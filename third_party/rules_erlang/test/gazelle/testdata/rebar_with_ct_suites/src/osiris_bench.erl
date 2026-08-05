%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_bench).

-include("osiris.hrl").
-include("osiris_peer_shim.hrl").

-export([run/1,
         stop/1,
         do_metrics/1,
         do_publish/1,
         test/1]).

-define(METRICS_INT_S, 10).

%% holds static or rarely changing fields
-record(cfg, {}).
-record(?MODULE, {cfg :: #cfg{}}).

-opaque state() :: #?MODULE{}.

-export_type([state/0]).

% -type spec() :: #{name := string(),
%                   in_flight := non_neg_integer()
%                   }.

test(Name) ->
    Spec = #{name => Name, in_flight => 5000},
    run(Spec).

run(#{name := Name} = Spec) ->
    {ok, Cwd} = file:get_cwd(),
    Dir0 = maps:get(directory, Spec, Cwd),
    Dir = filename:join([Dir0, ?MODULE, Name]),
    %% create cluster (if needed)
    [LeaderNode | Replicas] =
        Nodes = [start_secondary(N, Dir) || N <- [s1, s2, s3]],

    %% declare osiris cluster
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          retention => [{max_bytes, 100 * 1000 * 1000}],
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {ok, #{leader_pid := Leader2}} =
        osiris:start_cluster(Conf0#{name => Name ++ Name}),
    %% start metrics gatherer on leader node
    start_metrics_gatherer(node(Leader)),
    %%
    %% start publisher
    InFlight = maps:get(in_flight, Spec, 1000),
    start_publisher(node(Leader),
                    #{leader => Leader, in_flight => InFlight}),
    start_publisher(node(Leader2),
                    #{leader => Leader2, in_flight => InFlight}),
    Nodes.

stop(Nodes) when is_list(Nodes) ->
    [stop_peer(N) || N <- Nodes].

-if(?OTP_RELEASE >= 25).
stop_peer(RefOrName) ->
    %% peer:stop/1 not idempotent
    try
        ?PEER_MODULE:stop(RefOrName)
    catch exit:_:_Stacktrace ->
        ok
    end.
-else.
stop_peer(RefOrName) ->
    ?PEER_MODULE:stop(RefOrName).
-endif.

start_publisher(Node, Conf) ->
    erlang:spawn(Node, ?MODULE, do_publish, [Conf]).

do_publish(#{in_flight := InFlight} = Conf) ->
    do_publish0(Conf, InFlight).

do_publish0(Conf, 0) ->
    receive
        {osiris_written, _, Corrs} ->
            do_publish0(Conf, length(Corrs))
    after 1000000 ->
        exit(publish_timeout)
    end;
do_publish0(#{leader := Leader} = Conf, InFlight) ->
    Ref = make_ref(),
    ok = osiris:write(Leader, undefined, Ref, <<"datadata">>),
    do_publish0(Conf, InFlight - 1).

start_metrics_gatherer(Node) ->
    erlang:spawn(Node, ?MODULE, do_metrics, [#{}]).

do_metrics(O0) ->
    O = osiris_counters:overview(),
    O1 = maps:with(
             maps:keys(O0), O),
    _ = maps:map(
          fun(K, CC) ->
                  M = element(1, K),
                  N = element(2, K),
                  %% get last counters
                  CL = maps:get(K, O0),
                  Rates =
                      maps:fold(fun(F, V, Acc) ->
                                        LV = maps:get(F, CL),
                                        [{F, (V - LV) / ?METRICS_INT_S} | Acc]
                                end,
                                [], CC),
                  io:format("~s: ~s/~s - Rates ~w~n~n", [node(), M, N, Rates])
          end,
          O1),
    timer:sleep(?METRICS_INT_S * 1000),
    do_metrics(O).

start_secondary(NodeName, RunDir) ->
    Dir0 = filename:join(RunDir, NodeName),
    Host = get_current_host(),
    Dir = "'\"" ++ Dir0 ++ "\"'",
    Args = ["-pa" | search_paths()] ++ ["-osiris data_dir", Dir],
    ?INFO("osiris_bench: starting child node ~p with ~s~n", [NodeName, Args]),
    {ok, N} = start_peer_node(Host, NodeName, Args),
    ?INFO("osiris_bench: started child node ~w ~w~n", [N, Host]),
    Res = rpc:call(N, application, ensure_all_started, [osiris]),
    ok = rpc:call(N, logger, set_primary_config, [level, all]),
    ?INFO("osiris_bench: application start result ~p", [Res]),
    N.


-if(?OTP_RELEASE >= 25).
start_peer_node(Host, NodeName, Args) when is_atom(NodeName) ->
    Opts = #{
        name => string:trim(atom_to_list(NodeName)),
        host => Host,
        args => Args
    },
    {ok, _Pid, Node} = ?PEER_MODULE:start_link(Opts),
    {ok, Node}.
-else.
start_peer_node(Host, NodeName, Args) when is_atom(NodeName) ->
    ArgString = string:join(Args, " "),
    ?PEER_MODULE:start_link(Host, NodeName, ArgString).
-endif.

get_current_host() ->
    {ok, H} = inet:gethostname(),
    H.

search_paths() ->
    Ld = code:lib_dir(),
    lists:filter(fun(P) -> string:prefix(P, Ld) =:= nomatch end,
                 code:get_path()).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-endif.
