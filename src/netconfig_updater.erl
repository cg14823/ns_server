-module(netconfig_updater).

-behaviour(gen_server).

%% API
-export([start_link/0,
         apply_config/1,
         change_external_listeners/2,
         ensure_tls_dist_started/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(s, {}).

-include_lib("kernel/include/net_address.hrl").
-include("ns_common.hrl").

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    proc_lib:start_link(?MODULE, init, [[]]).

apply_config(Config) ->
    gen_server:call(?MODULE, {apply_config, Config}, infinity).

change_external_listeners(Action, Config) ->
    gen_server:call(?MODULE, {change_listeners, Action, Config}, infinity).

ensure_tls_dist_started(Nodes) ->
    gen_server:call(?MODULE, {ensure_tls_dist_started, Nodes}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    ServerName = ?MODULE,
    register(ServerName, self()),
    ensure_ns_config_settings_in_order(),
    proc_lib:init_ack({ok, self()}),
    case misc:consult_marker(update_marker_path()) of
        {ok, [Cmd]} ->
            ?log_info("Found update netconfig marker: ~p", [Cmd]),
            case apply_and_delete_marker(Cmd) of
                ok -> ok;
                {error, Error} -> erlang:error(Error)
            end;
        false -> ok
    end,
    gen_server:enter_loop(?MODULE, [], #s{}, {local, ServerName}, hibernate).

handle_call({apply_config, Config}, _From, State) ->
    CurConfig = lists:map(
                  fun ({afamily, _}) ->
                          {afamily, cb_dist:address_family()};
                      ({nodeEncryption, _}) ->
                          {nodeEncryption, cb_dist:external_encryption()};
                      ({externalListeners, _}) ->
                          {externalListeners, cb_dist:external_listeners()}
                  end, Config),
    Config2 = lists:usort(Config) -- CurConfig,
    CurConfig2 = lists:usort(CurConfig) -- Config,
    AFamily = proplists:get_value(afamily, Config2),
    case check_nodename_resolvable(node(), AFamily) of
        ok -> handle_with_marker(apply_config, CurConfig2, Config2, State);
        {error, _} = Error -> {reply, Error, State, hibernate}
    end;

handle_call({change_listeners, Action, Config}, _From, State) ->
    CurProtos = cb_dist:external_listeners(),
    AFamily = proplists:get_value(afamily, Config, cb_dist:address_family()),
    NEncrypt = proplists:get_value(nodeEncryption, Config,
                                   cb_dist:external_encryption()),
    Proto = {AFamily, NEncrypt},
    Protos = case Action of
                 enable -> lists:usort([Proto | CurProtos]);
                 disable -> CurProtos -- [Proto]
             end,
    NewConfig = [{externalListeners, Protos}],
    CurConfig = [{externalListeners, CurProtos}],
    handle_with_marker(apply_config, CurConfig, NewConfig, State);

handle_call({ensure_tls_dist_started, Nodes}, _From, State) ->
    ?log_info("Check that tls distribution server has started and "
              "the following nodes are connected: ~p", [Nodes]),

    NotStartedTLSListeners =
        case cb_dist:ensure_config() of
            ok -> [];
            {error, {not_started, List}} ->
                [L || L = {_, Encrypted} <- List, Encrypted =:= true]
        end,

    case NotStartedTLSListeners of
        [] ->
            NotConnected = [N || N <- Nodes, false <- [net_kernel:connect(N)]],
            case NotConnected of
                [] ->
                    {reply, ok, State};
                NotConnected ->
                    Reason = format_error({not_connected, NotConnected}),
                    {reply, {error, iolist_to_binary(Reason)}, State}
            end;
        NotStartedListeners ->
            Reason = format_error({not_started_listeners, NotStartedListeners}),
            {reply, {error, iolist_to_binary(Reason)}, State}
    end;

handle_call(Request, _From, State) ->
    ?log_error("Unhandled call: ~p", [Request]),
    {noreply, State, hibernate}.

handle_cast(Msg, State) ->
    ?log_error("Unhandled cast: ~p", [Msg]),
    {noreply, State, hibernate}.

handle_info(Info, State) ->
    ?log_error("Unhandled info: ~p", [Info]),
    {noreply, State, hibernate}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_with_marker(Command, From, To, State) ->
    case misc:marker_exists(update_marker_path()) of
        false ->
            MarkerStr = io_lib:format("{~p, ~p}.", [Command, From]),
            misc:create_marker(update_marker_path(), MarkerStr),
            case apply_and_delete_marker({Command, To}) of
                ok -> {reply, ok, State, hibernate};
                {error, _} = Error -> {stop, Error, Error, State}
            end;
        true ->
            {stop, marker_exists, State}
    end.

apply_and_delete_marker(Cmd) ->
    Res = case Cmd of
              {apply_config, To} ->
                  apply_config_unprotected(To)
          end,
    (Res =:= ok) andalso misc:remove_marker(update_marker_path()),
    Res.

apply_config_unprotected([]) -> ok;
apply_config_unprotected(Config) ->
    ?log_info("Node is going to apply the following settings: ~p", [Config]),
    try
        AFamily = proplists:get_value(afamily, Config,
                                      cb_dist:address_family()),
        NEncrypt = proplists:get_value(nodeEncryption, Config,
                                       cb_dist:external_encryption()),
        ExternalListeners = proplists:get_value(externalListeners, Config,
                                                cb_dist:external_listeners()),
        case cb_dist:update_config(Config) of
            {ok, Listeners} ->
                verify_listeners_started(Listeners, Config);
            {error, Reason} ->
                erlang:throw({update_cb_dist_config_error,
                              cb_dist:format_error(Reason)})
        end,
        case need_local_update(Config) of
            true -> change_local_dist_proto(AFamily, false);
            false -> ok
        end,
        case need_external_update(Config) of
            true -> change_ext_dist_proto(AFamily, NEncrypt);
            false -> ok
        end,
        ns_config:set({node, node(), address_family},
                      AFamily),
        ns_config:set({node, node(), node_encryption},
                      NEncrypt),
        ns_config:set({node, node(), erl_external_listeners},
                      ExternalListeners),
        ?log_info("Node network settings (~p) successfully applied", [Config]),
        ok
    catch
        throw:Error ->
            Msg = iolist_to_binary(format_error(Error)),
            ?log_error("~s", [Msg]),
            {error, Msg}
    end.

need_local_update(Config) ->
    proplists:get_value(afamily, Config) =/= undefined.

need_external_update(Config) ->
    (proplists:get_value(afamily, Config) =/= undefined) orelse
        (proplists:get_value(nodeEncryption, Config) =/= undefined).

verify_listeners_started(Listeners, Config) ->
    Protos = proplists:get_value(externalListeners, Config),
    NotStarted = case Protos of
                     undefined -> [];
                     _ -> Protos -- Listeners
                 end,
    case NotStarted of
        [] -> ok;
        L -> erlang:throw({start_listeners_failed, L})
    end.

change_local_dist_proto(ExpectedFamily, ExpectedEncryption) ->
    ?log_info("Reconnecting to babysitter and restarting couchdb since local "
              "dist protocol settings changed, expected afamily is ~p, "
              "expected encryption is ~p",
              [ExpectedFamily, ExpectedEncryption]),
    Babysitter = ns_server:get_babysitter_node(),
    case cb_dist:reload_config(Babysitter) of
        {ok, _} -> ok;
        {error, Error} ->
            erlang:throw({reload_cb_dist_config_error, Babysitter,
                          cb_dist:format_error(Error)})
    end,
    ensure_connection_proto(Babysitter,
                            ExpectedFamily, ExpectedEncryption, 10),
    %% Curently couchdb doesn't support gracefull change of afamily
    %% so we have to restart it. Unfortunatelly we can't do it without
    %% restarting ns_server.
    case ns_server_cluster_sup:restart_ns_server() of
        {ok, _} ->
            check_connection_proto(ns_node_disco:couchdb_node(),
                                   ExpectedFamily, ExpectedEncryption);
        {error, not_running} -> ok;
        Error2 -> erlang:throw({ns_server_restart_error, Error2})
    end.

change_ext_dist_proto(ExpectedFamily, ExpectedEncryption) ->
    Nodes = ns_node_disco:nodes_wanted() -- [node()],
    ?log_info("Reconnecting to all known erl nodes since dist protocol "
              "settings changed, expected afamily is ~p, expected encryption "
              "is ~p, nodes: ~p", [ExpectedFamily, ExpectedEncryption, Nodes]),
    [ensure_connection_proto(N, ExpectedFamily, ExpectedEncryption, 10)
        || N <- Nodes],
    ok.

ensure_connection_proto(Node, _Family, _Encr, Retries) ->
    ensure_connection_proto(Node, _Family, _Encr, Retries, 10).

ensure_connection_proto(Node, _Family, _Encr, Retries, _) when Retries =< 0 ->
    erlang:throw({exceeded_retries, Node});
ensure_connection_proto(Node, Family, Encryption, Retries, RetryTimeout) ->
    erlang:disconnect_node(Node),
    case net_kernel:connect(Node) of
        true ->
            ?log_debug("Reconnected to ~p, checking connection type...",
                       [Node]),
            try check_connection_proto(Node, Family, Encryption) of
                ok -> ok
            catch
                throw:Reason ->
                    ?log_error("Checking node ~p connection type failed with "
                               "reason: ~p, will sleep for ~p ms, "
                               "retries left: ~p",
                               [Node, Reason, RetryTimeout, Retries - 1]),
                    Retries > 1 andalso timer:sleep(RetryTimeout),
                    ensure_connection_proto(Node, Family, Encryption,
                                            Retries - 1, RetryTimeout * 2)
            end;
        false ->
            ?log_error("Failed to connect to node ~p, will sleep for ~p ms, "
                       "retries left: ~p", [Node, RetryTimeout, Retries - 1]),
            Retries > 1 andalso timer:sleep(RetryTimeout),
            ensure_connection_proto(Node, Family, Encryption, Retries - 1,
                                    RetryTimeout * 2)
    end.

check_connection_proto(Node, Family, Encryption) ->
    Proto = case Encryption of
                true -> proxy;
                false -> tcp
            end,
    case net_kernel:node_info(Node) of
        {ok, Info} ->
            case proplists:get_value(address, Info) of
                %% Workaround for a bug in inet_tls_dist.erl
                %% address family is always set to inet, even when the socket
                %% is actually an inet6 socket
                #net_address{address = {{_, _, _, _, _, _, _, _}, _},
                             protocol = proxy,
                             family = inet} when Proto == proxy,
                                                 Family == inet6 -> ok;
                #net_address{protocol = Proto, family = Family} -> ok;
                A -> erlang:throw({wrong_proto, Node, A})
            end;
        {error, Error} ->
            erlang:throw({node_info, Node, Error})
    end.

format_error({update_cb_dist_config_error, Msg}) ->
    io_lib:format("Failed to update cb_dist configuration file: ~s", [Msg]);
format_error({reload_cb_dist_config_error, Node, Msg}) ->
    io_lib:format("Failed to reload cb_dist configuration file on node ~p: ~s",
                  [Node, Msg]);
format_error({ns_server_restart_error, Error}) ->
    io_lib:format("Restart error: ~p", [Error]);
format_error({node_info, Node, Error}) ->
    io_lib:format("Failed to get connection info to node ~p: ~p",
                  [Node, Error]);
format_error({wrong_proto, Node, _}) ->
    io_lib:format("Couldn't establish connection of desired type to node ~p",
                  [Node]);
format_error({exceeded_retries, Node}) ->
    io_lib:format("Reconnect to ~p retries exceeded", [Node]);
format_error({host_ip_not_allowed, Addr}) ->
    io_lib:format("Can't change address family when node is using raw IP "
                  "addr: ~p", [Addr]);
format_error({rename_failed, Addr, Reason}) ->
    io_lib:format("Address change (~p) failed with reason: ~p", [Addr, Reason]);
format_error({start_listeners_failed, L}) ->
    ProtoStrs = [cb_dist:netsettings2str(P) || P <- L],
    io_lib:format("Failed to start listeners: ~s",
                  [string:join(ProtoStrs, ", ")]);
format_error({not_connected, Nodes}) ->
    NodesStr = string:join([atom_to_list(N) || N <- Nodes], ", "),
    io_lib:format("Could not connect to nodes: ~s", [NodesStr]);
format_error({not_started_listeners, Listeners}) ->
    ListenersStr = string:join([cb_dist:netsettings2str(L) || L <- Listeners],
                               ", "),
    io_lib:format("Could not start distribution servers: ~s", [ListenersStr]);
format_error(R) ->
    io_lib:format("~p", [R]).

update_marker_path() ->
    path_config:component_path(data, "netconfig_marker").

check_nodename_resolvable(_, undefined) -> ok;
check_nodename_resolvable('nonode@nohost', _) -> ok;
check_nodename_resolvable(Node, AFamily) ->
    {_, Hostname} = misc:node_name_host(Node),
    case inet:getaddr(Hostname, AFamily) of
        {ok, _} -> ok;
        {error, Reason} ->
            M = io_lib:format("Unable to resolve ~s address for ~s: ~p",
                              [misc:afamily2str(AFamily), Hostname, Reason]),
            {error, iolist_to_binary(M)}
    end.

%% This function is needed in two cases:
%%  - migration for address family settings to 6.5
%%  - allow manual changes in dist_cfg file
ensure_ns_config_settings_in_order() ->
    RV = ns_config:run_txn(
           fun (Cfg, Set) ->
               AFamily = cb_dist:address_family(),
               NodeEncryption = cb_dist:external_encryption(),
               Listeners = cb_dist:external_listeners(),
               Cfg1 =
                   case ns_config:search_node(Cfg, address_family) of
                       {value, AFamily} -> Cfg;
                       _ ->
                           Set({node, node(), address_family}, AFamily, Cfg)
                   end,
               Cfg2 =
                   case ns_config:search_node(Cfg, node_encryption) of
                       {value, NodeEncryption} -> Cfg1;
                       _ ->
                           Set({node, node(), node_encryption}, NodeEncryption,
                               Cfg1)
                   end,
               Cfg3 =
                   case ns_config:search_node(Cfg, erl_external_listeners) of
                       {value, Listeners} -> Cfg2;
                       _ ->
                           Set({node, node(), erl_external_listeners},
                               Listeners, Cfg2)
                   end,
               {commit, Cfg3}
           end),
    {commit, _} = RV,
    ok.
