%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-dialyzer(unmatched_returns).

-export([]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("src/osiris_peer_shim.hrl").

-dialyzer({no_match, start_child_node/3}).
-dialyzer({nowarn_function, start_peer_node_25/3}).
-dialyzer({nowarn_function, start_peer_node_pre_25/3}).

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [{group, tests}].

all_tests() ->
    [single_node_write,
     cluster_write_replication_plain,
     cluster_write_replication_tls,
     start_many_clusters,
     quorum_write,
     cluster_batch_write,
     read_validate_single_node,
     read_validate,
     single_node_offset_listener,
     single_node_offset_listener2,
     cluster_offset_listener,
     replica_offset_listener,
     cluster_restart,
     cluster_restart_large,
     cluster_restart_new_leader,
     cluster_delete,
     cluster_failure,
     replica_reader_failure_should_stop_replica,
     start_cluster_invalid_replicas,
     restart_replica,
     replica_unknown_command,
     diverged_replica,
     retention,
     retention_max_age_eventually,
     retention_max_age_update_retention,
     retention_max_age_noproc,
     retention_add_replica_after,
     retention_overtakes_offset_reader,
     update_retention,
     update_retention_replica,
     tracking_offset,
     tracking_timestamp,
     tracking_offset_and_timestamp_same_id,
     tracking_offset_many,
     tracking_timestamp_many,
     tracking_offset_all,
     tracking_timestamp_all,
     tracking_retention,
     single_node_deduplication,
     single_node_deduplication_order,
     single_node_deduplication_2,
     single_node_deduplication_sub_batch,
     cluster_minority_deduplication,
     cluster_deduplication,
     cluster_deduplication_order,
     writers_retention,
     single_node_reader_counters,
     cluster_reader_counters,
     combine_ips_hosts_test,
     empty_last_segment].

-define(BIN_SIZE, 800).

groups() ->
    [{tests, [], all_tests()}].

init_per_suite(Config) ->
    osiris:configure_logger(logger),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    application:set_env(kernel, prevent_overlapping_partitions, false),
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    PrivDir = ?config(priv_dir, Config),
    Dir = filename:join(PrivDir, TestCase),
    _ = application:stop(osiris),
    _ = application:load(osiris),
    application:set_env(osiris, data_dir, Dir),
    ok = extra_init(TestCase),
    {ok, Apps} = application:ensure_all_started(osiris),
    ok = logger:set_primary_config(level, all),
    [{data_dir, Dir},
     {test_case, TestCase},
     {cluster_name, atom_to_binary(TestCase, utf8)},
     {started_apps, Apps}
     | Config].

extra_init(cluster_write_replication_tls) ->
    TlsGenDir = os:getenv("DEPS_DIR") ++ "/tls_gen/basic",
    TlsGenCmd = "make -C " ++ TlsGenDir ++ " CN=$(hostname -s) CLIENT_ALT_NAME=$(hostname -s) SERVER_ALT_NAME=$(hostname -s)",
    TlsGenBasicOutput = os:cmd(TlsGenCmd),
    Hostname = string:trim(os:cmd("hostname -s"), both, "\n"),
    ct:pal(?LOW_IMPORTANCE, "~s: ~s", [TlsGenCmd, TlsGenBasicOutput]),
    TlsConfDir = TlsGenDir ++ "/result/",
    application:set_env(osiris, replication_transport, ssl),
    application:set_env(osiris, replication_server_ssl_options, [
        {cacertfile, TlsConfDir ++ "ca_certificate.pem"},
        {certfile, TlsConfDir ++ "server_" ++ Hostname ++ "_certificate.pem"},
        {keyfile, TlsConfDir ++ "server_" ++ Hostname ++ "_key.pem"},
        {secure_renegotiate, true},
        {verify,verify_peer},
        {fail_if_no_peer_cert, true}
    ]),
    application:set_env(osiris, replication_client_ssl_options, [
        {cacertfile, TlsConfDir ++ "ca_certificate.pem"},
        {certfile, TlsConfDir ++ "client_" ++ Hostname ++ "_certificate.pem"},
        {keyfile, TlsConfDir ++ "client_" ++ Hostname ++ "_key.pem"},
        {secure_renegotiate, true},
        {verify,verify_peer},
        {fail_if_no_peer_cert, true}
    ]),
    ok;
extra_init(_) ->
    application:set_env(osiris, replication_transport, tcp),
    ok.

end_per_testcase(_TestCase, Config) ->
    _ = [application:stop(App)
         || App <- lists:reverse(?config(started_apps, Config))],
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

single_node_write(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          tracking_max_writers => 255,
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    Wid = <<"wid1">>,
    ?assertEqual(undefined, osiris:fetch_writer_seq(Leader, Wid)),
    ok = osiris:write(Leader, Wid, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, _WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    ?assertEqual(42, osiris:fetch_writer_seq(Leader, Wid)),
    ok.

start_many_clusters(Config) ->
    %% start some stuff
    ok = logger:set_primary_config(level, all),
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Names = [unicode:characters_to_binary([Name, <<"_">>, integer_to_binary(I)])
             || I <- lists:seq(1, 10)],
    %% set a small port range to try to trigger port conflicts
    AllEnv = [{port_range, {6000, 6010}} |
              proplists:delete(port_range,
                               application:get_all_env(osiris))],
    ct:pal("AllEnv ~p", [AllEnv]),
    PeerStates = [start_child_node(N, PrivDir, AllEnv) || N <- [s1, s2, s3]],
    Nodes = [NodeName || {_Ref, NodeName} <- PeerStates],
    F = fun (N) ->
                [LeaderNode | Replicas] = Nodes,
                Conf0 = #{name => N,
                          epoch => 1,
                          leader_node => LeaderNode,
                          replica_nodes => Replicas
                         },
                {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
                WriterId = N,
                ok = osiris:write(Leader, WriterId, 42, <<"mah-data">>),
                receive
                    {osiris_written, _, WriterId, [42]} ->
                        true
                after 2000 ->
                          ct:pal("~s reached written timeout", [N]),
                          flush(),
                          false
                end
        end,
    {_Oks, Failures} = osiris_util:partition_parallel(F, Names, 60000),
    timer:sleep(1000),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ?assertEqual([], Failures),
    ok.

cluster_write_replication_plain(Config) ->
    cluster_write(Config).

cluster_write_replication_tls(Config) ->
    cluster_write(Config).

cluster_write(Config) ->
    ok = logger:set_primary_config(level, all),
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir, application:get_all_env(osiris))
                  || N <- [s1, s2, s3]],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    WriterId = undefined,
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader,
           replica_pids := ReplicaPids}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, WriterId, 42, <<"mah-data">>),
    ok = osiris:write(Leader, WriterId, 43, <<"mah-data2">>),
    receive
        {osiris_written, _, undefined, [42, 43]} ->
            ok;
        {osiris_written, _, undefined, [42]} ->
            receive
                {osiris_written, _, undefined, [43]} ->
                    ok
            after 2000 ->
                      flush(),
                      exit(osiris_written_timeout_2)
            end
    after 2000 ->
              flush(),
              exit(osiris_written_timeout)
    end,
    %% give time for all members to receive data
    timer:sleep(500),
    [begin
         ok = validate_log(P, [{0, <<"mah-data">>}, {1, <<"mah-data2">>}])
     end || P <- [Leader | ReplicaPids]],
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

