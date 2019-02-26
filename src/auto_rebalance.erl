%% @author Couchbase <info@couchbase.com>
%% @copyright 2019 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% Auto-rebalance: Schedule and trigger an automatic rebalance.
%%
%% This will be used to retry rebalance upon failure. Additional
%% uses cases will be supported in future.
%%

-module(auto_rebalance).

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/0]).
-export([retry_rebalance/5,
         cancel_any_pending_retry/1,
         cancel_any_pending_retry_async/1,
         cancel_pending_retry/2,
         cancel_pending_retry_async/2,
         get_pending_retry/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(retry_rebalance, { known_nodes      :: [term()],
                           eject_nodes      :: [term()],
                           delta_recov_bkts :: [term()],
                           rebalance_id     :: binary(),
                           retry_check      :: [term()],
                           state            :: pending | in_progress,
                           attempts         :: non_neg_integer(),
                           timer_ref        :: undefined | reference()
                         }).

-record(state, {state :: idle | #retry_rebalance{}}).

-define(SERVER, {via, leader_registry, ?MODULE}).

%% APIs
start_link() ->
    misc:start_singleton(gen_server, ?MODULE, [], []).

retry_rebalance(KnownNodes, EjectNodes, DRBuckets, RebalanceId, Chk) ->
    case auto_rebalance_settings:is_retry_enabled() of
        true ->
            cast({rebalance, KnownNodes, EjectNodes, DRBuckets, RebalanceId,
                  Chk}),
            true;
        false ->
            ?log_debug("Retry rebalance is not enabled. Failed rebalance "
                       "with Id ~s will not be retried.", [RebalanceId]),
            false
    end.

cancel_any_pending_retry(CancelledBy) ->
    call({cancel_any_pending_retry, CancelledBy}).

cancel_any_pending_retry_async(CancelledBy) ->
    cast({cancel_any_pending_retry, CancelledBy}).

cancel_pending_retry(RebalanceId, CancelledBy) ->
    call({cancel_pending_retry, RebalanceId, CancelledBy}).

cancel_pending_retry_async(RebalanceId, CancelledBy) ->
    cast({cancel_pending_retry, RebalanceId, CancelledBy}).

get_pending_retry() ->
    call(get_pending_retry).

%% gen_server callbacks
init([]) ->
    {ok, reset_state()}.

handle_cast({rebalance, KnownNodes, EjectNodes, DRBuckets, Id, Chk},
            #state{state = idle} = State) ->
    Count = 1,
    AfterS = auto_rebalance_settings:get_retry_after(ns_config:latest()),
    TRef = schedule_retry(Id, Count, AfterS),
    RS = #retry_rebalance{known_nodes = KnownNodes,
                          eject_nodes = EjectNodes,
                          delta_recov_bkts = DRBuckets,
                          rebalance_id = Id,
                          retry_check = Chk,
                          state = pending,
                          attempts = Count,
                          timer_ref = TRef},
    {noreply, State#state{state = RS}};

handle_cast({rebalance, KNs, ENs, DRBuckets, Id, Chk},
            #state{state = #retry_rebalance{delta_recov_bkts = PrevDRB,
                                            rebalance_id = PrevId,
                                            attempts = Count,
                                            timer_ref = PrevTRef} = RS} = S) ->
    NewState = case Id =:= PrevId of
                   true ->
                       %% Since this is a retry of a previous rebalance,
                       %% the timer should have been expired.
                       false = erlang:read_timer(PrevTRef),

                       %% Validate arguments match
                       true = DRBuckets =:= PrevDRB,

                       Cfg = ns_config:latest(),
                       Max = auto_rebalance_settings:get_retry_max(Cfg),
                       AfterS = auto_rebalance_settings:get_retry_after(Cfg),
                       case Count =:= Max of
                           true ->
                               ale:info(?USER_LOGGER,
                                        "Rebalance with Id ~s will not be "
                                        "retried. Exhausted all retries. "
                                        "Retry count ~p", [Id, Count]),
                               reset_state();
                           _ ->
                               NewCount = Count + 1,
                               TRef = schedule_retry(Id, NewCount, AfterS),
                               RS1 = RS#retry_rebalance{state = pending,
                                                        known_nodes = KNs,
                                                        eject_nodes = ENs,
                                                        retry_check = Chk,
                                                        attempts = NewCount,
                                                        timer_ref = TRef},
                               S#state{state = RS1}
                       end;
                   false ->
                       ?log_error("Retry rebalance encountered Id mismatch. "
                                  "Rebalance with Id ~s will not be retried. "
                                  "Pending rebalance with Id ~s will be "
                                  "cancelled.", [Id, PrevId]),
                       erlang:cancel_timer(PrevTRef),
                       misc:flush(retry_rebalance),
                       reset_state()
               end,
    {noreply, NewState};

handle_cast({cancel_any_pending_retry, CancelledBy},
            #state{state = #retry_rebalance{rebalance_id = ID,
                                            timer_ref = TRef}}) ->
    NewState = cancel_rebalance(ID, TRef, CancelledBy),
    {noreply, NewState};

