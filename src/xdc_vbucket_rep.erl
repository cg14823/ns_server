%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

%% This module is responsible for replicating an individual vbucket. It gets
%% started and stopped by the xdc_replicator module when the local vbucket maps
%% changes and moves its vb. When the remote vbucket map changes, it receives
%% an error and restarts, thereby reloading it's the remote vb info.

%% It waits for changes to the local vbucket (state=idle), and calculates
%% the amount of work it needs to do. Then it asks the concurrency throttle
%% for a turn to replicate (state=waiting_turn). When it gets it's turn, it
%% replicates a single snapshot of the local vbucket (state=replicating).
%% it waits for the last worker to complete, then enters the idle state
%% and it checks to see if any work is to be done again.

%% While it's idle or waiting_turn, it will update the amount of work it
%% needs to do during the next replication, but it won't while it's
%% replicating. This can be enhanced in the future to update it's count while
%% it has a snapshot.cd bi

%% XDC Replicator Functions
-module(xdc_vbucket_rep).
-behaviour(gen_server).

%% public functions
-export([start_link/6]).

%% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-export([format_status/2]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").

-record(init_state, {
          rep,
          vb,
          mode,
          init_throttle,
          work_throttle,
          parent}).

start_link(Rep, Vb, InitThrottle, WorkThrottle, Parent, RepMode) ->
    InitState = #init_state{rep = Rep,
                            vb = Vb,
                            mode = RepMode,
                            init_throttle = InitThrottle,
                            work_throttle = WorkThrottle,
                            parent = Parent},
    gen_server:start_link(?MODULE, InitState, []).