quorum_write(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    [_ | ReplicaPeers] = PeerStates,
    {FirstReplicaRef, _} = hd(ReplicaPeers),
    stop_peer(FirstReplicaRef),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_written, _, _WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        [stop_peer(Ref) || {Ref, _} <- PeerStates],
        exit(osiris_written_timeout)
    end,
    ok = validate_log(Leader, [{0, <<"mah-data">>}]),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

cluster_batch_write(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok,
     #{leader_pid := Leader, replica_pids := [ReplicaPid, ReplicaPid2]}} =
        osiris:start_cluster(Conf0),
    Batch = {batch, 1, 0, 8, simple(<<"mah-data">>)},
    ok = osiris:write(Leader, undefined, 42, Batch),
    receive
        {osiris_written, _, _WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    ok = validate_log(Leader, [{0, <<"mah-data">>}]),
    timer:sleep(1000),
    ok = validate_log(ReplicaPid, [{0, <<"mah-data">>}]),
    ok = validate_log(ReplicaPid2, [{0, <<"mah-data">>}]),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

single_node_offset_listener(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => []},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {error, {offset_out_of_range, empty}} =
        osiris:init_reader(Leader, {abs, 0}, {test, []}),
    osiris:register_offset_listener(Leader, 0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_offset, _Name, 0} ->
            {ok, Log0} = osiris:init_reader(Leader, {abs, 0}, {test, []}),
            {[{0, <<"mah-data">>}], Log} = osiris_log:read_chunk_parsed(Log0),
            {end_of_stream, _} = osiris_log:read_chunk_parsed(Log),
            ok
    after 2000 ->
        flush(),
        exit(osiris_offset_timeout)
    end,
    flush(),
    ok.

single_node_reader_counters(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => []},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {ok, Log0} = osiris:init_reader(Leader, next, {offset_reader_1, []}),
    Overview = osiris_counters:overview(),
    ?assertEqual(1, maps:get(readers, maps:get({'osiris_writer', Name}, Overview))),
    ?assertEqual(1, maps:get(epoch, maps:get({'osiris_writer', Name}, Overview))),
    ?assert(maps:is_key(offset_reader_1, Overview)),
    {ok, Log1} = osiris_writer:init_data_reader(Leader, {0, empty}, #{counter_spec => {data_reader_1, []}}),
    Overview1 = osiris_counters:overview(),
    ?assertEqual(2, maps:get(readers, maps:get({'osiris_writer', Name}, Overview1))),
    ?assert(maps:is_key(data_reader_1, Overview1)),
    osiris_log:close(Log0),
    ?assertNot(maps:is_key(offset_reader_1, osiris_counters:overview())),
    Overview2 = osiris_counters:overview(),
    ?assertEqual(1, maps:get(readers, maps:get({'osiris_writer', Name}, Overview2))),
    osiris_log:close(Log1),
    Overview3 = osiris_counters:overview(),
    ?assertEqual(0, maps:get(readers, maps:get({'osiris_writer', Name}, Overview3))),
    ?assertNot(maps:is_key(data_reader_1, osiris_counters:overview())),
    ok.

cluster_reader_counters(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [_ | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    Overview0 = osiris_counters:overview(),
    ?assertEqual(2, maps:get(readers, maps:get({'osiris_writer', Name}, Overview0))),
    {ok, Log0} = osiris:init_reader(Leader, next, {test, []}),
    Overview1 = osiris_counters:overview(),
    ?assertEqual(3, maps:get(readers, maps:get({'osiris_writer', Name}, Overview1))),
    {ok, Log1} = osiris_writer:init_data_reader(Leader, {0, empty}, #{counter_spec => {'test_data', []}}),
    Overview2 = osiris_counters:overview(),
    ?assertEqual(4, maps:get(readers, maps:get({'osiris_writer', Name}, Overview2))),
    osiris_log:close(Log0),
    Overview3 = osiris_counters:overview(),
    ?assertEqual(3, maps:get(readers, maps:get({'osiris_writer', Name}, Overview3))),
    osiris_log:close(Log1),
    Overview4 = osiris_counters:overview(),
    ?assertEqual(2, maps:get(readers, maps:get({'osiris_writer', Name}, Overview4))),

    [stop_peer(Ref) || {Ref, _} <- PeerStates].


combine_ips_hosts_test(_Config) ->
  Ip = ["192.168.23.23"],
  HostName = "myhostname.com",
  ?assertEqual(["192.168.23.23", "myhostname.com"],
    osiris_replica:combine_ips_hosts(tcp, Ip, HostName, HostName)),

  HostNameFromNode = osiris_util:hostname_from_node(),
  ?assertEqual(["192.168.23.23","myhostname.com", HostNameFromNode],
    osiris_replica:combine_ips_hosts(tcp, Ip, HostName,
      HostNameFromNode)),

  ?assertEqual(["myhostname.com", "192.168.23.23"],
    osiris_replica:combine_ips_hosts(ssl, Ip, HostName, HostName)),

  HostNameFromNode = osiris_util:hostname_from_node(),
  ?assertEqual(["myhostname.com", HostNameFromNode, "192.168.23.23"],
    osiris_replica:combine_ips_hosts(ssl, Ip, HostName,
      HostNameFromNode)).


single_node_offset_listener2(Config) ->
    %% writes before registering
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => []},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {ok, Log0} = osiris:init_reader(Leader, next, {test, []}),
    Next = osiris_log:next_offset(Log0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    wait_for_written([42]),
    osiris:register_offset_listener(Leader, Next),
    receive
        {osiris_offset, _Name, 0} ->
            {[{0, <<"mah-data">>}], Log} = osiris_log:read_chunk_parsed(Log0),
            {end_of_stream, _} = osiris_log:read_chunk_parsed(Log),
            ok
    after 2000 ->
        flush(),
        exit(osiris_offset_timeout)
    end,
    flush(),
    ok.

cluster_offset_listener(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [_ | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    {ok, Log0} = osiris:init_reader(Leader, 0, {test, []}),
    osiris:register_offset_listener(Leader, 0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_offset, _Name, O} when O > -1 ->
            ct:pal("got offset ~w", [O]),
            {[{0, <<"mah-data">>}], Log} = osiris_log:read_chunk_parsed(Log0),
            %% stop all replicas
            [stop_peer(Ref) || {Ref, _} <- PeerStates],
            ok = osiris:write(Leader, undefined, 43, <<"mah-data2">>),
            timer:sleep(10),
            {end_of_stream, _} = osiris_log:read_chunk_parsed(Log),
            ok
    after 2000 ->
        flush(),
        [stop_peer(Ref) || {Ref, _} <- PeerStates],
        exit(osiris_offset_timeout)
    end,
    ok.

replica_offset_listener(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [_ | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader, replica_pids := ReplicaPids}} =
        osiris:start_cluster(Conf0),
    Self = self(),
    R = hd(ReplicaPids),
    _ = spawn(node(R),
              fun() ->
                 {ok, Log0} = osiris:init_reader(R, 0, {test, []}),
                 osiris:register_offset_listener(R, 0),
                 receive
                     {osiris_offset, _Name, O} when O > -1 ->
                         ct:pal("got offset ~w", [O]),
                         {[{0, <<"mah-data">>}], Log} =
                             osiris_log:read_chunk_parsed(Log0),
                         osiris_log:close(Log),
                         Self ! test_passed,
                         ok
                 after 2000 ->
                     flush(),
                     exit(osiris_offset_timeout)
                 end
              end),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),

    receive
        test_passed ->
            ok
    after 5000 ->
        flush(),
        [stop_peer(Ref) || {Ref, _} <- PeerStates],
        exit(timeout)
    end,
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

read_validate_single_node(Config) ->
    _PrivDir = ?config(data_dir, Config),
    Num = 10000,
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []}} =
        osiris:start_cluster(Conf0),
    timer:sleep(500),
    % start_profile(Config, [osiris_writer, gen_batch_server,
    %                        osiris_log, lists, file]),
    ct:pal("writing ~b", [Num]),
    write_n(Leader, Num, #{}),
    % stop_profile(Config),
    {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, empty}, #{counter_spec => {'test', []}}),

    ct:pal("~w counters ~p", [node(), osiris_counters:overview()]),

    ct:pal("validating....", []),
    {Time, _} = timer:tc(fun() -> validate_read(Num, Log0) end),
    MsgSec = Num / (Time / 1000 / 1000),
    ct:pal("validate read of ~b entries took ~wms ~w msg/s",
           [Num, Time div 1000, MsgSec]),
    ok.

read_validate(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    NumWriters = 2,
    Num = 1000000 * NumWriters,
    PeerStates = [start_child_node(N, PrivDir) || N <- [r1, r2]],
    Replicas = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          retention => [{max_bytes, 1000000}],
          leader_node => node(),
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader, replica_pids := ReplicaPids}} =
        osiris:start_cluster(Conf0),
    {_, GarbBefore} = erlang:process_info(Leader, garbage_collection),
    {_, MemBefore} = erlang:process_info(Leader, memory),
    {_, BinBefore} = erlang:process_info(Leader, binary),
    timer:sleep(500),
    {Time, _} =
        timer:tc(fun() ->
                    Self = self(),
                    N = Num div NumWriters,
                    [begin
                         spawn(fun() ->
                                  write_n(Leader, N div 2, #{}),
                                  Self ! done
                               end),
                         write_n(Leader, N div 2, #{}),
                         receive done -> ok after 1000 * 60 -> exit(blah) end
                     end
                     || _ <- lists:seq(1, NumWriters)]
                 end),
    {_, BinAfter} = erlang:process_info(Leader, binary),
    {_, GarbAfter} = erlang:process_info(Leader, garbage_collection),
    {_, MemAfter} = erlang:process_info(Leader, memory),
    {reductions, _RedsAfter} = erlang:process_info(Leader, reductions),

    ct:pal("Binary:~n~w~n~w~n", [length(BinBefore), length(BinAfter)]),
    ct:pal("Garbage:~n~w~n~w~n", [GarbBefore, GarbAfter]),
    ct:pal("Memory:~n~w~n~w~n", [MemBefore, MemAfter]),
    MsgSec = Num / (Time / 1000 / 1000),
    ct:pal("~b writes took ~wms ~w msg/s",
           [Num, trunc(Time div 1000), trunc(MsgSec)]),
    ct:pal("~w counters ~p", [node(), osiris_counters:overview()]),
    _ = [begin
             ct:pal("~w counters ~p",
                    [N, erpc:call(N, osiris_counters, overview, [])])
         end || N <- Replicas],

    {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, empty}, #{counter_spec => {'test', []}}),
    {_, _} = timer:tc(fun() -> validate_read(Num, Log0) end),

    %% test reading on a secondary
    R = hd(ReplicaPids),
    Self = self(),
    _ = spawn(node(R),
              fun() ->
                 {ok, RLog0} = osiris_writer:init_data_reader(R, {0, empty}, #{counter_spec => {'test', []}}),
                 {_, _} = timer:tc(fun() -> validate_read(Num, RLog0) end),
                 Self ! validate_read_done
              end),
    receive
        validate_read_done ->
            ct:pal("all reads validated", []),
            ok
    after 30000 ->
        exit(validate_read_done_timeout)
    end,

    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

cluster_restart(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          replica_nodes => Replicas,
          leader_node => LeaderNode},
    {ok, #{leader_pid := Leader,
           replica_pids := [Replica1, Replica2]} = Conf} =
        osiris:start_cluster(Conf0),
    WriterId = <<"wid1">>,
    ok = osiris:write(Leader, WriterId, 42, <<"before-restart">>),
    receive
        {osiris_written, _, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    timer:sleep(1),
    RangesBeforeRecovery =
    [begin
         #{committed_chunk_id := E,
           first_chunk_id := S} = osiris:get_stats(P),
         {S, E}
     end || P <- [Leader, Replica1, Replica2]],

    ?assertEqual([{0,0}, {0,0}, {0,0}], RangesBeforeRecovery),

    osiris:stop_cluster(Conf),
    {ok, #{leader_pid := Leader1,
           replica_pids := [ReplicaPid1, ReplicaPid2]}} =
        osiris:start_cluster(Conf0#{epoch => 2}),
    %% give leader some time to discover the committed offset
    timer:sleep(1000),

    %% get all log ranges after recovery for each member and validate they are all
    %% the same
    RangesAfterRecovery =
    [begin
         #{committed_chunk_id := E,
           first_chunk_id := S} = osiris:get_stats(P),
         {S, E}
     end || P <- [Leader1, ReplicaPid1, ReplicaPid2]],
    ?assertEqual([{0,0}, {0,0}, {0,0}], RangesAfterRecovery),
    ct:pal("~p ~p", [RangesBeforeRecovery, RangesAfterRecovery]),
    ok = validate_log_offset_reader(Leader1, [{0, <<"before-restart">>}]),
    ok = validate_log_offset_reader(ReplicaPid1, [{0, <<"before-restart">>}]),
    ok = validate_log_offset_reader(ReplicaPid2, [{0, <<"before-restart">>}]),

    ok = osiris:write(Leader1, WriterId, 43, <<"after-restart">>),
    receive
        {osiris_written, _, WriterId, [43]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    ExpectedLog = [{0, <<"before-restart">>}, {1, <<"after-restart">>}],

    ok = validate_log_offset_reader(Leader1, ExpectedLog),
    ok = validate_log_offset_reader(ReplicaPid1, ExpectedLog),
    ok = validate_log_offset_reader(ReplicaPid2, ExpectedLog),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

cluster_restart_large(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Keys = [first_offset, offset],
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
    #{name => Name,
      epoch => 1,
      replica_nodes => Replicas,
      max_segment_size_bytes => 100 * 1000,
      leader_node => LeaderNode},
    {ok, #{leader_pid := Leader} = Conf} = osiris:start_cluster(Conf0),
    write_n(Leader, 255, 0, 1000000, #{}),
    CountersPre = erpc:call(LeaderNode, osiris_counters, overview,
                            [{osiris_writer, Name}]),

    %% wait for replica key counters to match writer
    await_condition(fun () ->
                            RC = erpc:call(hd(Replicas), osiris_counters, overview,
                                           [{osiris_replica, Name}]),
                            maps:with(Keys, CountersPre) == maps:with(Keys, RC)
                    end, 1000, 20),
    Replica1CountersPre = erpc:call(hd(Replicas), osiris_counters, overview,
                                    [{osiris_replica, Name}]),

    ?assertMatch(#{epoch := 1}, CountersPre),
    ?assertMatch(#{epoch := 1}, Replica1CountersPre),
    osiris:stop_cluster(Conf),
    {ok, #{leader_pid := _Leader1}} =
        osiris:start_cluster(Conf0#{epoch => 2}),
    %% give leader some time to discover the committed offset
    timer:sleep(1000),
    CountersPost = erpc:call(LeaderNode, osiris_counters, overview,
                             [{osiris_writer, Name}]),
    Replica1CountersPost = erpc:call(hd(Replicas), osiris_counters, overview,
                                     [{osiris_replica, Name}]),
    %% assert key counters are recovered
    ct:pal("Counters ~n~p", [CountersPost]),
    ?assertMatch(#{epoch := 2}, CountersPost),
    ?assertMatch(#{epoch := 2}, Replica1CountersPost),
    ?assertEqual(maps:with(Keys, CountersPre),
                 maps:with(Keys, CountersPost)),
    ?assertEqual(maps:with(Keys, Replica1CountersPre),
                 maps:with(Keys, Replica1CountersPost)),

    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

cluster_restart_new_leader(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          replica_nodes => Replicas,
          leader_node => LeaderNode},
    {ok, #{leader_pid := Leader} = Conf} = osiris:start_cluster(Conf0),
    WriterId = <<"wid1">>,
    ok = osiris:write(Leader, WriterId, 42, <<"before-restart">>),
    receive
        {osiris_written, _, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    osiris:stop_cluster(Conf),
    %% restart cluster with new
    [NewLeaderNode, Replica1] = Replicas,
    {ok, #{leader_pid := Leader1}} =
        osiris:start_cluster(Conf0#{epoch => 2,
                                    replica_nodes => [LeaderNode, Replica1],
                                    leader_node => NewLeaderNode}),
    %% give leader some time to discover the committed offset
    timer:sleep(1000),

    ok = validate_log(Leader1, [{0, <<"before-restart">>}]),

    ok = osiris:write(Leader1, WriterId, 43, <<"after-restart">>),
    receive
        {osiris_written, _, WriterId, [43]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    ok =
        validate_log(Leader1,
                     [{0, <<"before-restart">>}, {1, <<"after-restart">>}]),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

cluster_delete(Config) ->
    Name = ?config(cluster_name, Config),
    ok = cluster_delete(Config, Name, Name),
    ok = cluster_delete(Config, Name, binary_to_list(Name)),
    ok = cluster_delete(Config, binary_to_list(Name), binary_to_list(Name)),
    ok = cluster_delete(Config, binary_to_list(Name), Name),
    ok.

cluster_delete(Config, StartName, DeleteName) ->
    PrivDir = ?config(data_dir, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => StartName,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader,
           replica_pids := ReplicaPids} = Conf} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 42, <<"before-restart">>),
    receive
        {osiris_written, _, _WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,

    osiris:delete_cluster(Conf#{name => DeleteName}),
    %% validate pids are gone
    [begin
         ?assertEqual(false, erpc:call(node(Pid), erlang,is_process_alive, [Pid]))
     end || Pid <- [Leader | ReplicaPids]],
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

cluster_failure(Config) ->
    %% when the leader exits the failure the replicas and replica readers
    %% should also exit
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader, replica_pids := [R1, R2]} = _Conf} =
        osiris:start_cluster(Conf0),

    _PreRRs =
        supervisor:which_children({osiris_replica_reader_sup, node(Leader)}),
    %% stop the leader
    _ = gen_batch_server:stop(Leader, bananas, 5000),

    R1Ref = monitor(process, R1),
    R2Ref = monitor(process, R2),
    receive
        {'DOWN', R1Ref, _, _, _} ->
            ok
    after 2000 ->
        flush(),
        exit(down_timeout_1)
    end,
    receive
        {'DOWN', R2Ref, _, _, _} ->
            ok
    after 2000 ->
        flush(),
        exit(down_timeout_2)
    end,
    [] = supervisor:which_children({osiris_replica_reader_sup, node(Leader)}),

    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

replica_reader_failure_should_stop_replica(Config) ->
    %% when the leader exits the failure the replicas and replica readers
    %% should also exit
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    PeerStates = [start_child_node(N, PrivDir) || N <- [s1, s2, s3]],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader, replica_pids := [R1, R2]} = _Conf} =
        osiris:start_cluster(Conf0),

    [{_, RRPid1, _, _},
     {_, RRPid2, _, _}] =
        supervisor:which_children({osiris_replica_reader_sup, node(Leader)}),

    R1Ref = monitor(process, R1),
    R2Ref = monitor(process, R2),

    %% stop replica readers
    proc_lib:stop(RRPid1),
    proc_lib:stop(RRPid2),

    %% check replicas are stopping
    receive
        {'DOWN', R1Ref, _, _, _} ->
            ok
    after 2000 ->
        flush(),
        exit(down_timeout_1)
    end,
    receive
        {'DOWN', R2Ref, _, _, _} ->
            ok
    after 2000 ->
        flush(),
        exit(down_timeout_2)
    end,
    [] = supervisor:which_children({osiris_replica_reader_sup, node(Leader)}),

    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

start_cluster_invalid_replicas(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [zen@rabbit],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := _Leader, replica_pids := []}} =
        osiris:start_cluster(Conf0).

restart_replica(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Prefixes = [s1, s2, s3],
    PeerStates = [start_child_node(N, PrivDir) || N <- Prefixes],
    [LeaderE1, Replica1, Replica2] = [NodeName || {_Ref, NodeName} <- PeerStates],
    InitConf =
        #{name => Name,
          reference => Name,
          epoch => 1,
          leader_node => LeaderE1,
          replica_nodes => [Replica1, Replica2]},
    {ok,
     #{leader_pid := LeaderE1Pid, replica_pids := [R1Pid, _]} = Conf} =
        osiris:start_cluster(InitConf),
    %% write some records in e1
    Msgs = lists:seq(1, 1),
    _ = [osiris:write(LeaderE1Pid, undefined, N, [<<N:64/integer>>]) || N <- Msgs],
    wait_for_written(Msgs),
    timer:sleep(100),
    ok = erpc:call(node(R1Pid), gen_server, stop, [R1Pid]),
    _ = [osiris:write(LeaderE1Pid, undefined, N, [<<N:64/integer>>]) || N <- Msgs],
    wait_for_written(Msgs),
    {ok, _Replica1b} = osiris_replica:start(node(R1Pid), Conf),
    _ = [osiris:write(LeaderE1Pid, undefined, N, [<<N:64/integer>>]) || N <- Msgs],
    wait_for_written(Msgs),
    ok.


replica_unknown_command(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Prefixes = [s1, s2, s3],
    PeerStates = [start_child_node(N, PrivDir) || N <- Prefixes],
    [LeaderE1, Replica1, Replica2] = [NodeName || {_Ref, NodeName} <- PeerStates],
    InitConf =
        #{name => Name,
          reference => Name,
          epoch => 1,
          leader_node => LeaderE1,
          replica_nodes => [Replica1, Replica2]},
    {ok,
     #{leader_pid := _, replica_pids := [ReplicaPid, _]}} =
        osiris:start_cluster(InitConf),

    {error, unknown_command} = gen_server:call(ReplicaPid, what_is_this),
    ok = osiris:stop_cluster(InitConf),
    ok.

diverged_replica(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Prefixes = [s1, s2, s3],
    PeerStates = [start_child_node(N, PrivDir) || N <- Prefixes],
    [LeaderE1, LeaderE2, LeaderE3] = Nodes = [NodeName || {_Ref, NodeName} <- PeerStates],
    ConfE1 =
        #{name => Name,
          reference => Name,
          epoch => 1,
          leader_node => LeaderE1,
          replica_nodes => [LeaderE2, LeaderE3]},
    {ok, #{leader_pid := LeaderE1Pid}} = osiris:start_cluster(ConfE1),
    %% write some records in e1
    _ = [osiris:write(LeaderE1Pid, undefined, N, [<<N:64/integer>>])
         || N <- lists:seq(1, 100)],
    wait_for_written(lists:seq(1, 100)),

    %% shut down cluster and start only LeaderE2 in epoch 2
    ok = osiris:stop_cluster(ConfE1),
    ConfE2 =
        ConfE1#{leader_node => LeaderE2,
                epoch => 2,
                replica_nodes => [LeaderE1, LeaderE2]},
    {ok, LeaderE2Pid} = osiris_writer:start(ConfE2),
    %% write some entries that won't be committedo
    _ = [osiris:write(LeaderE2Pid, undefined, N, [<<N:64/integer>>])
         || N <- lists:seq(101, 200)],
    %% we can't wait for osiris_written here
    timer:sleep(500),
    %% shut down LeaderE2
    ok = osiris_writer:stop(ConfE2),

    ConfE3 =
        ConfE1#{leader_node => LeaderE3,
                epoch => 3,
                replica_nodes => [LeaderE1, LeaderE2]},
    %% start the cluster in E3 with E3 as leader
    {ok, #{leader_pid := LeaderE3Pid}} = osiris:start_cluster(ConfE3),
    %% write some more in this epoch
    _ = [osiris:write(LeaderE3Pid, undefined, N, [<<N:64/integer>>])
         || N <- lists:seq(201, 300)],
    wait_for_written(lists:seq(201, 300)),
    timer:sleep(1000),

    print_counters(),
    ok = osiris:stop_cluster(ConfE3),

    %% validate replication etc takes place
    [Idx1, Idx2, Idx3] =
        [begin
             {ok, D} =
                 file:read_file(
                     filename:join([PrivDir,
                                    hd(string:split(atom_to_list(N), "@")),
                                    ?FUNCTION_NAME,
                                    "00000000000000000000.index"])),
             D
         end
         || N <- Nodes],
    ?assertEqual(Idx1, Idx2),
    ?assertEqual(Idx1, Idx3),

    [Seg1, Seg2, Seg3] =
        [begin
             {ok, D} =
                 file:read_file(
                     filename:join([PrivDir,
                                    hd(string:split(atom_to_list(N), "@")),
                                    ?FUNCTION_NAME,
                                    "00000000000000000000.segment"])),
             D
         end
         || N <- Nodes],
    ?assertEqual(Seg1, Seg2),
    ?assertEqual(Seg1, Seg3),
    ok.

retention(Config) ->
    DataDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 50000 * 1000,
    %% silly low setting
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          retention => [{max_bytes, SegSize}],
          max_segment_size_bytes => SegSize,
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []} = Conf1} =
        osiris:start_cluster(Conf0),
    timer:sleep(500),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    timer:sleep(1000),
    Wc = filename:join([DataDir, ?FUNCTION_NAME, "*.segment"]),
    %% one file only
    [_] = filelib:wildcard(Wc),
    osiris:stop_cluster(Conf1),
    ok.

retention_max_age_eventually(Config) ->
    DataDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 50000 * 1000,
    application:set_env(osiris, retention_eval_interval, 5000),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          retention => [{max_age, 5000}],
          max_segment_size_bytes => SegSize,
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []} = Conf1} =
        osiris:start_cluster(Conf0),
    timer:sleep(100),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    Wc = filename:join([DataDir, ?FUNCTION_NAME, "*.segment"]),
    %% one file only
    await_condition(fun () ->
                            length(filelib:wildcard(Wc)) == 1
                    end, 1000, 20),
    osiris:stop_cluster(Conf1),
    ok.

retention_max_age_update_retention(Config) ->
    %% ensure a retention update cancels the current scheduled
    %% retention evaluation
    DataDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 50000 * 1000,
    application:set_env(osiris, retention_eval_interval, 5000),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          retention => [{max_age, 5000}],
          max_segment_size_bytes => SegSize,
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []} = Conf1} =
        osiris:start_cluster(Conf0),
    timer:sleep(100),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    Wc = filename:join([DataDir, ?FUNCTION_NAME, "*.segment"]),
    ok = osiris:update_retention(Leader, [{max_bytes, SegSize * 10}]),
    timer:sleep(10000),
    %% one file only
    ?assertNot(length(filelib:wildcard(Wc)) == 1),
    osiris:stop_cluster(Conf1),
    ok.

retention_max_age_noproc(Config) ->
    %% test scheduled retention eval when process is shut down
    %% we should not eval in this case
    DataDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 50000 * 1000,
    application:set_env(osiris, retention_eval_interval, 5000),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          retention => [{max_age, 5000}],
          max_segment_size_bytes => SegSize,
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []} = Conf1} =
        osiris:start_cluster(Conf0),
    timer:sleep(100),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    Wc = filename:join([DataDir, ?FUNCTION_NAME, "*.segment"]),
    timer:sleep(1000),
    %% stop cluster before scheduled retention triggers
    osiris:stop_cluster(Conf1),
    timer:sleep(6000),
    ?assertNot(length(filelib:wildcard(Wc)) == 1),
    ok.

retention_add_replica_after(Config) ->
    DataDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 50000 * 1000,
    Prefixes = [s1, s2, s3],
    PeerStates = [start_child_node(N, DataDir) || N <- Prefixes],
    [LeaderNode, Replica1, Replica2] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          retention => [{max_bytes, SegSize}],
          max_segment_size_bytes => SegSize,
          replica_nodes => [Replica1]},
    {ok, #{leader_pid := Leader,
           replica_pids := [ReplicaPid]} = Conf1} =
        osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 0, <<"first">>),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    ok = osiris:write(Leader, undefined, Num + 1, <<"last">>),
    wait_for_written([Num + 1]),

    ct:pal("checking 1", []),
    check_last_entry(Leader, <<"last">>),
    check_last_entry(ReplicaPid, <<"last">>),

    ct:pal("stop cluster", []),
    ok = osiris:stop_cluster(Conf1),
    ct:pal("stopped cluster", []),

    {ok, #{leader_pid := Leader2,
           replica_pids := [ReplicaPid1, ReplicaPid2]} = Conf2} =
        osiris:start_cluster(Conf0#{replica_nodes => [Replica1, Replica2],
                                    epoch => 2}),
    timer:sleep(2000),

    %% validate all members have the same last entry
    ct:pal("checking 2", []),
    check_last_entry(Leader2, <<"last">>),
    check_last_entry(ReplicaPid1, <<"last">>),
    check_last_entry(ReplicaPid2, <<"last">>),
    ok = osiris:stop_cluster(Conf2),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

check_last_entry(Pid, Entry) when is_pid(Pid) ->
    Self = self(),
    ct:pal("checking last entry for node ~s ~w", [node(Pid), Pid]),
    X = spawn(node(Pid),
               fun () ->
                       {ok, Log0} = osiris:init_reader(Pid, last, {test, []}),
                       [{_, Entry}] = read_til_end(Log0, undefined),
                       Self ! {self(), done},
                       ok
               end),
    receive
        {X, done} ->
            ct:pal("checking last entry done ~w", [node(Pid)]),
            ok
    after 10000 ->
              exit({done_timeout, node(X)})
    end,
    ok.

retention_overtakes_offset_reader(Config) ->
    DataDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 50000 * 1000,
    Prefixes = [s1, s2, s3],
    PeerStates = [start_child_node(N, DataDir) || N <- Prefixes],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          retention => [{max_bytes, SegSize}],
          max_segment_size_bytes => SegSize,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader,
           replica_pids := [ReplicaPid1, ReplicaPid2]}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 0, <<"first">>),
    timer:sleep(500),
    Self = self(),
    ReaderFun =
        fun (P) ->
                fun () ->
                        {ok, Log0} = osiris:init_reader(P, first, {test, []}),
                        {[{0, <<"first">>}], Log} = osiris_log:read_chunk_parsed(Log0),
                        receive
                            validate ->
                                [{_, <<"last">>}] = read_til_end(Log, undefined),
                                Self ! {done, self()},
                                ok
                        end
                end
        end,


    Pid1 = spawn_link(node(Leader), ReaderFun(Leader)),
    Pid2 = spawn_link(node(ReplicaPid1), ReaderFun(ReplicaPid1)),
    Pid3 = spawn_link(node(ReplicaPid2), ReaderFun(ReplicaPid2)),

    write_n(Leader, Num, 0, 1000 * 8, #{}),
    ok = osiris:write(Leader, undefined, 0, <<"last">>),
    timer:sleep(1000),
    Pid1 ! validate,
    Pid2 ! validate,
    Pid3 ! validate,
    receive {done, Pid1} -> ok
    after 30000 -> exit({done_timeout, Pid1})
    end,
    receive {done, Pid2} -> ok
    after 30000 -> exit({done_timeout, Pid2})
    end,
    receive {done, Pid3} -> ok
    after 30000 -> exit({done_timeout, Pid3})
    end,

    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    %% read til the end
    ok.


update_retention(Config) ->
    DataDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 50000 * 1000,
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          % retention => [{max_bytes, SegSize}],
          max_segment_size_bytes => SegSize,
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []}} =
        osiris:start_cluster(Conf0),
    timer:sleep(500),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    %% a retention update should trigger a retention evaluation
    Wc = filename:join([DataDir, ?FUNCTION_NAME, "*.segment"]),
    FilesPre = filelib:wildcard(Wc),
    ok = osiris:update_retention(Leader, [{max_bytes, SegSize}]),
    timer:sleep(1000),
    Files = filelib:wildcard(Wc),
    ?assert(length(Files) < length(FilesPre)),
    %% assert on num segs
    ok.

