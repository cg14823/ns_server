%% @author Couchbase <info@couchbase.com>
%% @copyright 2010-2019 Couchbase, Inc.
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
%% Monitor and maintain the vbucket layout of each bucket.
%% There is one of these per bucket.
%%
%% @doc Failover implementation.
%%

-module(failover).

-include("cut.hrl").
-include("ns_common.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([run/2, is_possible/1, orchestrate/2, get_failover_vbuckets/2]).

-define(DATA_LOST, 1).
-define(FAILOVER_OPS_TIMEOUT, ?get_timeout(failover_ops_timeout, 10000)).


run(Nodes, AllowUnsafe) ->
    case is_possible(Nodes) of
        ok ->
            Result = leader_activities:run_activity(
                       failover, majority,
                       ?cut(orchestrate(Nodes, [durability_aware])),
                       [{unsafe, AllowUnsafe}]),

            case Result of
                {leader_activities_error, _, {quorum_lost, _}} ->
                    orchestration_unsafe;
                {leader_activities_error, _, {no_quorum, _}} ->
                    orchestration_unsafe;
                _ ->
                    Result
            end;
        Error ->
            Error
    end.

orchestrate(Nodes, Options) ->
    case pre_failover_config_sync(Nodes, Options) of
        ok ->
            do_orchestrate(Nodes, Options);
        Error ->
            Error
    end.

do_orchestrate(Nodes, Options) ->
    ale:info(?USER_LOGGER, "Starting failing over ~p", [Nodes]),
    master_activity_events:note_failover(Nodes),

    ErrorNodes = failover(Nodes, Options),

    case ErrorNodes of
        [] ->
            ns_cluster:counter_inc(failover_complete),
            ale:info(?USER_LOGGER, "Failed over ~p: ok", [Nodes]);
        _ ->
            ns_cluster:counter_inc(failover_incomplete),
            ale:error(?USER_LOGGER,
                      "Failover couldn't "
                      "complete on some nodes:~n~p", [ErrorNodes])
    end,

    ok = leader_activities:deactivate_quorum_nodes(Nodes),

    ns_cluster:counter_inc(failover),
    deactivate_nodes(Nodes),

    ok.

pre_failover_config_sync(FailedNodes, Options) ->
    case durability_aware(Options) of
        true ->
            Timeout = ?get_timeout(failover_config_pull, 10000),
            SyncNodes = config_sync_nodes(FailedNodes),

            ?log_info("Going to pull config "
                      "from ~p before failover", [SyncNodes]),

            case ns_config_rep:pull_remotes(SyncNodes, Timeout) of
                ok ->
                    ok;
                Error ->
                    ?log_error("Config pull from ~p failed: ~p",
                               [SyncNodes, Error]),
                    config_sync_failed
            end;
        false ->
            ok
    end.

config_sync_nodes(FailedNodes) ->
    Nodes = ns_cluster_membership:get_nodes_with_status(_ =/= inactiveFailed),
    Nodes -- FailedNodes.

deactivate_nodes([]) ->
    ok;
deactivate_nodes(Nodes) ->
    ale:info(?USER_LOGGER, "Deactivating failed over nodes ~p", [Nodes]),
    ns_cluster_membership:deactivate(Nodes).

%% @doc Fail one or more nodes. Doesn't eject the node from the cluster. Takes
%% effect immediately.
failover(Nodes, Options) ->
    lists:umerge([failover_buckets(Nodes, Options),
                  failover_services(Nodes)]).

failover_buckets(Nodes, Options) ->
    Results =
        lists:foldl(
          fun ({Bucket, BucketConfig}, Acc) ->
                  %% Verify that the server list is consistent with cluster
                  %% membership states.
                  ok = ns_janitor:check_server_list(Bucket, BucketConfig),

                  try failover_bucket(Bucket, BucketConfig, Nodes, Options) of
                      Res ->
                          Res ++ Acc
                  catch throw:{failed, Msg} ->
                          ?log_error("Caught failover exception: ~p", [Msg]),
                          update_failover_vbuckets(Acc),
                          ns_orchestrator:request_janitor_run({bucket, Bucket}),
                          throw({failover_failed, Msg})
                  end
          end, [], ns_bucket:get_buckets()),
    update_failover_vbuckets(Results),
    failover_handle_results(Results).

update_failover_vbuckets(Results) ->
    GroupedByNode =
        misc:groupby_map(fun (L) ->
                                 Node   = proplists:get_value(node, L),
                                 Bucket = proplists:get_value(bucket, L),
                                 VBs    = proplists:get_value(vbuckets, L),

                                 {Node, {Bucket, VBs}}
                         end, Results),
    {commit, _} =
        ns_config:run_txn(
          fun (Config, Set) ->
                  {commit,
                   lists:foldl(?cut(update_failover_vbuckets(Set, _, _)),
                               Config, GroupedByNode)}
          end).

update_failover_vbuckets(Set, {Node, BucketResults}, Config) ->
    ExistingBucketResults = get_failover_vbuckets(Config, Node),
    Merged = merge_failover_vbuckets(ExistingBucketResults, BucketResults),

    ?log_debug("Updating failover_vbuckets for ~p with ~p~n"
               "Existing vbuckets: ~p~nNew vbuckets: ~p",
               [Node, Merged, ExistingBucketResults, BucketResults]),

    case Merged of
        ExistingBucketResults ->
            Config;
        _ ->
            Set({node, Node, failover_vbuckets}, Merged, Config)
    end.

merge_failover_vbuckets(ExistingBucketResults, BucketResults) ->
    Grouped =
        misc:groupby_map(fun functools:id/1,
                         ExistingBucketResults ++ BucketResults),
    lists:map(fun ({B, [VBs1, VBs2]}) when is_list(VBs1), is_list(VBs2) ->
                      {B, lists:usort(VBs1 ++ VBs2)};
                  ({B, [VBs]}) when is_list(VBs) ->
                      {B, lists:sort(VBs)}
              end, Grouped).

-ifdef(TEST).
merge_failover_vbuckets_test() ->
    ?assertEqual(
       [{"test", [0, 1, 2, 3]}, {"test1", [0, 1, 2, 3]}],
       merge_failover_vbuckets(
         [], [{"test", [0, 1, 2, 3]}, {"test1", [0, 1, 2, 3]}])),
    ?assertEqual(
       [{"test", [0, 1, 2, 3]}, {"test1", [0, 1, 2, 3]}],
       merge_failover_vbuckets(
         [{"test", [0, 1, 2, 3]}], [{"test1", [0, 1, 2, 3]}])),
    ?assertEqual(
       [{"test", [0, 1, 2, 3]}],
       merge_failover_vbuckets([{"test", [0, 3]}], [{"test", [1, 2]}])),
    ?assertEqual(
       [{"test", [0, 1, 2, 3]}],
       merge_failover_vbuckets([{"test", [0, 2, 3]}], [{"test", [1, 2]}])).
-endif.

failover_handle_results(Results) ->
    NodeStatuses =
        misc:groupby_map(fun (Result) ->
                                 Node   = proplists:get_value(node, Result),
                                 Status = proplists:get_value(status, Result),

                                 {Node, Status}
                         end, Results),

    lists:filtermap(fun ({Node, Statuses}) ->
                            NonOKs = [S || S <- Statuses, S =/= ok],

                            case NonOKs of
                                [] ->
                                    false;
                                _ ->
                                    {true, Node}
                            end
                    end, NodeStatuses).

failover_bucket(Bucket, BucketConfig, Nodes, Options) ->
    master_activity_events:note_bucket_failover_started(Bucket, Nodes),

    Type   = ns_bucket:bucket_type(BucketConfig),
    Result = do_failover_bucket(Type, Bucket, BucketConfig, Nodes, Options),

    master_activity_events:note_bucket_failover_ended(Bucket, Nodes),

    Result.

do_failover_bucket(memcached, Bucket, BucketConfig, Nodes, _Options) ->
    failover_memcached_bucket(Nodes, Bucket, BucketConfig),
    [];
do_failover_bucket(membase, Bucket, BucketConfig, Nodes, Options) ->
    Map = proplists:get_value(map, BucketConfig, []),
    R = failover_membase_bucket(Nodes, Bucket, BucketConfig, Map, Options),

    [[{bucket, Bucket},
      {node, N},
      {status, R},
      {vbuckets, node_vbuckets(Map, N)}] || N <- Nodes].

failover_services(Nodes) ->
    Config    = ns_config:get(),
    Services0 = lists:flatmap(
                  ns_cluster_membership:node_services(Config, _), Nodes),
    Services  = lists:usort(Services0) -- [kv],

    Results = lists:flatmap(failover_service(Config, _, Nodes), Services),
    failover_handle_results(Results).

failover_service(Config, Service, Nodes) ->
    ns_cluster_membership:failover_service_nodes(Config, Service, Nodes),

    %% We're refetching the config since failover_service_nodes updated the
    %% one that we had.
    Result = service_janitor:complete_service_failover(ns_config:get(),
                                                       Service,
                                                       Nodes),
    case Result of
        ok ->
            ?log_debug("Failed over service ~p on nodes ~p successfully",
                       [Service, Nodes]);
        _ ->
            ?log_error("Failed to failover service ~p on nodes ~p: ~p",
                       [Service, Nodes, Result])
    end,

    [[{node, Node},
      {status, Result},
      {service, Service}] || Node <- Nodes].

failover_memcached_bucket(Nodes, Bucket, BucketConfig) ->
    remove_nodes_from_server_list(Nodes, Bucket, BucketConfig).

failover_membase_bucket(Nodes, Bucket, BucketConfig, [], _Options) ->
    %% this is possible if bucket just got created and ns_janitor didn't get a
    %% chance to create a map yet; or alternatively, if it failed to do so
    %% because, for example, one of the nodes was down
    failover_membase_bucket_with_no_map(Nodes, Bucket, BucketConfig);
failover_membase_bucket(Nodes, Bucket, BucketConfig, Map, Options) ->
    failover_membase_bucket_with_map(Nodes, Bucket, BucketConfig, Map, Options).

failover_membase_bucket_with_no_map(Nodes, Bucket, BucketConfig) ->
    ?log_debug("Skipping failover of bucket ~p because it has no vbuckets. "
               "Config:~n~p", [Bucket, BucketConfig]),

    %% we still need to make sure to remove ourselves from the bucket server
    %% list
    remove_nodes_from_server_list(Nodes, Bucket, BucketConfig),
    ok.

failover_membase_bucket_with_map(Nodes, Bucket, BucketConfig, Map, Options) ->
    NewMap = fix_vbucket_map(Nodes, Bucket, Map, Options),
    true = (NewMap =/= undefined),

    ?log_debug("Original vbucket map: ~p~n"
               "VBucket map with failover applied: ~p", [Map, NewMap]),

    case [I || {I, [undefined|_]} <- misc:enumerate(NewMap, 0)] of
        [] -> ok; % Phew!
        MissingVBuckets ->
            ?rebalance_error("Lost data in ~p for ~w", [Bucket, MissingVBuckets]),
            ?user_log(?DATA_LOST,
                      "Data has been lost for ~B% of vbuckets in bucket ~p.",
                      [length(MissingVBuckets) * 100 div length(Map), Bucket])
    end,

    ns_bucket:set_fast_forward_map(Bucket, undefined),
    ns_bucket:set_map(Bucket, NewMap),
    remove_nodes_from_server_list(Nodes, Bucket, BucketConfig),

    CleanupOptions = janitor_cleanup_options(Nodes, Options),
    case (catch ns_janitor:cleanup(Bucket, CleanupOptions)) of
        ok ->
            ok;
        {error, _, BadNodes} ->
            ?rebalance_error("Skipped vbucket activations and "
                             "replication topology changes because not "
                             "all remaining nodes were found to have "
                             "healthy bucket ~p: ~p", [Bucket, BadNodes]),
            janitor_failed;
        Error ->
            ?rebalance_error("Janitor cleanup of ~p "
                             "failed after failover of ~p: ~p",
                             [Bucket, Nodes, Error]),
            janitor_failed
    end.

janitor_cleanup_options(FailedNodes, FailoverOptions) ->
    [{sync_nodes, config_sync_nodes(FailedNodes)},
     {pull_config, false},
     {push_config, durability_aware(FailoverOptions)}].

durability_aware(Options) ->
    cluster_compat_mode:preserve_durable_mutations() andalso
        proplists:get_bool(durability_aware, Options).

fix_vbucket_map(FailoverNodes, Bucket, Map, Options) ->
    case durability_aware(Options) of
        true ->
            fix_vbucket_map_durability_aware(FailoverNodes, Bucket, Map);
        false ->
            mb_map:promote_replicas(Map, FailoverNodes)
    end.

fix_vbucket_map_durability_aware(FailoverNodes, Bucket, Map) ->
    EnumeratedMap = misc:enumerate(Map, 0),

    FixedChains =
        dict:from_list(
          case [C || C = {_, [Master | _]} <- EnumeratedMap,
                     lists:member(Master, FailoverNodes)] of
              [] ->
                  [];
              ChainsNeedFixing ->
                  fix_chains(Bucket, FailoverNodes, ChainsNeedFixing)
          end),
    lists:map(
      fun ({VB, Chain}) ->
              case dict:find(VB, FixedChains) of
                  {ok, NewChain} ->
                      NewChain;
                  error ->
                      mb_map:promote_replica(Chain, FailoverNodes)
              end
      end, EnumeratedMap).

fix_chains(Bucket, FailoverNodes, Chains) ->
    NodesToQuery = nodes_to_query(Chains, FailoverNodes),

    {Info, BadNodes} =
        janitor_agent:query_vbuckets(
          Bucket, NodesToQuery,
          [high_seqno, high_prepared_seqno],
          [stop_replications, {timeout, ?FAILOVER_OPS_TIMEOUT}]),

    BadNodes =:= [] orelse
        throw_failover_error("Failed to get failover info for bucket ~p: ~p",
                             [Bucket, BadNodes]),

    ?log_debug("Retrieved the following vbuckets information: ~p",
               [dict:to_list(Info)]),

    [{VB, fix_chain(VB, Chain, Info, FailoverNodes)}
     || {VB, Chain} <- Chains].

fix_chain(VBucket, Chain, Info, FailoverNodes) ->
    NodeStates = janitor_agent:fetch_vbucket_states(VBucket, Info),
    WithFNodesRemoved = mb_map:promote_replica(Chain, FailoverNodes),

    case find_max_replica(WithFNodesRemoved, NodeStates) of
        not_found ->
            WithFNodesRemoved;
        MaxReplica ->
            [MaxReplica | lists:delete(MaxReplica, WithFNodesRemoved)]
    end.

nodes_to_query(Chains, FailoverNodes) ->
    NodeVBs =
        lists:flatmap(
          fun ({VB, Chain}) ->
                  [{Node, VB} || Node <- tl(Chain),
                                 Node =/= undefined,
                                 not lists:member(Node, FailoverNodes)]
          end, Chains),
    [{N, lists:usort(VBs)} ||
        {N, VBs} <- misc:groupby_map(fun functools:id/1, NodeVBs)].

throw_failover_error(Msg, Params) ->
    throw({failed, lists:flatten(io_lib:format(Msg, Params))}).

%% A replica is considered ahead of another replica if its last snapshot seqno
%% is greater, if they are the same, the replica with greater high_seqno is then
%% considered ahead.
find_max_replica(Chain, NodeStates) ->
    Get = fun (K, P) ->
                  V = proplists:get_value(K, P), true = V =/= undefined, V
          end,
    ChainStates =
        lists:filtermap(
          fun (undefined) ->
                  false;
              (Node) ->
                  case lists:keyfind(Node, 1, NodeStates) of
                      {Node, _, Props} ->
                          {true,
                           {Node,
                            {Get(high_prepared_seqno, Props),
                             Get(high_seqno, Props)}}};
                      false ->
                          false
                  end
          end, Chain),
    case ChainStates of
        [] ->
            not_found;
        _ ->
            {MaxReplica, _} = misc:min_by(fun ({_, SeqNos}, {_, MaxSeqNos}) ->
                                                  SeqNos > MaxSeqNos
                                          end, ChainStates),
            MaxReplica
    end.

remove_nodes_from_server_list(Nodes, Bucket, BucketConfig) ->
    Servers = proplists:get_value(servers, BucketConfig),
    ns_bucket:set_servers(Bucket, Servers -- Nodes).

node_vbuckets(Map, Node) ->
    [V || {V, Chain} <- misc:enumerate(Map, 0),
          lists:member(Node, Chain)].

is_possible(Nodes) ->
    ActiveNodes = lists:sort(ns_cluster_membership:active_nodes()),
    FailoverNodes = lists:sort(Nodes),
    case ActiveNodes of
        FailoverNodes ->
            last_node;
        _ ->
            case lists:subtract(FailoverNodes, ActiveNodes) of
                [] ->
                    case ns_cluster_membership:service_nodes(ActiveNodes, kv) of
                        FailoverNodes ->
                            last_node;
                        _ ->
                            ok
                    end;
                _ ->
                    unknown_node
            end
    end.

get_failover_vbuckets(Config, Node) ->
    ns_config:search(Config, {node, Node, failover_vbuckets}, []).