%% gen_server behavior callback functions
init(#init_state{init_throttle = InitThrottle} = InitState) ->
    process_flag(trap_exit, true),
    %% signal to self to initialize
    ok = concurrency_throttle:send_back_when_can_go(InitThrottle, init),
    {ok, InitState}.

format_status(Opt, [PDict, State]) ->
    xdc_rep_utils:sanitize_status(Opt, PDict, State).

handle_info({'EXIT',_Pid, normal}, St) ->
    {noreply, St};

handle_info({'EXIT',_Pid, Reason}, St) ->
    {stop, Reason, St};

handle_info(init, #init_state{init_throttle = InitThrottle} = InitState) ->
    try
        State = init_replication_state(InitState),
        self() ! src_db_updated, % signal to self to check for changes
        {noreply, update_status_to_parent(State)}
    catch
        ErrorType:Error ->
            ?xdcr_error("Error initializing vb replicator (~p):~p", [InitState, {ErrorType,Error}]),
            {stop, Error, InitState}
    after
        concurrency_throttle:is_done(InitThrottle)
    end;

handle_info(src_db_updated, #init_state{} = St) ->
    %% nothing need to be done, will send ourself a signal to check update after init is over
    {noreply, St};

handle_info(src_db_updated,
            #rep_state{status = #rep_vb_status{status = idle}} = St) ->
    misc:flush(src_db_updated),
    case update_number_of_changes(St) of
        #rep_state{status = #rep_vb_status{num_changes_left = 0}} = St2 ->
            {noreply, St2, hibernate};
        #rep_state{status =VbStatus, throttle = Throttle, target_name = TgtURI} = St2 ->
            #rep_vb_status{vb = Vb} = VbStatus,
            TargetNode =  target_uri_to_node(TgtURI),
            ?xdcr_debug("ask for token for rep of vb: ~p to target node: ~p", [Vb, TargetNode]),
            ok = concurrency_throttle:send_back_when_can_go(Throttle, TargetNode, start_replication),
            {noreply, update_status_to_parent(St2#rep_state{status = VbStatus#rep_vb_status{status = waiting_turn}}), hibernate}
    end;

handle_info(src_db_updated,
            #rep_state{status = #rep_vb_status{status = waiting_turn}} = St) ->
    misc:flush(src_db_updated),
    {noreply, update_status_to_parent(update_number_of_changes(St)), hibernate};

handle_info(src_db_updated, #rep_state{status = #rep_vb_status{status = replicating}} = St) ->
    %% we ignore this message when replicating, because it's difficult to
    %% compute accurately while actively replicating.
    %% When done replicating, we will check for new changes always.
    misc:flush(src_db_updated),
    {noreply, St};

handle_info(start_replication, #rep_state{throttle = Throttle,
                                          status = #rep_vb_status{vb = Vb, status = waiting_turn} = VbStatus} = St) ->

    ?xdcr_debug("get start-replication token for vb ~p from throttle (pid: ~p)", [Vb, Throttle]),

    St1 = St#rep_state{status = VbStatus#rep_vb_status{status = replicating}},
    St2 = update_rep_options(St1),
    {noreply, start_replication(St2)};

handle_info(return_token_please, State) ->
    case State of
        #rep_state{status = RepVBStatus,
                   changes_queue = ChangesQueue} when RepVBStatus#rep_vb_status.status =:= replicating ->
            ?xdcr_debug("changes queue for vb ~p closed due to pause request, "
                        "rep will stop after flushing remaining ~p items in queue",
                        [RepVBStatus#rep_vb_status.vb,
                         couch_work_queue:item_count(ChangesQueue)]),
            ChangesReader = erlang:get(changes_reader),
            {true, is_pid} = {is_pid(ChangesReader), is_pid},
            ChangesReader ! please_stop;
        _ ->
            ok
    end,
    {noreply, State}.


handle_call({report_seq_done,
             #worker_stat{
               worker_id = WorkerID,
               seq = Seq,
               worker_item_opt_repd = NumDocsOptRepd,
               worker_item_checked = NumChecked,
               worker_item_replicated = NumWritten,
               worker_data_replicated = WorkerDataReplicated} = WorkerStat}, From,
            #rep_state{seqs_in_progress = SeqsInProgress,
                       highest_seq_done = HighestDone,
                       current_through_seq = ThroughSeq,
                       status = #rep_vb_status{num_changes_left = ChangesLeft,
                                               docs_opt_repd = TotalOptRepd,
                                               docs_checked = TotalChecked,
                                               docs_written = TotalWritten,
                                               data_replicated = TotalDataReplicated,
                                               workers_stat = AllWorkersStat,
                                               vb = Vb} = VbStatus} = State) ->
    gen_server:reply(From, ok),
    {NewThroughSeq0, NewSeqsInProgress} = case SeqsInProgress of
                                              [Seq | Rest] ->
                                                  {Seq, Rest};
                                              [_ | _] ->
                                                  {ThroughSeq, ordsets:del_element(Seq, SeqsInProgress)}
                                          end,
    NewHighestDone = lists:max([HighestDone, Seq]),
    NewThroughSeq = case NewSeqsInProgress of
                        [] ->
                            lists:max([NewThroughSeq0, NewHighestDone]);
                        _ ->
                            NewThroughSeq0
                    end,

    %% check possible inconsistency, and dump warning msgs if purger is ahead of replication
    SourceDB = State#rep_state.source,
    PurgeSeq = couch_db:get_purge_seq(SourceDB),
    BehindPurger =
        case (PurgeSeq >= NewHighestDone) and (State#rep_state.behind_purger == false) of
            true ->
                ?xdcr_error("WARNING! Database delete purger current sequence is ahead of "
                            "replicator sequence for (source: ~p, target: ~p "
                            "that means one or more deletion is lost "
                            "(vb: ~p, purger seq: ~p, repl current seq: ~p).",
                            [(State#rep_state.rep_details)#rep.source,
                             (State#rep_state.rep_details)#rep.target,
                             Vb, PurgeSeq, NewHighestDone]),
                true;
            _ ->
                %% keep old value if repl is not outpaced, or warning msg has been dumped
                State#rep_state.behind_purger
        end,

    ?xdcr_trace("Replicator of vbucket ~p: worker reported seq ~p, through seq was ~p, "
                "new through seq is ~p, highest seq done was ~p, new highest seq done is ~p "
                "(db purger seq: ~p, repl outpaced by purger during this run? ~p)~n"
                "Seqs in progress were: ~p~nSeqs in progress are now: ~p"
                "(total docs checked: ~p, total docs written: ~p)",
                [Vb, Seq, ThroughSeq, NewThroughSeq, HighestDone,
                 NewHighestDone, PurgeSeq, BehindPurger,
                 SeqsInProgress, NewSeqsInProgress,
                 TotalChecked, TotalWritten]),

    %% get stats
    {ChangesQueueSize, ChangesQueueDocs} = get_changes_queue_stats(State),

    %% update latency stats, using worker id as key
    NewWorkersStat = dict:store(WorkerID, WorkerStat, AllWorkersStat),

    %% aggregate weighted latency as well as its weight from each worker
    [VbMetaLatencyAggr, VbMetaLatencyWtAggr] = dict:fold(
                                                 fun(_Pid, #worker_stat{worker_meta_latency_aggr = MetaLatencyAggr,
                                                                        worker_item_checked = Weight} = _WorkerStat,
                                                     [MetaLatencyAcc, MetaLatencyWtAcc]) ->
                                                         [MetaLatencyAcc + MetaLatencyAggr, MetaLatencyWtAcc + Weight]
                                                 end,
                                                 [0, 0], NewWorkersStat),

    [VbDocsLatencyAggr, VbDocsLatencyWtAggr] = dict:fold(
                                                 fun(_Pid, #worker_stat{worker_docs_latency_aggr = DocsLatencyAggr,
                                                                        worker_item_replicated = Weight} = _WorkerStat,
                                                     [DocsLatencyAcc, DocsLatencyWtAcc]) ->
                                                         [DocsLatencyAcc + DocsLatencyAggr, DocsLatencyWtAcc + Weight]
                                                 end,
                                                 [0, 0], NewWorkersStat),

    NewState = State#rep_state{
                 current_through_seq = NewThroughSeq,
                 seqs_in_progress = NewSeqsInProgress,
                 highest_seq_done = NewHighestDone,
                 behind_purger = BehindPurger,
                 status = VbStatus#rep_vb_status{num_changes_left = ChangesLeft - NumChecked,
                                                 docs_changes_queue = ChangesQueueDocs,
                                                 size_changes_queue = ChangesQueueSize,
                                                 data_replicated = TotalDataReplicated + WorkerDataReplicated,
                                                 docs_checked = TotalChecked + NumChecked,
                                                 docs_written = TotalWritten + NumWritten,
                                                 docs_opt_repd = TotalOptRepd + NumDocsOptRepd,
                                                 workers_stat = NewWorkersStat,
                                                 meta_latency_aggr = VbMetaLatencyAggr,
                                                 meta_latency_wt = VbMetaLatencyWtAggr,
                                                 docs_latency_aggr = VbDocsLatencyAggr,
                                                 docs_latency_wt = VbDocsLatencyWtAggr}
                },

    {noreply, update_status_to_parent(NewState)};

handle_call({worker_done, Pid}, _From,
            #rep_state{workers = Workers, status = VbStatus} = State) ->
    case Workers -- [Pid] of
        Workers ->
            {stop, {unknown_worker_done, Pid}, ok, State};
        [] ->
            %% all workers completed. Now shutdown everything and prepare for
            %% more changes from src

            %% allow another replicator to go
            State2 = replication_turn_is_done(State),
            couch_api_wrap:db_close(State2#rep_state.source),
            couch_api_wrap:db_close(State2#rep_state.src_master_db),
            couch_api_wrap:db_close(State2#rep_state.target),
            couch_api_wrap:db_close(State2#rep_state.tgt_master_db),

            %% force check for changes since we last snapshop
            %%
            %% NOTE: this is required for correct handling of
            %% pause/resume as of now. I.e. because we can actually
            %% reach this state without completing replication of
            %% snapshot we had
            %%
            %% This is also required because of message drop in
            %% handling of src_db_updated message in replicating
            %% state. I.e. we discard src_db_updated messages while
            %% replicating snapshot, so we have to assume that some
            %% more mutations were made after we're done with
            %% snapshot.
            self() ! src_db_updated,

            %% changes may or may not be closed
            VbStatus2 = VbStatus#rep_vb_status{size_changes_queue = 0,
                                               docs_changes_queue = 0},
            %% dump a bunch of stats
            Vb = VbStatus2#rep_vb_status.vb,
            Throttle = State2#rep_state.throttle,
            HighestDone = State2#rep_state.highest_seq_done,
            ChangesLeft = VbStatus2#rep_vb_status.num_changes_left,
            TotalChecked = VbStatus2#rep_vb_status.docs_checked,
            TotalWritten = VbStatus2#rep_vb_status.docs_written,
            TotalDataRepd = VbStatus2#rep_vb_status.data_replicated,
            NumCkpts = VbStatus2#rep_vb_status.num_checkpoints,
            NumFailedCkpts = VbStatus2#rep_vb_status.num_failedckpts,
            LastCkptTime = State2#rep_state.last_checkpoint_time,
            StartRepTime = State2#rep_state.rep_start_time,

            ?xdcr_trace("Replicator of vbucket ~p done, return token to throttle: ~p~n"
                        "(highest seq done is ~p, number of changes left: ~p~n"
                        "total docs checked: ~p, total docs written: ~p (total data repd: ~p)~n"
                        "total number of succ ckpts: ~p (failed ckpts: ~p)~n"
                        "last succ ckpt time: ~p, replicator start time: ~p.",
                        [Vb, Throttle, HighestDone, ChangesLeft, TotalChecked, TotalWritten, TotalDataRepd,
                         NumCkpts, NumFailedCkpts,
                         calendar:now_to_local_time(LastCkptTime),
                         calendar:now_to_local_time(StartRepTime)
                        ]),
            VbStatus3 = VbStatus2#rep_vb_status{status = idle},

            %% finally report stats to bucket replicator and tell it that I am idle
            NewState = update_status_to_parent(State2#rep_state{
                                                  workers = [],
                                                  status = VbStatus3,
                                                  source = undefined,
                                                  src_master_db = undefined,
                                                  target = undefined,
                                                  tgt_master_db = undefined}),

            %% cancel the timer since we will start it next time the vb rep waken up
            NewState2 = xdc_vbucket_rep_ckpt:cancel_timer(NewState),
            % hibernate to reduce memory footprint while idle
            {reply, ok, NewState2, hibernate};
        Workers2 ->
            {reply, ok, State#rep_state{workers = Workers2}}
    end.


handle_cast(checkpoint, #rep_state{status = VbStatus} = State) ->
    Result = case VbStatus#rep_vb_status.status of
                 replicating ->
                     Start = now(),
                     case xdc_vbucket_rep_ckpt:do_checkpoint(State) of
                         {ok, _, NewState} ->
                             CommitTime = timer:now_diff(now(), Start) div 1000,
                             TotalCommitTime = CommitTime + NewState#rep_state.status#rep_vb_status.commit_time,
                             VbStatus2 = NewState#rep_state.status#rep_vb_status{commit_time = TotalCommitTime},
                             NewState2 = NewState#rep_state{timer = xdc_vbucket_rep_ckpt:start_timer(State),
                                                            status = VbStatus2},
                             Vb = (NewState2#rep_state.status)#rep_vb_status.vb,
                             ?xdcr_trace("checkpoint issued during replication for vb ~p, "
                                         "commit time: ~p", [Vb, CommitTime]),
                             {ok, NewState2};
                         {checkpoint_commit_failure, ErrorMsg, NewState} ->
                             %% update the failed ckpt stats to bucket replicator
                             Vb = (NewState#rep_state.status)#rep_vb_status.vb,
                             ?xdcr_error("checkpoint commit failure during replication for vb ~p, "
                                         "error: ~p", [Vb, ErrorMsg]),
                             {stop, ErrorMsg, update_status_to_parent(NewState)}
                     end;
                 _ ->
                     %% if get checkpoint when not in replicating state, continue to wait until we
                     %% get our next turn, we'll do the checkpoint at the start of that.
                     NewState = xdc_vbucket_rep_ckpt:cancel_timer(State),
                     {ok, NewState}
             end,

    case Result of
        {ok, NewState3} ->
            {noreply, NewState3};
        {stop, _, _} ->
            Result
    end;


handle_cast({report_error, Err},
            #rep_state{parent = Parent} = State) ->
    %% relay error from child to parent bucket replicator
    gen_server:cast(Parent, {report_error, Err}),
    {noreply, State};

handle_cast({report_seq, Seq},
            #rep_state{seqs_in_progress = SeqsInProgress} = State) ->
    NewSeqsInProgress = ordsets:add_element(Seq, SeqsInProgress),
    {noreply, State#rep_state{seqs_in_progress = NewSeqsInProgress}}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, #init_state{rep = #rep{target = TargetRef}, parent = P, vb = Vb} = InitState) ->
    report_error(Reason, Vb, P),
    ?xdcr_error("Shutting xdcr vb replicator (~p) down without ever successfully initializing: ~p", [InitState, Reason]),
    remote_clusters_info:invalidate_remote_bucket_by_ref(TargetRef),
    ok;

terminate(Reason, State) when Reason == normal orelse Reason == shutdown ->
    terminate_cleanup(State);

terminate(Reason, #rep_state{
            source_name = Source,
            target_name = Target,
            rep_details = #rep{id = Id, replication_mode = RepMode, target = TargetRef},
            status = #rep_vb_status{vb = Vb} = Status,
            parent = P
           } = State) ->

    case RepMode of
        "capi" ->
            ?xdcr_error("Replication (CAPI mode) `~s` (`~s` -> `~s`) failed: ~s",
                        [Id, Source, misc:sanitize_url(Target), to_binary(Reason)]);
        _ ->
            case Reason of
                {{error, {ErrorStat, _ErrKeys}}, _State} ->
                    ?xdcr_error("Replication (XMem mode) `~s` (`~s` -> `~s`) failed."
                                "Error msg from xmem server: ~p."
                                "Please see ns_server debug log for complete state dump.",
                                [Id, Source, misc:sanitize_url(Target), ErrorStat]);
                _ ->
                    ?xdcr_error("Replication (XMem mode) `~s` (`~s` -> `~s`) failed."
                                "Please see ns_server debug log for complete state dump",
                                [Id, Source, misc:sanitize_url(Target)])
            end
    end,
    update_status_to_parent(State#rep_state{status =
                                                Status#rep_vb_status{status = idle,
                                                                     num_changes_left = 0,
                                                                     docs_changes_queue = 0,
                                                                     size_changes_queue = 0
                                                                    }}),
    report_error(Reason, Vb, P),
    %% an unhandled error happened. Invalidate target vb map cache.
    remote_clusters_info:invalidate_remote_bucket_by_ref(TargetRef),
    terminate_cleanup(State).


terminate_cleanup(State0) ->
    State = xdc_vbucket_rep_ckpt:cancel_timer(State0),
    Dbs = [State#rep_state.source,
           State#rep_state.target,
           State#rep_state.src_master_db,
           State#rep_state.tgt_master_db],
    [catch couch_api_wrap:db_close(Db) || Db <- Dbs, Db /= undefined].


%% internal helper function

report_error(Err, _Vb, _Parent) when Err == normal orelse Err == shutdown ->
    ok;
report_error(_Err, Vb, Parent) ->
    %% return raw erlang time to make it sortable
    RawTime = erlang:localtime(),
    Time = misc:iso_8601_fmt(RawTime),

    String = iolist_to_binary(io_lib:format("~s [Vb Rep] Error replicating vbucket ~p. "
                                            "Please see logs for details.",
                                            [Time, Vb])),
    gen_server:cast(Parent, {report_error, {RawTime, String}}).

replication_turn_is_done(#rep_state{throttle = T} = State) ->
    concurrency_throttle:is_done(T),
    State.

update_status_to_parent(#rep_state{parent = Parent,
                                   status = VbStatus} = State) ->
    %% compute work time since last update the status, note we only compute
    %% the work time if the status is replicating
    WorkTime = case VbStatus#rep_vb_status.status of
                   replicating ->
                       case State#rep_state.work_start_time of
                           0 ->
                               %% timer not initalized yet
                               0;
                           _ ->
                               timer:now_diff(now(), State#rep_state.work_start_time) div 1000
                       end;
                   %% if not replicating (idling or waiting for turn), do not count the work time
                   _ ->
                       0
               end,

    %% post to parent bucket replicator
    Parent ! {set_vb_rep_status,  VbStatus#rep_vb_status{work_time = WorkTime}},

    %% account stats to persist
    TotalChecked = VbStatus#rep_vb_status.total_docs_checked + VbStatus#rep_vb_status.docs_checked,
    TotalWritten = VbStatus#rep_vb_status.total_docs_written + VbStatus#rep_vb_status.docs_written,
    TotalDocsOptRepd = VbStatus#rep_vb_status.total_docs_opt_repd + VbStatus#rep_vb_status.docs_opt_repd,
    TotalDataRepd = VbStatus#rep_vb_status.total_data_replicated +
        VbStatus#rep_vb_status.data_replicated,

    %% reset accumulated stats and start work time
    NewVbStat = VbStatus#rep_vb_status{
                  total_docs_checked = TotalChecked,
                  total_docs_written = TotalWritten,
                  total_docs_opt_repd = TotalDocsOptRepd,
                  total_data_replicated = TotalDataRepd,
                  docs_checked = 0,
                  docs_written = 0,
                  docs_opt_repd = 0,
                  data_replicated = 0,
                  work_time = 0,
                  commit_time = 0,
                  num_checkpoints = 0,
                  num_failedckpts = 0},
    State#rep_state{status = NewVbStat,
                    work_start_time = now()}.

init_replication_state(#init_state{rep = Rep,
                                   vb = Vb,
                                   mode = RepMode,
                                   work_throttle = Throttle,
                                   parent = Parent}) ->
    #rep{
          source = Src,
          target = Tgt,
          options = Options
        } = Rep,
    SrcVbDb = xdc_rep_utils:local_couch_uri_for_vbucket(Src, Vb),
    {ok, CurrRemoteBucket} =
        case remote_clusters_info:get_remote_bucket_by_ref(Tgt, false) of
            {ok, RBucket} ->
                {ok, RBucket};
            {error, ErrorMsg} ->
                ?xdcr_error("Error in fetching remot bucket, error: ~p,"
                            "sleep for ~p secs before retry.",
                            [ErrorMsg, (?XDCR_SLEEP_BEFORE_RETRY)]),
                %% sleep and retry once
                timer:sleep(1000*?XDCR_SLEEP_BEFORE_RETRY),
                remote_clusters_info:get_remote_bucket_by_ref(Tgt, false);
            {error, Error, Msg} ->
                ?xdcr_error("Error in fetching remot bucket, error: ~p, msg: ~p"
                            "sleep for ~p secs before retry",
                            [Error, Msg, (?XDCR_SLEEP_BEFORE_RETRY)]),
                %% sleep and retry once
                timer:sleep(1000*?XDCR_SLEEP_BEFORE_RETRY),
                remote_clusters_info:get_remote_bucket_by_ref(Tgt, false);
            {error, Error, Msg, Details} ->
                ?xdcr_error("Error in fetching remot bucket, error: ~p, msg: ~p, details: ~p"
                            "sleep for ~p secs before retry",
                            [Error, Msg, Details, (?XDCR_SLEEP_BEFORE_RETRY)]),
                %% sleep and retry once
                timer:sleep(1000*?XDCR_SLEEP_BEFORE_RETRY),
                remote_clusters_info:get_remote_bucket_by_ref(Tgt, false)
        end,

    TgtURI = hd(dict:fetch(Vb, CurrRemoteBucket#remote_bucket.capi_vbucket_map)),
    CertPEM = CurrRemoteBucket#remote_bucket.cluster_cert,
    TgtDb = xdc_rep_utils:parse_rep_db(TgtURI, [], [{xdcr_cert, CertPEM} | Options]),
    {ok, Source} = couch_api_wrap:db_open(SrcVbDb, []),
    {ok, Target} = couch_api_wrap:db_open(TgtDb, []),
    {ok, SourceInfo} = couch_api_wrap:get_db_info(Source),
    {ok, TargetInfo} = couch_api_wrap:get_db_info(Target),

    {ok, SrcMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Source),
                          []),
    {ok, TgtMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Target),
                          []),

    XMemRemote = case RepMode of
                     "xmem" ->
                         {ok, #remote_node{host = RemoteHostName, memcached_port = Port} = RN, LatestRemoteBucket} =
                             case remote_clusters_info:get_memcached_vbucket_info_by_ref(Tgt, false, Vb) of
                                 {ok, RemoteNode, TgtBucket} ->
                                     {ok, RemoteNode, TgtBucket};
                                 Error2 ->
                                     ?xdcr_error("Error in fetching remot memcached vbucket info, error: ~p"
                                                 "sleep for ~p secs before retry",
                                                 [Error2, (?XDCR_SLEEP_BEFORE_RETRY)]),
                                     timer:sleep(1000*?XDCR_SLEEP_BEFORE_RETRY),
                                     remote_clusters_info:get_memcached_vbucket_info_by_ref(Tgt, false, Vb)
                             end,

                         {ok, {_ClusterUUID, BucketName}} = remote_clusters_info:parse_remote_bucket_reference(Tgt),
                         Password = binary_to_list(LatestRemoteBucket#remote_bucket.password),
                         #xdc_rep_xmem_remote{ip = RemoteHostName, port = Port,
                                              bucket = BucketName, vb = Vb,
                                              username = BucketName, password = Password,
                                              options = [{remote_node, RN},
                                                         {remote_proxy_port, RN#remote_node.ssl_proxy_port},
                                                         {cert, LatestRemoteBucket#remote_bucket.cluster_cert}]};
                     _ ->
                         nil
                 end,

    %% We have to pass the vbucket database along with the master database
    %% because the replication log id needs to be prefixed with the vbucket id
    %% at both the source and the destination.
    [SourceLog, TargetLog] = find_replication_logs(
                               [{Source, SrcMasterDb}, {Target, TgtMasterDb}],
                               Rep),

    {StartSeq,
     TotalDocsChecked,
     TotalDocsWritten,
     TotalDataReplicated,
     History} = compare_replication_logs(SourceLog, TargetLog),
    ?xdcr_trace("history log at src and dest: startseq: ~p, docs checked: ~p,"
                "docs_written: ~p, data replicated: ~p",
                [StartSeq, TotalDocsChecked, TotalDocsWritten, TotalDataReplicated]),
    #doc{body={CheckpointHistory}} = SourceLog,

    %% check if we are already behind purger
    PurgeSeq = couch_db:get_purge_seq(Source),
    BehindPurger  =
        case (PurgeSeq > 0) and (PurgeSeq >= StartSeq) of
            true ->
                ?xdcr_error("WARNING! Database delete purger current sequence is ahead "
                            "of replicator starting sequence for (source:~p, target:~p) "
                            "that means one or more deletion is lost "
                            "(vb: ~p, purger seq: ~p, repl start seq: ~p).",
                            [Src, Tgt, Vb, PurgeSeq, StartSeq]),
                true;
            _ ->
                false
        end,

    couch_db:close(Source),
    couch_db:close(SrcMasterDb),
    couch_api_wrap:db_close(TgtMasterDb),
    couch_api_wrap:db_close(Target),
    couch_api_wrap:db_close(TgtMasterDb),

    RepState = #rep_state{
      rep_details = Rep,
      throttle = Throttle,
      parent = Parent,
      source_name = SrcVbDb,
      target_name = TgtURI,
      source = Source,
      target = Target,
      src_master_db = SrcMasterDb,
      tgt_master_db = TgtMasterDb,
      history = History,
      checkpoint_history = {[{<<"no_changes">>, true}| CheckpointHistory]},
      start_seq = StartSeq,
      current_through_seq = StartSeq,
      source_cur_seq = StartSeq,
      source_log = SourceLog,
      target_log = TargetLog,
      rep_starttime = httpd_util:rfc1123_date(),
      src_starttime = get_value(<<"instance_start_time">>, SourceInfo),
      tgt_starttime = get_value(<<"instance_start_time">>, TargetInfo),
      last_checkpoint_time = now(),
      rep_start_time = now(),
      %% temporarily initialized to 0, when vb rep gets the token it will
      %% initialize the work start time in start_replication()
      work_start_time = 0,
      session_id = couch_uuids:random(),
      behind_purger = BehindPurger,
      %% XMem not started
      xmem_location = nil,
      xmem_remote = XMemRemote,
      status = #rep_vb_status{vb = Vb,
                              pid = self(),
                              %% init per vb replication stats from checkpoint doc
                              total_docs_checked = TotalDocsChecked,
                              total_docs_written = TotalDocsWritten,
                              total_data_replicated = TotalDataReplicated,
                              %% the per vb replicator stats are cleared here. They
                              %% will be computed during the lifetime of vb
                              %% replicator and aggregated at the parent bucket
                              %% replicator when vb replicator pushes the stats
                              docs_checked = 0,
                              docs_written = 0,
                              work_time = 0,
                              commit_time = 0,
                              data_replicated = 0,
                              num_checkpoints = 0,
                              num_failedckpts = 0
                             }
     },
    XMemRemoteStr = case XMemRemote of
                        nil ->
                            "none";
                        _ ->
                            ?format_msg("(target node: ~s:~p, target bucket: ~s)",
                                        [XMemRemote#xdc_rep_xmem_remote.ip,
                                         XMemRemote#xdc_rep_xmem_remote.port,
                                         XMemRemote#xdc_rep_xmem_remote.bucket])
                    end,
    ?xdcr_debug("vb ~p replication state initialized: (local db: ~p, remote db: ~p, mode: ~p, xmem remote: ~s)",
                [Vb, RepState#rep_state.source_name,
                 misc:sanitize_url(RepState#rep_state.target_name), RepMode, XMemRemoteStr]),
    RepState.

update_rep_options(#rep_state{rep_details =
                                  #rep{id = Id,
                                       options = OldOptions} = Rep} = State) ->
    NewOptions = xdc_settings:get_all_settings_snapshot_by_doc_id(Id),

    case OldOptions =:= NewOptions of
        true ->
            State;
        false ->
            NewRep = Rep#rep{options = NewOptions},
            State#rep_state{rep_details = NewRep}
    end.

start_replication(#rep_state{
                     source_name = SourceName,
                     target_name = OrigTgtURI,
                     current_through_seq = StartSeq,
                     last_checkpoint_time = LastCkptTime,
                     status = #rep_vb_status{vb = Vb},
                     rep_details = #rep{id = Id, options = Options, target = TargetRef},
                     xmem_remote = Remote
                    } = State) ->

    WorkStart = now(),

    NumWorkers = get_value(worker_processes, Options),
    BatchSizeItems = get_value(worker_batch_size, Options),
    {ok, Source} = couch_api_wrap:db_open(SourceName, []),

    %% we re-fetch bucket details to get fresh remote cluster certificate
    {TgtDB, TgtURI} =
        case remote_clusters_info:get_remote_bucket_by_ref(TargetRef, false) of
            {ok, CurrRemoteBucket} ->
                TgtURI0 = hd(dict:fetch(Vb, CurrRemoteBucket#remote_bucket.capi_vbucket_map)),
                CertPEM = CurrRemoteBucket#remote_bucket.cluster_cert,
                case Remote of
                    #xdc_rep_xmem_remote{options = XMemRemoteOptions} ->
                        case get_value(cert, XMemRemoteOptions) =:= CertPEM of
                            true -> ok;
                            false ->
                                erlang:exit({cert_mismatch_restart, Id, Vb})
                        end;
                    _ ->
                        ok
                end,
                {xdc_rep_utils:parse_rep_db(TgtURI0, [], [{xdcr_cert, CertPEM} | Options]), TgtURI0};
            Err ->
                ?xdcr_error("Couldn't re-fetch remote bucket info for ~s (original url: ~s): ~p",
                            [TargetRef, misc:sanitize_url(OrigTgtURI), Err]),
                erlang:exit({get_remote_bucket_failed, Err})
        end,
    {ok, Target} = couch_api_wrap:db_open(TgtDB, []),

    {ok, SrcMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Source),
                          []),
    {ok, TgtMasterDb} = couch_api_wrap:db_open(
                          xdc_rep_utils:get_master_db(Target), []),

    {ok, ChangesQueue} = couch_work_queue:new([
                                               {max_items, BatchSizeItems * NumWorkers * 2},
                                               {max_size, 100 * 1024 * NumWorkers}
                                              ]),
    %% This starts the _changes reader process. It adds the changes from
    %% the source db to the ChangesQueue.
    ChangesReader = spawn_changes_reader(StartSeq, Source, ChangesQueue),
    erlang:put(changes_reader, ChangesReader),
    %% Changes manager - responsible for dequeing batches from the changes queue
    %% and deliver them to the worker processes.
    ChangesManager = spawn_changes_manager(self(), ChangesQueue, BatchSizeItems),
    %% This starts the worker processes. They ask the changes queue manager for a
    %% a batch of _changes rows to process -> check which revs are missing in the
    %% target, and for the missing ones, it copies them from the source to the target.
    MaxConns = get_value(http_connections, Options),
    OptRepThreshold = get_value(optimistic_replication_threshold, Options),

    ?xdcr_trace("changes reader process (PID: ~p) and manager process (PID: ~p) "
                "created, now starting worker processes...",
                [ChangesReader, ChangesManager]),
    Changes = couch_db:count_changes_since(Source, StartSeq),


    %% start xmem server if it has not started
    Vb = (State#rep_state.status)#rep_vb_status.vb,
    XMemLoc = case Remote of
                  nil ->
                      nil;
                  %% xmem replication mode
                  _XMemRemote  ->
                      ConnectionTimeout = get_value(connection_timeout, Options),
                      xdc_vbucket_rep_xmem:make_location(Remote, ConnectionTimeout)
              end,

    BatchSizeKB = get_value(doc_batch_size_kb, Options),

    %% build start option for worker process
    WorkerOption = #rep_worker_option{
      cp = self(), source = Source, target = Target,
      changes_manager = ChangesManager, max_conns = MaxConns,
      opt_rep_threshold = OptRepThreshold, xmem_location = XMemLoc,
      batch_size = BatchSizeKB * 1024,
      batch_items = BatchSizeItems},

    Workers = lists:map(
                fun(WorkerID) ->
                        WorkerOption2 = WorkerOption#rep_worker_option{worker_id = WorkerID},
                        {ok, WorkerPid} = xdc_vbucket_rep_worker:start_link(WorkerOption2),
                        WorkerPid
                end,
                lists:seq(1, NumWorkers)),

    ?xdcr_info("Replication `~p` is using:~n"
               "~c~p worker processes~n"
               "~ca worker batch size of ~p~n"
               "~ca worker batch size (KiB) ~p~n"
               "~c~p HTTP connections~n"
               "~ca connection timeout of ~p seconds~n"
               "~c~p retries per request~n"
               "~csocket options are: ~s~s",
               [Id, $\t, NumWorkers, $\t, BatchSizeItems, $\t, BatchSizeKB, $\t,
                MaxConns, $\t, get_value(connection_timeout, Options),
                $\t, get_value(retries_per_request, Options),
                $\t, io_lib:format("~p", [get_value(socket_options, Options)]),
                case StartSeq of
                    ?LOWEST_SEQ ->
                        "";
                    _ ->
                        io_lib:format("~n~csource start sequence ~p", [$\t, StartSeq])
                end]),

    IntervalSecs = get_value(checkpoint_interval, Options),
    TimeSinceLastCkpt = timer:now_diff(now(), LastCkptTime) div 1000000,

    ?xdcr_trace("Worker pids are: ~p, last checkpt time: ~p"
                "secs since last ckpt: ~p, ckpt interval: ~p)",
                [Workers, calendar:now_to_local_time(LastCkptTime),
                 TimeSinceLastCkpt, IntervalSecs]),

    %% check if we need do checkpointing, replicator will crash if checkpoint failure
    State1 = State#rep_state{
               xmem_location = XMemLoc,
               source = Source,
               target = Target,
               src_master_db = SrcMasterDb,
               tgt_master_db = TgtMasterDb},

    Start = now(),
    {Succ, ErrorMsg, NewState} = case TimeSinceLastCkpt > IntervalSecs of
                                     true ->
                                         xdc_vbucket_rep_ckpt:do_checkpoint(State1);
                                     _ ->
                                         {ok, <<"no checkpoint">>, State1}
                                 end,

    CommitTime = timer:now_diff(now(), Start) div 1000,
    TotalCommitTime = CommitTime + NewState#rep_state.status#rep_vb_status.commit_time,

    NewVbStatus = NewState#rep_state.status,
    ResultState = update_status_to_parent(NewState#rep_state{
                                            changes_queue = ChangesQueue,
                                            workers = Workers,
                                            source = Source,
                                            src_master_db = SrcMasterDb,
                                            target_name = TgtURI,
                                            target = Target,
                                            tgt_master_db = TgtMasterDb,
                                            status = NewVbStatus#rep_vb_status{num_changes_left = Changes,
                                                                               commit_time = TotalCommitTime},
                                            timer = xdc_vbucket_rep_ckpt:start_timer(State),
                                            work_start_time = WorkStart
                                           }),

    %% finally crash myself if fail to commit, after posting status to parent
    case Succ of
        ok ->
            ?xdcr_trace("checkpoint at start of replication for vb ~p "
                        "commit time: ~p ms, msg: ~p", [Vb, CommitTime, ErrorMsg]),
            ok;
        checkpoint_commit_failure ->
            ?xdcr_error("checkpoint commit failure at start of replication for vb ~p, "
                        "error: ~p", [Vb, ErrorMsg]),
            exit(ErrorMsg)
    end,


    %% finally the vb replicator has been started
    Src = ResultState#rep_state.source_name,
    Tgt = misc:sanitize_url(ResultState#rep_state.target_name),
    case Remote of
        nil ->
            ?xdcr_info("replicator of vb ~p for replication from src ~p to target ~p has been "
                       "started (capi mode).",
                       [Vb, Src, Tgt]),
            ok;
        _ ->
            ?xdcr_info("replicator of vb ~p for replication from src ~p to target ~p has been "
                       "started (xmem remote (ip: ~p, port: ~p, bucket: ~p)).",
                       [Vb, Src, Tgt, Remote#xdc_rep_xmem_remote.ip,
                        Remote#xdc_rep_xmem_remote.port, Remote#xdc_rep_xmem_remote.bucket]),
            ok
    end,
    ResultState.

update_number_of_changes(#rep_state{source_name = Src,
                                    current_through_seq = Seq,
                                    status = VbStatus} = State) ->
    case couch_server:open(Src, []) of
        {ok, Db} ->
            Changes = couch_db:count_changes_since(Db, Seq),
            couch_db:close(Db),
            if VbStatus#rep_vb_status.num_changes_left /= Changes ->
                    State#rep_state{status = VbStatus#rep_vb_status{num_changes_left = Changes}};
               true ->
                    State
            end;
        {not_found, no_db_file} ->
            %% oops our file was deleted.
            %% We'll get shutdown when the vbucket map message is processed
            State
    end.


spawn_changes_reader(StartSeq, Db, ChangesQueue) ->
    spawn_link(fun() ->
                       read_changes(StartSeq, Db, ChangesQueue)
               end).

read_changes(StartSeq, Db, ChangesQueue) ->
    couch_db:changes_since(
      Db, StartSeq,
      fun(DocInfo, _) ->
              ok = couch_work_queue:queue(ChangesQueue, DocInfo),
              receive
                  please_stop ->
                      ?xdcr_debug("Handling please_stop in changes reader"),
                      {stop, ok}
              after 0 ->
                      {ok, []}
              end
      end, [], []),
    couch_work_queue:close(ChangesQueue).

spawn_changes_manager(Parent, ChangesQueue, BatchSize) ->
    spawn_link(fun() ->
                       changes_manager_loop_open(Parent, ChangesQueue, BatchSize)
               end).

changes_manager_loop_open(Parent, ChangesQueue, BatchSize) ->
    receive
        {get_changes, From} ->
            case couch_work_queue:dequeue(ChangesQueue, BatchSize) of
                closed ->
                    ok; % now done!
                {ok, Changes, _Size} ->
                    #doc_info{local_seq = Seq} = lists:last(Changes),
                    ReportSeq = Seq,
                    ok = gen_server:cast(Parent, {report_seq, ReportSeq}),
                    From ! {changes, self(), Changes, ReportSeq},
                    changes_manager_loop_open(Parent, ChangesQueue, BatchSize)
            end
    end.

find_replication_logs(DbList, #rep{id = Id} = Rep) ->
    fold_replication_logs(DbList, ?REP_ID_VERSION, Id, Id, Rep, []).


fold_replication_logs([], _Vsn, _LogId, _NewId, _Rep, Acc) ->
    lists:reverse(Acc);

fold_replication_logs([{Db, MasterDb} | Rest] = Dbs, Vsn, LogId0, NewId0, Rep, Acc) ->
    LogId = xdc_rep_utils:get_checkpoint_log_id(Db, LogId0),
    NewId = xdc_rep_utils:get_checkpoint_log_id(Db, NewId0),
    case couch_api_wrap:open_doc(MasterDb, LogId, [ejson_body]) of
        {error, <<"not_found">>} when Vsn > 1 ->
            OldRepId = Rep#rep.id,
            fold_replication_logs(Dbs, Vsn - 1,
                                  OldRepId, NewId0, Rep, Acc);
        {error, <<"not_found">>} ->
            fold_replication_logs(
              Rest, ?REP_ID_VERSION, NewId0, NewId0, Rep, [#doc{id = NewId, body = {[]}} | Acc]);
        {ok, Doc} when LogId =:= NewId ->
            fold_replication_logs(
              Rest, ?REP_ID_VERSION, NewId0, NewId0, Rep, [Doc | Acc]);
        {ok, Doc} ->
            MigratedLog = #doc{id = NewId, body = Doc#doc.body},
            fold_replication_logs(
              Rest, ?REP_ID_VERSION, NewId0, NewId0, Rep, [MigratedLog | Acc])
    end.

compare_replication_logs(SrcDoc, TgtDoc) ->
    #doc{body={RepRecProps}} = SrcDoc,
    #doc{body={RepRecPropsTgt}} = TgtDoc,
    case get_value(<<"session_id">>, RepRecProps) ==
        get_value(<<"session_id">>, RepRecPropsTgt) of
        true ->
            %% if the records have the same session id,
            %% then we have a valid replication history
            OldSeqNum = get_value(<<"source_last_seq">>, RepRecProps, ?LOWEST_SEQ),
            OldHistory = get_value(<<"history">>, RepRecProps, []),
            ?xdcr_info("Records on source and target the same session id, "
                       "a valid history: ~p", [OldHistory]),
            {OldSeqNum,
             get_value(<<"docs_checked">>, RepRecProps, 0),
             get_value(<<"docs_written">>, RepRecProps, 0),
             get_value(<<"data_replicated">>, RepRecProps, 0),
             OldHistory};
        false ->
            SourceHistory = get_value(<<"history">>, RepRecProps, []),
            TargetHistory = get_value(<<"history">>, RepRecPropsTgt, []),
            ?xdcr_info("Replication records differ. "
                       "Scanning histories to find a common ancestor.", []),
            ?xdcr_debug("Record on source:~p~nRecord on target:~p~n",
                        [RepRecProps, RepRecPropsTgt]),
            compare_rep_history(SourceHistory, TargetHistory)
    end.

compare_rep_history(S, T) when S =:= [] orelse T =:= [] ->
    ?xdcr_info("no common ancestry -- performing full replication", []),
    {?LOWEST_SEQ, 0, 0, 0, []};

compare_rep_history([{S} | SourceRest], [{T} | TargetRest] = Target) ->
    SourceId = get_value(<<"session_id">>, S),
    case has_session_id(SourceId, Target) of
        true ->
            RecordSeqNum = get_value(<<"recorded_seq">>, S, ?LOWEST_SEQ),
            ?xdcr_info("found a common replication record with source_seq ~p",
                       [RecordSeqNum]),
            {RecordSeqNum,
             get_value(<<"docs_checked">>, S, 0),
             get_value(<<"docs_written">>, S, 0),
             get_value(<<"data_replicated">>, S, 0),
             SourceRest};
        false ->
            TargetId = get_value(<<"session_id">>, T),
            case has_session_id(TargetId, SourceRest) of
                true ->
                    RecordSeqNum = get_value(<<"recorded_seq">>, T, ?LOWEST_SEQ),
                    ?xdcr_info("found a common replication record with source_seq ~p",
                               [RecordSeqNum]),
                    {RecordSeqNum,
                     get_value(<<"docs_checked">>, T, 0),
                     get_value(<<"docs_written">>, T, 0),
                     get_value(<<"data_replicated">>, T, 0),
                     TargetRest};
                false ->
                    compare_rep_history(SourceRest, TargetRest)
            end
    end.

has_session_id(_SessionId, []) ->
    false;
has_session_id(SessionId, [{Props} | Rest]) ->
    case get_value(<<"session_id">>, Props, nil) of
        SessionId ->
            true;
        _Else ->
            has_session_id(SessionId, Rest)
    end.

target_uri_to_node(TgtURI) ->
    TargetURI = binary_to_list(TgtURI),
    [_Prefix, NodeDB] = string:tokens(TargetURI, "@"),
    [Node, _Bucket] = string:tokens(NodeDB, "/"),
    Node.

get_changes_queue_stats(#rep_state{changes_queue = ChangesQueue} = _State) ->
    ChangesQueueSize = case couch_work_queue:size(ChangesQueue) of
                           closed ->
                               0;
                           QueueSize ->
                               QueueSize
                       end,
    %% num of docs in changes queue
    ChangesQueueDocs = case couch_work_queue:item_count(ChangesQueue) of
                           closed ->
                               0;
                           QueueDocs ->
                               QueueDocs
                       end,

    {ChangesQueueSize, ChangesQueueDocs}.