update_retention_replica(Config) ->
    DataDir = ?config(data_dir, Config),
    Num = 150000,
    SegSize = 50000 * 1000,
    Name = ?config(cluster_name, Config),
    Prefixes = [s1, s2, s3],
    PeerStates = [start_child_node(N, DataDir) || N <- Prefixes],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    Conf0 =
        #{name => Name,
          epoch => 1,
          max_segment_size_bytes => SegSize,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader, replica_pids := [R1, R2]}} =
        osiris:start_cluster(Conf0),
    Retention = [{max_bytes, SegSize}],
    timer:sleep(500),
    write_n(Leader, Num, 0, 1000 * 8, #{}),

    %% update retention for all members
    ok = osiris:update_retention(Leader, Retention),
    ok = osiris:update_retention(R1, Retention),
    ok = osiris:update_retention(R2, Retention),
    timer:sleep(1000),
    %% validate
    Fun = fun(Pid) ->
             Node = hd(string:split(atom_to_list(node(Pid)), "@")),
             Wc = filename:join([DataDir, Node, ?FUNCTION_NAME, "*.segment"]),
             Files = filelib:wildcard(Wc),
             length(Files)
          end,
    ?assertEqual(1, erpc:call(node(R1), erlang, apply, [Fun, [R1]])),
    ?assertEqual(1, erpc:call(node(R2), erlang, apply, [Fun, [R2]])),
    ?assertEqual(1,
                 erpc:call(node(Leader), erlang, apply, [Fun, [Leader]])),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

tracking_offset(Config) ->
    tracking(Config, offset).

tracking_timestamp(Config) ->
    tracking(Config, timestamp).

tracking(Config, TrkType) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    TrackId = <<"tracking-id-1">>,

    ?assertEqual(undefined, osiris:read_tracking(Leader, TrkType, TrackId)),
    ok = osiris:write_tracking(Leader, TrackId, {TrkType, 0}),
    %% need to sleep a little else we may try to write and read in the same
    %% batch which due to batch reversal isn't possible. This should be ok
    %% given the use case for reading tracking
    timer:sleep(100),
    ?assertEqual({TrkType, 0}, osiris:read_tracking(Leader, TrkType, TrackId)),
    ok = osiris:write_tracking(Leader, TrackId, {TrkType, 1}),
    timer:sleep(100),
    ?assertEqual({TrkType, 1}, osiris:read_tracking(Leader, TrkType, TrackId)),
    ok = osiris:stop_cluster(Conf0),
    {ok, #{leader_pid := Leader2}} = osiris:start_cluster(Conf0#{epoch => 2}),
    ?assertEqual({TrkType, 1}, osiris:read_tracking(Leader2, TrkType, TrackId)),
    ok.

%% Tests that the same tracking ID can use both offsets and timestamps at the same time.
tracking_offset_and_timestamp_same_id(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    TrackId = <<"tracking-id-1">>,

    ?assertEqual(undefined, osiris:read_tracking(Leader, offset, TrackId)),
    ?assertEqual(undefined, osiris:read_tracking(Leader, timestamp, TrackId)),
    ok = osiris:write_tracking(Leader, TrackId, {offset, 1}),
    ok = osiris:write_tracking(Leader, TrackId, {timestamp, 3}),
    timer:sleep(100),
    ?assertEqual({offset, 1}, osiris:read_tracking(Leader, offset, TrackId)),
    ?assertEqual({timestamp, 3}, osiris:read_tracking(Leader, timestamp, TrackId)),
    ok = osiris:stop_cluster(Conf0),
    {ok, #{leader_pid := Leader2}} = osiris:start_cluster(Conf0#{epoch => 2}),
    ?assertEqual({offset, 1}, osiris:read_tracking(Leader2, offset, TrackId)),
    ?assertEqual({timestamp, 3}, osiris:read_tracking(Leader2, timestamp, TrackId)),
    ok.

tracking_offset_many(Config) ->
    tracking_many(Config, offset).

tracking_timestamp_many(Config) ->
    tracking_many(Config, timestamp).

tracking_many(Config, TrkType) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    TrackId = <<"tracking-id-1">>,
    ?assertEqual(undefined, osiris:read_tracking(Leader, TrkType, TrackId)),
    ok = osiris:write_tracking(Leader, TrackId, {TrkType, 0}),
    ok = osiris:write_tracking(Leader, TrackId, {TrkType, 1}),
    ok = osiris:write_tracking(Leader, TrackId, {TrkType, 2}),
    ok = osiris:write_tracking(Leader, TrackId, {TrkType, 3}),
    timer:sleep(250),
    ?assertEqual({TrkType, 3}, osiris:read_tracking(Leader, TrkType, TrackId)),
    ok.

tracking_offset_all(Config) ->
    tracking_all(Config, offset).

tracking_timestamp_all(Config) ->
    tracking_all(Config, timestamp).

tracking_all(Config, TrkType) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, undefined, 42, <<"mah-data">>),
    receive
        {osiris_written, _Name, _, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout)
    end,
    TrackId1 = <<"tracking-id-1">>,
    TrackId2 = <<"tracking-id-2">>,
    TrackId3 = <<"tracking-id-3">>,
    ?assertMatch(#{offsets := Off, timestamps := Ts}
                   when map_size(Off) == 0 andalso map_size(Ts) == 0,
                        osiris:read_tracking(Leader)),
    ok = osiris:write_tracking(Leader, TrackId1, {TrkType, 0}),
    ok = osiris:write_tracking(Leader, TrackId2, {TrkType, 1}),
    ok = osiris:write_tracking(Leader, TrackId3, {TrkType, 2}),
    timer:sleep(250),
    Key = list_to_atom(atom_to_list(TrkType) ++ "s"),
    ?assertMatch(#{Key := #{TrackId1 := 0,
                            TrackId2 := 1,
                            TrackId3 := 2}}, osiris:read_tracking(Leader)),
    ok.

tracking_retention(Config) ->
    _PrivDir = ?config(data_dir, Config),
    Num = 150_000,
    Name = ?config(cluster_name, Config),
    SegSize = 50_000 * 1000,
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          retention => [{max_bytes, SegSize}],
          max_segment_size_bytes => SegSize,
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []}} =
        osiris:start_cluster(Conf0),
    timer:sleep(500),
    TrkId = <<"trkid1">>,
    osiris:write_tracking(Leader, TrkId, {offset, 5}),
    TrkId2 = <<"trkid2">>,
    osiris:write_tracking(Leader, TrkId2, {offset, Num}),
    Now = erlang:system_time(millisecond),
    TrkId3 = <<"trkid3">>,
    osiris:write_tracking(Leader, TrkId3, {timestamp, Now}),
    TrkId4 = <<"trkid4">>,
    osiris:write_tracking(Leader, TrkId4, {timestamp, Now + 5_000}),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    timer:sleep(1000),
    %% tracking id should be gone
    ?assertEqual(undefined, osiris:read_tracking(Leader, offset, TrkId)),
    ?assertEqual({offset, Num}, osiris:read_tracking(Leader, offset, TrkId2)),
    ?assertEqual(undefined, osiris:read_tracking(Leader, timestamp, TrkId3)),
    ?assertEqual({timestamp, Now + 5_000}, osiris:read_tracking(Leader, timestamp, TrkId4)),
    ok.