handle_cast({cancel_any_pending_retry, _CancelledBy}, State) ->
    {noreply, State};

handle_cast({cancel_pending_retry, RebID, CancelledBy},
            #state{state = #retry_rebalance{rebalance_id = PendingID,
                                            timer_ref = TRef}} = State) ->
    NewState = case RebID =:= PendingID of
                   true ->
                       cancel_rebalance(PendingID, TRef, CancelledBy);
                   false ->
                       ale:info(?USER_LOGGER,
                                "Pending rebalance will not be cancelled due "
                                "to rebalance Id mismatch. "
                                "Id passed by the caller:~s. "
                                "Id of pending rebalance:~s.",
                                [RebID, PendingID]),
                       State
               end,
    {noreply, NewState};

handle_cast({cancel_pending_retry, _RebID, _CancelledBy}, State) ->
    {noreply, State};

handle_cast(Cast, State) ->
    ?log_warning("Unexpected cast ~p when in state:~n~p", [Cast, State]),
    {noreply, State}.

handle_call(get_pending_retry, _From,
            #state{state = #retry_rebalance{known_nodes = KN,
                                            eject_nodes = EN,
                                            delta_recov_bkts = DRBkts,
                                            rebalance_id = ID,
                                            state = RetryState,
                                            attempts = Count,
                                            timer_ref = TRef}} = State) ->
    true = TRef =/= undefined,
    TimeS = case erlang:read_timer(TRef) of
                false ->
                    %% Can happen when timer has expired
                    0;
                TimeMS ->
                    TimeMS/1000
            end,
    Max = auto_rebalance_settings:get_retry_max(ns_config:latest()),
    RV = [{retry_rebalance, RetryState}, {rebalance_id, ID},
          {known_nodes, KN}, {eject_nodes, EN},
          {delta_recovery_buckets, DRBkts},
          {attempts_remaining, Max - Count + 1},
          {retry_after_secs, TimeS}],
    {reply, RV, State};

handle_call(get_pending_retry, _From,  #state{state = idle} = State) ->
    {reply, [{retry_rebalance, not_pending}], State};

handle_call({cancel_any_pending_retry, _} = Call, _From, State) ->
    {noreply, NewState} = handle_cast(Call, State),
    {reply, ok, NewState};

handle_call({cancel_pending_retry, _, _} = Call, _From, State) ->
    {noreply, NewState} = handle_cast(Call, State),
    {reply, ok, NewState};

handle_call(Call, From, State) ->
    ?log_warning("Unexpected call ~p from ~p when in state:~n~p",
                 [Call, From, State]),
    {reply, nack, State}.

handle_info(retry_rebalance,
            #state{state = #retry_rebalance{known_nodes = KN, eject_nodes = EN,
                                            delta_recov_bkts = DB,
                                            retry_check = Chk,
                                            rebalance_id = ID} = RS} = S) ->
    NewState = case ns_orchestrator:retry_rebalance(KN, EN, DB, ID, Chk) of
                   ok ->
                       ?log_debug("Retrying rebalance with Id:~s, "
                                  "KnownNodes:~p, EjectNodes:~p, "
                                  "and Delta Recovery Buckets:~p ",
                                  [ID, KN, EN, DB]),
                       RS1 = RS#retry_rebalance{state = in_progress},
                       S#state{state = RS1};
                   Error ->
                       ale:info(?USER_LOGGER,
                                "Retry of rebalance with Id ~s failed with "
                                "error ~p. Operation will not be retried.",
                                [ID, Error]),
                       reset_state()
               end,
    {noreply, NewState};

handle_info(Info, State) ->
    ?log_warning("Unexpected message ~p when in state:~n~p", [Info, State]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions

reset_state() ->
    #state{state = idle}.

call(Call) ->
    misc:wait_for_global_name(?MODULE),
    gen_server:call(?SERVER, Call).

cast(Cast) ->
    misc:wait_for_global_name(?MODULE),
    gen_server:cast(?SERVER, Cast).

schedule_retry(Id, RetryCount, AfterS) ->
    ale:info(?USER_LOGGER,
             "Rebalance with Id ~s will be retried after ~p seconds. "
             "Retry attempt number ~p",
             [Id, AfterS, RetryCount]),
    erlang:send_after(AfterS * 1000, self(), retry_rebalance).

cancel_rebalance(ID, TRef, CancelledBy) ->
    ?log_debug("Cancelling pending rebalance with Id ~s. Cancelled by ~s.",
               [ID, CancelledBy]),
    erlang:cancel_timer(TRef),
    misc:flush(retry_rebalance),
    reset_state().