single_node_deduplication(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    WID = <<"wid1">>,
    ok = osiris:write(Leader, WID, 1, <<"data1">>),
    ok = osiris:write(Leader, WID, 1, <<"data1b">>),
    ok = osiris:write(Leader, WID, 2, <<"data2">>),
    wait_for_written([1, 2]),
    %% validate there are only a single entry
    validate_log(Leader, [{0, <<"data1">>}, {1, <<"data2">>}]),
    ok.

single_node_deduplication_order(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    WID = <<"wid1">>,
    SEQ = lists:seq(1,148),
    %% step 1: standard insert
    _ = [osiris:write(Leader, WID, N, [<<N:64/integer>>])
         || N <- SEQ],

   wait_for_written(SEQ),
    %% here we send the same messages
    %% and osiris send back the messages ids.
    %% The test is meant to check if the messages order
    %% is the same from the step 1 (osiris_writer:handle_duplicates/3)
     _ = [osiris:write(Leader, WID, N, [<<N:64/integer>>])
          || N <- SEQ],
    %% the messages received must be in order
    wait_for_written_order(SEQ),
    ok.

single_node_deduplication_2(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    WID = <<"wid1">>,
    ok = osiris:write(Leader, WID, 1, <<"data1">>),
    timer:sleep(50),
    ok = osiris:write(Leader, WID, 1, <<"data1b">>),
    ok = osiris:write(Leader, WID, 2, <<"data2">>),
    wait_for_written([1, 2]),
    %% data1b must not have been written
    ok = validate_log(Leader, [{0, <<"data1">>}, {1, <<"data2">>}]),

    ok.

single_node_deduplication_sub_batch(Config) ->
    Name = ?config(cluster_name, Config),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    WID = <<"wid1">>,
    ok = osiris:write(Leader, WID, 1, {batch, 1, 0, 5, simple(<<"data1">>)}),
    timer:sleep(50),
    ok = osiris:write(Leader, WID, 1, {batch, 1, 0, 5, simple(<<"data1">>)}),
    ok = osiris:write(Leader, WID, 2, {batch, 1, 0, 5, simple(<<"data2">>)}),
    wait_for_written([1, 2]),
    %% data1b must not have been written
    ok = validate_log(Leader, [{0, <<"data1">>}, {1, <<"data2">>}]),
    ok.

cluster_minority_deduplication(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Prefixes = [s1, s2, s3],
    PeerStates = [start_child_node(N, PrivDir) || N <- Prefixes],
    [_ | ReplicaStates] = PeerStates,
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    WriterId = atom_to_binary(?FUNCTION_NAME, utf8),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    [stop_peer(Ref) || {Ref, _} <- ReplicaStates],
    ok = osiris:write(Leader, WriterId, 42, <<"data1">>),
    ok = osiris:write(Leader, WriterId, 42, <<"data1b">>),
    timer:sleep(50),
    ok = osiris:write(Leader, WriterId, 43, <<"data2">>),
    %% the duplicate must not be confirmed until the prior write is
    receive
        {osiris_written, _, WriterId, _} ->
            ct:fail("unexpected osiris written event in minority")
    after 1000 ->
        ok
    end,
    ok = validate_log(Leader, [{0, <<"data1">>}, {1, <<"data2">>}]),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

cluster_deduplication(Config) ->
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Prefixes = [s1, s2, s3],
    PeerStates = [start_child_node(N, PrivDir) || N <- Prefixes],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    WriterId = atom_to_binary(?FUNCTION_NAME, utf8),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    ok = osiris:write(Leader, WriterId, 42, <<"mah-data">>),
    receive
        {osiris_written, _, WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout_1)
    end,
    ok = osiris:write(Leader, WriterId, 42, <<"mah-data-dupe">>),
    receive
        {osiris_written, _, WriterId, [42]} ->
            ok
    after 2000 ->
        flush(),
        exit(osiris_written_timeout_2)
    end,
    ok = validate_log(Leader, [{0, <<"mah-data">>}]),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

cluster_deduplication_order(Config) ->
    %% cluster test for deduplication order
    %% see: single_node_deduplication_order/1
    %% for details
    PrivDir = ?config(data_dir, Config),
    Name = ?config(cluster_name, Config),
    Prefixes = [s1, s2, s3],
    PeerStates = [start_child_node(N, PrivDir) || N <- Prefixes],
    [LeaderNode | Replicas] = [NodeName || {_Ref, NodeName} <- PeerStates],
    WriterId = atom_to_binary(?FUNCTION_NAME, utf8),
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => LeaderNode,
          replica_nodes => Replicas},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    SEQ = lists:seq(1,207),

    _ = [osiris:write(Leader, WriterId, N, [<<N:64/integer>>])
         || N <- SEQ],

    wait_for_written(SEQ),

    _ = [osiris:write(Leader, WriterId, N, [<<N:64/integer>>])
         || N <- SEQ],

    wait_for_written_order(SEQ),
    [stop_peer(Ref) || {Ref, _} <- PeerStates],
    ok.

writers_retention(Config) ->
    Name = ?config(cluster_name, Config),
    SegSize = 1000 * 10000,
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          replica_nodes => [],
          max_segment_size_bytes => SegSize,
          %% set a value lower than default
          tracking_config => #{max_sequences => 32},
          dir => ?config(priv_dir, Config)},
    {ok, #{leader_pid := Leader}} = osiris:start_cluster(Conf0),
    %% perform writes from 255 unique writers
    Writes =
        [begin
             WID = integer_to_binary(I),
             ok = osiris:write(Leader, WID, I, <<I:64/integer>>),
             I
         end
         || I <- lists:seq(1, 500)],
    wait_for_written(Writes),

    %% then make sure another segment is created
    write_n(Leader, 20000, 0, 8 * 1000, #{}),

    %% validate there are a maximum of 255 active writers after the segment
    %% roll over
    Writers = osiris_writer:query_writers(Leader, fun(W) -> W end),

    ?assert(map_size(Writers) < 33),

    %% validate there are only a single entry
    ok.

empty_last_segment(Config) ->
    %% can happen after unclean shutdown
    DataDir = ?config(data_dir, Config),
    Num = 150000,
    Name = ?config(cluster_name, Config),
    SegSize = 20000 * 1000,
    Conf0 =
        #{name => Name,
          epoch => 1,
          leader_node => node(),
          retention => [{max_bytes, SegSize * 3}],
          max_segment_size_bytes => SegSize,
          replica_nodes => []},
    {ok, #{leader_pid := Leader, replica_pids := []} = Conf1} =
        osiris:start_cluster(Conf0),
    timer:sleep(500),
    write_n(Leader, Num, 0, 1000 * 8, #{}),
    timer:sleep(100),
    osiris:stop_cluster(Conf1),
    Wc = filename:join([DataDir, ?FUNCTION_NAME, "*.segment"]),
    %% one file only
    [LastSeg | _] = lists:reverse(lists:sort(filelib:wildcard(Wc))),

    {ok, Fd} = file:open(LastSeg, [raw, binary, read, write]),
    ok = file:truncate(Fd),
    ok = file:close(Fd),
    {ok, #{leader_pid := Leader2, replica_pids := []}} =
        osiris:start_cluster(Conf1),
    timer:sleep(100),
    ?assert(erlang:is_process_alive(Leader2)),
    ok.

%% Utility

write_n(Pid, N, Written) ->
    write_n(Pid, N, 0, ?BIN_SIZE, Written).

write_n(_Pid, N, N, _BinSize, Written) ->
    %% wait for all written events;
    wait_for_written(Written),
    ok;
write_n(Pid, N, Next, BinSize, Written) ->
    ok = osiris:write(Pid, undefined, Next, <<Next:BinSize/integer>>),
    write_n(Pid, N, Next + 1, BinSize, Written#{Next => ok}).

wait_for_written(Written0) when is_list(Written0) ->
    wait_for_written(lists:foldl(fun(N, Acc) -> maps:put(N, ok, Acc) end,
                                 #{}, Written0));
wait_for_written(Written0) ->
    receive
        {osiris_written, _Name, _WriterId, Corrs} ->
          Written = maps:without(Corrs, Written0),
            case maps:size(Written) of
                0 ->
                    ok;
                _ ->
                    wait_for_written(Written)
            end
    after 1000 * 60 ->
        flush(),
        print_counters(),
        exit(osiris_written_timeout)
    end.

wait_for_written_order([]) ->
  ok;
wait_for_written_order(Written0) ->
  receive
    {osiris_written, _Name, _WriterId, Corrs} ->
      %% remove Corrs from Written0
      Written = lists:sublist(Written0, length(Corrs) + 1,
        length(Written0)-length(Corrs) ),

      Sub = lists:sublist(Written0, length(Corrs)),
      %% check if the Corrs received are
      %% equals to the SubList from Written0
      %% they must be the same
      case Sub =:= Corrs of
        true -> ok;
        false -> flush(),
          print_counters(),
          exit(osiris_written_out_of_order)
      end,
      wait_for_written_order(Written)

  after 1000 * 8 ->
    flush(),
    print_counters(),
    exit(osiris_written_timeout)
  end.

validate_read(N, Log) ->
    validate_read(N, 0, Log).

validate_read(N, N, Log0) ->
    {end_of_stream, _Log} = osiris_log:read_chunk_parsed(Log0),
    ok;
validate_read(Max, Next, Log0) ->
    {[{Offs, _} | _] = Recs, Log} = osiris_log:read_chunk_parsed(Log0),
    case Offs == Next of
        false ->
            ct:fail("validate_read failed Offs ~b not equal to ~b",
                    [Offs, Next]);
        true ->
            validate_read(Max, Next + length(Recs), Log)
    end.

start_child_node(NodeNamePrefix, PrivDir) ->
    start_child_node(NodeNamePrefix, PrivDir, []).

start_child_node(NodeName, PrivDir, ExtraAppConfig0) ->
    _ = file:make_dir(PrivDir),
    Dir = filename:join(PrivDir, NodeName),
    _ = file:make_dir(Dir),

    %% make sure the data dir computed above is passed on to the peers
    ExtraAppConfig1 = proplists:delete(data_dir, ExtraAppConfig0),
    ExtraAppConfig = [{data_dir, Dir} | ExtraAppConfig1],

    Host = get_current_host(),
    Args = ["-pa" | search_paths()] ++
           ["-kernel", "prevent_overlapping_partitions", "false"],
    %% ct:pal("starting child node ~p with ~p~n", [NodeName, Args]),
    {_Ref, FinalNodeName} = Result =
        case start_peer_node(Host, NodeName, Args) of
            {ok, Pid, FinalNodeName0} when is_atom(FinalNodeName0) ->
                {Pid, FinalNodeName0};
            {ok, FinalNodeName0} when is_atom(FinalNodeName0) ->
                %% before Erlang 25, the "ref" is the name of the node
                {FinalNodeName0, FinalNodeName0}
        end,
    %% ct:pal("started child node ~w~n", [FinalNodeName]),
    ct:pal("node ~s will use data dir at ~s", [FinalNodeName, Dir]),
    ok = erpc:call(FinalNodeName, ?MODULE, node_setup, [Dir]),
    %% ct:pal("performed node setup on child node ~w", [FinalNodeName]),
    ok = erpc:call(FinalNodeName, osiris, configure_logger, [logger]),

    %% ct:pal("configured logger on child node ~w", [FinalNodeName]),
    AppsToStart =
        case proplists:lookup(replication_transport, ExtraAppConfig) of
            {_, ssl} ->
                [osiris, ssl];
            _ ->
                [osiris]
        end,

    Keys = proplists:get_keys(ExtraAppConfig),
    AllKeys = lists:usort([replication_transport,
                           replication_server_ssl_options,
                           replication_client_ssl_options] ++ Keys),
    [begin
        case proplists:lookup(K, ExtraAppConfig) of
            none ->
                ok;
            {K, V} ->
                ok = erpc:call(FinalNodeName, application, set_env, [osiris, K, V])
        end
    end || K <- AllKeys],

    ok = erpc:call(FinalNodeName, logger, set_primary_config, [level, all]),
    _ = [ erpc:call(FinalNodeName, application, ensure_all_started, [App])
          || App <- AppsToStart],
    Result.

flush() ->
    receive
        Any ->
            ct:pal("flush ~p", [Any]),
            flush()
    after 0 ->
        ok
    end.

start_peer_node(Host, NodeName, Args) ->
    case list_to_integer(erlang:system_info(otp_release)) of
        N when N >= 25 ->
            start_peer_node_25(Host, NodeName, Args);
        _ ->
            start_peer_node_pre_25(Host, NodeName, Args)
    end.

start_peer_node_25(_Host, NodeName, Args) ->
    Opts = #{
        %% the caller is responsible for computing the final name,
        %% as the peer module implies that both node name prefix and
        %% hostname are strings, which is not always true in our case
        name      => NodeName,
        args      => Args,
        longnames => false
    },
    ?PEER_MODULE:start_link(Opts).

start_peer_node_pre_25(Host, NodeName, Args) ->
    ArgString = string:join(Args, " "),
    ?PEER_MODULE:start_link(Host, NodeName, ArgString).

stop_peer(RefOrName) ->
    case list_to_integer(erlang:system_info(otp_release)) of
        N when N >= 25 ->
            stop_peer_25(RefOrName);
        _ ->
            stop_peer_pre25(RefOrName)
    end.

stop_peer_25(RefOrName) ->
    %% peer:stop/1 not idempotent
    try
        ?PEER_MODULE:stop(RefOrName)
    catch exit:_:_Stacktrace ->
        ok
    end.

stop_peer_pre25(RefOrName) ->
    ?PEER_MODULE:stop(RefOrName).

get_current_host() ->
    {ok, H} = inet:gethostname(),
    H.

make_node_name(N) ->
    {ok, H} = inet:gethostname(),
    list_to_atom(lists:flatten(
                     io_lib:format("~s@~s", [N, H]))).

search_paths() ->
    Ld = code:lib_dir(),
    lists:filter(fun(P) -> string:prefix(P, Ld) =:= nomatch end,
                 code:get_path()).

% start_profile(Config, Modules) ->
%     Dir = ?config(priv_dir, Config),
%     Case = ?config(test_case, Config),
%     GzFile = filename:join([Dir, "lg_" ++ atom_to_list(Case) ++ ".gz"]),
%     ct:pal("Profiling to ~p~n", [GzFile]),

%     lg:trace(Modules, lg_file_tracer,
%              GzFile, #{running => false, mode => profile}).

% stop_profile(Config) ->
%     Case = ?config(test_case, Config),
%     ct:pal("Stopping profiling for ~p~n", [Case]),
%     lg:stop(),
%     Dir = ?config(priv_dir, Config),
%     Name = filename:join([Dir, "lg_" ++ atom_to_list(Case)]),
%     lg_callgrind:profile_many(Name ++ ".gz.*", Name ++ ".out",#{}),
%     ok.

validate_log(Leader, Exp) when is_pid(Leader) ->
    case node(Leader) == node() of
        true ->
            {ok, Log0} = osiris_writer:init_data_reader(Leader, {0, empty},
                                                        #{counter_spec => {'test', []}}),
            validate_log(Log0, Exp);
        false ->
            ok = erpc:call(node(Leader), ?MODULE, ?FUNCTION_NAME, [Leader, Exp])
    end;
validate_log(Log, []) ->
    ok = osiris_log:close(Log),
    ok;
validate_log(Log0, Expected) ->
    case osiris_log:read_chunk_parsed(Log0) of
        {end_of_stream, _} ->
            ct:fail("validate log failed, rem: ~p", [Expected]);
        {Entries, Log} ->
            validate_log(Log, Expected -- Entries)
    end.

validate_log_offset_reader(Leader, Exp) when is_pid(Leader) ->
    case node(Leader) == node() of
        true ->
            {ok, Log0} = osiris:init_reader(Leader, first, {'test', []}),
            validate_log_offset_reader(Log0, Exp);
        false ->
            ok = erpc:call(node(Leader), ?MODULE, ?FUNCTION_NAME, [Leader, Exp])
    end;
validate_log_offset_reader(Log, []) ->
    ok = osiris_log:close(Log),
    ok;
validate_log_offset_reader(Log0, Expected) ->
    case osiris_log:read_chunk_parsed(Log0) of
        {end_of_stream, _} ->
            ct:fail("validate log failed, rem: ~p", [Expected]);
        {Entries, Log} ->
            validate_log_offset_reader(Log, Expected -- Entries)
    end.

print_counters() ->
    [begin
         ct:pal("~w counters ~p",
                [N, erpc:call(N, osiris_counters, overview, [])]),
         ok
     end
     || N <- nodes()],
    ok.

read_til_end(Log0, Last) ->
    case osiris_log:read_chunk_parsed(Log0) of
        {end_of_stream, Log} ->
            osiris_log:close(Log),
            Last;
        {Entries, Log} ->
            read_til_end(Log, Entries)
    end.


node_setup(DataDir) ->
    LogFile = filename:join([DataDir, "osiris.log"]),
    SaslFile = filename:join([DataDir, "osiris_sasl.log"]),
    _ = logger:set_primary_config(level, debug),
    Config = #{config => #{type => {file, LogFile}}, level => debug},
    _ = logger:add_handler(ra_handler, logger_std_h, Config),

    _ = application:load(kernel),
    application:set_env(kernel, prevent_overlapping_partitions, false),

    _ = application:load(sasl),
    application:set_env(sasl, sasl_error_logger, {file, SaslFile}),
    _ = application:stop(sasl),
    _ = application:start(sasl),
    _ = error_logger:tty(false),

    _ = application:load(osiris),
    application:set_env(osiris, data_dir, DataDir),

    ok.

simple(Bin) ->
    S = byte_size(Bin),
    <<0:1, S:31, Bin/binary>>.

await_condition(_CondFun, _Sleep, 0) ->
    exit(await_condition_attempts_exceeded);
await_condition(CondFun, Sleep, Attempt) ->
    timer:sleep(Sleep),
    try CondFun() of
        true ->
            ok;
        false ->
            await_condition(CondFun, Sleep, Attempt-1)
    catch
        _:Err ->
            ct:pal("~s err ~p", [?FUNCTION_NAME, Err]),
            await_condition(CondFun, Sleep, Attempt-1)
    end.


