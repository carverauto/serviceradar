%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_log_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-export([]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("src/osiris.hrl").
% -include("src/osiris_peer_shim.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [{group, tests}].

all_tests() ->
    [init_empty,
     init_twice,
     init_recover,
     init_recover_with_writers,
     init_with_lower_epoch,
     write_batch,
     subbatch,
     subbatch_compressed,
     read_chunk_parsed,
     read_chunk_parsed_2,
     read_chunk_parsed_multiple_chunks,
     read_chunk_parsed_2_multiple_chunks,
     read_header,
     write_multi_log,
     tail_info_empty,
     tail_info,
     init_offset_reader_empty,
     init_offset_reader_empty_directory,
     init_offset_reader,
     init_offset_reader_last_chunk_is_not_user_chunk,
     init_offset_reader_no_user_chunk_in_last_segment,
     init_offset_reader_no_user_chunk_in_segments,
     init_offset_reader_timestamp_empty,
     init_offset_reader_timestamp,
     init_offset_reader_timestamp_multi_segment,
     init_offset_reader_truncated,
     init_data_reader_next,
     init_data_reader_empty_log,
     init_data_reader_truncated,
     init_epoch_offsets_empty,
     init_epoch_offsets_empty_writer,
     init_epoch_offsets_truncated_writer,
     init_epoch_offsets,
     init_epoch_offsets_multi_segment,
     init_epoch_offsets_multi_segment2,
     init_raw_offset_reader,
     % truncate,
     % truncate_multi_segment,
     accept_chunk,
     accept_chunk_truncates_tail,
     accept_chunk_does_not_truncate_tail_in_same_epoch,
     accept_chunk_in_other_epoch,
     init_epoch_offsets_discards_all_when_no_overlap_in_same_epoch,
     overview,
     init_corrupted_log,
     init_only_one_corrupted_segment,
     init_empty_last_files,
     evaluate_retention_max_bytes,
     evaluate_retention_max_age,
     evaluate_retention_max_age_empty,
     offset_tracking,
     offset_tracking_snapshot,
     many_segment_overview
    ].

groups() ->
    [{tests, [], all_tests()}].

init_per_suite(Config) ->
    osiris:configure_logger(logger),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    osiris:configure_logger(logger),
    PrivDir = ?config(priv_dir, Config),
    Dir = filename:join(PrivDir, TestCase),
    LeaderDir = filename:join(Dir, "leader"),
    Follower1Dir = filename:join(Dir, "follower1"),
    ORef = osiris_log_shared:new(),
    [{test_case, TestCase},
     {leader_dir, LeaderDir},
     {follower1_dir, Follower1Dir},
     {osiris_conf,
      #{dir => Dir,
        name => atom_to_list(TestCase),
        epoch => 1,
        readers_counter_fun => fun(_) -> ok end,
        shared => ORef,
        options => #{}}},
     {dir, Dir}
     | Config].

end_per_testcase(_TestCase, _Config) ->
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

init_empty(Config) ->
    S0 = osiris_log:init(?config(osiris_conf, Config)),
    ?assertEqual(0, osiris_log:next_offset(S0)),
    ok.

init_twice(Config) ->
    _S0 = osiris_log:init(?config(osiris_conf, Config)),
    S1 = osiris_log:init(?config(osiris_conf, Config)),
    ?assertEqual(0, osiris_log:next_offset(S1)),
    ok.

init_recover(Config) ->
    S0 = osiris_log:init(?config(osiris_conf, Config)),
    S1 = osiris_log:write([<<"hi">>], S0),
    ?assertEqual(1, osiris_log:next_offset(S1)),
    ok = osiris_log:close(S1),
    S2 = osiris_log:init(?config(osiris_conf, Config)),
    ?assertEqual(1, osiris_log:next_offset(S2)),
    %% validate the segment filename is recovered
    ?assertMatch(#{file := "00000000000000000000.segment"},
                 osiris_log:format_status(S2)),
    ok.

init_recover_with_writers(Config) ->
    S0 = osiris_log:init(?config(osiris_conf, Config)),
    Now = erlang:system_time(millisecond),
    Writers = make_trailer(sequence, <<"wid1">>, 1),
    ChId = osiris_log:next_offset(S0),
    S1 = osiris_log:write([<<"hi">>], ?CHNK_USER, Now, Writers, S0),
    ?assertEqual(1, osiris_log:next_offset(S1)),
    ok = osiris_log:close(S1),
    S2 = osiris_log:init(?config(osiris_conf, Config)),
    Trk = osiris_log:recover_tracking(S2),
    ?assertMatch(#{sequences := #{<<"wid1">> := {ChId, 1}}}, osiris_tracking:overview(Trk)),
    ?assertEqual(1, osiris_log:next_offset(S2)),
    ok.

init_with_lower_epoch(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf#{max_segment_size_bytes => 10 * 1000 * 1000}),
    S1 = osiris_log:write([<<"hi">>, <<"hi-there">>], S0),
    %% same is ok
    osiris_log:close(S1),
    _ = osiris_log:close(
            osiris_log:init(Conf)),
    %% higher is always ok
    _ = osiris_log:close(
            osiris_log:init(Conf#{epoch => 2})),
    %% lower is not ok
    ?assertException(exit, {invalid_epoch, _, _},
                     osiris_log:init(Conf#{epoch => 0})),
    ok.

write_batch(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf),
    ?assertEqual(0, osiris_log:next_offset(S0)),
    S1 = osiris_log:write([<<"hi">>], S0),
    ?assertEqual(1, osiris_log:next_offset(S1)),
    ok.

subbatch(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf),
    IOData = [<<0:1, 2:31/unsigned, "hi">>, <<0:1, 2:31/unsigned, "h0">>],
    CompType = 0, %% no compression
    Batch = {batch, 2, CompType, iolist_size(IOData), IOData},
    %% osiris_writer passes entries in reverse order
    S1 = osiris_log:write(
             lists:reverse([Batch, <<"simple">>]), S0),
    ?assertEqual(3, osiris_log:next_offset(S1)),
    OffRef = osiris_log_shared:new(),
    {ok, R0} =
        osiris_log:init_offset_reader(0, Conf#{shared => OffRef}),
    {end_of_stream, R1} = osiris_log:read_chunk_parsed(R0),
    osiris_log_shared:set_committed_chunk_id(OffRef, 0), %% first chunk index

    ?assertMatch({[{0, <<"hi">>}, {1, <<"h0">>}, {2, <<"simple">>}], _},
                 osiris_log:read_chunk_parsed(R1)),

    osiris_log:close(S1),
    osiris_log:close(R1),
    ok.


subbatch_compressed(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf),
    IOData = zlib:gzip([<<0:1, 2:31/unsigned, "hi">>, <<0:1, 2:31/unsigned, "h0">>]),
    CompType = 1, %% gzip
    Batch = {batch, 2, CompType, iolist_size(IOData), IOData},
    %% osiris_writer passes entries in reverse order
    S1 = osiris_log:write(
             lists:reverse([Batch, <<"simple">>]), S0),
    ?assertEqual(3, osiris_log:next_offset(S1)),
    OffRef = osiris_log_shared:new(),
    {ok, R0} =
        osiris_log:init_offset_reader(0, Conf#{shared => OffRef}),
    {end_of_stream, R1} = osiris_log:read_chunk_parsed(R0),
    osiris_log_shared:set_committed_chunk_id(OffRef, 0), %% first chunk index

    %% compressed sub batches should not be parsed server side
    %% so just returns the batch as is
    ?assertMatch({[{0, Batch}, {2, <<"simple">>}], _},
                 osiris_log:read_chunk_parsed(R1)),

    osiris_log:close(S1),
    osiris_log:close(R1),
    ok.

read_chunk_parsed(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf),
    RConf = Conf#{shared => osiris_log:get_shared(S0)},
    {ok, R0} = osiris_log:init_data_reader({0, empty}, RConf),
    {end_of_stream, R1} = osiris_log:read_chunk_parsed(R0),
    _S1 = osiris_log:write([<<"hi">>], S0),
    ?assertMatch({[{0, <<"hi">>}], _}, osiris_log:read_chunk_parsed(R1)),
    ok.

read_chunk_parsed_2(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf),
    RConf = Conf#{shared => osiris_log:get_shared(S0)},
    {ok, R0} = osiris_log:init_data_reader({0, empty}, RConf),
    {end_of_stream, R1} = osiris_log:read_chunk_parsed(R0, with_header),
    _S1 = osiris_log:write([<<"hi">>], S0),
    {ok,
     #{num_records := 1},
     [{0, <<"hi">>}], R2} = osiris_log:read_chunk_parsed(R1, with_header),
    {end_of_stream, _} = osiris_log:read_chunk_parsed(R2, with_header),
    ok.

read_chunk_parsed_multiple_chunks(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf),
    Entries = [<<"hi">>, <<"hi-there">>],
    %% osiris_writer passes entries in reversed order
    S1 = osiris_log:write(
             lists:reverse(Entries), S0),
    S2 = osiris_log:write([<<"hi-again">>], S1),
    RConf = Conf#{shared => osiris_log:get_shared(S2)},
    {ok, R0} = osiris_log:init_data_reader({0, empty}, RConf),
    {[{0, <<"hi">>}, {1, <<"hi-there">>}], R1} =
        osiris_log:read_chunk_parsed(R0),
    ?assertMatch({[{2, <<"hi-again">>}], _},
                 osiris_log:read_chunk_parsed(R1)),
    %% open another reader at a later index
    {ok, R2} = osiris_log:init_data_reader({2, {1, 0, 0}}, RConf),
    ?assertMatch({[{2, <<"hi-again">>}], _},
                 osiris_log:read_chunk_parsed(R2)),
    ok.

read_chunk_parsed_2_multiple_chunks(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf),
    Entries = [<<"hi">>, <<"hi-there">>],
    %% osiris_writer passes entries in reversed order
    S1 = osiris_log:write(
             lists:reverse(Entries), S0),
    S2 = osiris_log:write([<<"hi-again">>], S1),
    RConf = Conf#{shared => osiris_log:get_shared(S2)},
    {ok, R0} = osiris_log:init_data_reader({0, empty}, RConf),
    {ok, #{num_records := 2},
     [{0, <<"hi">>}, {1, <<"hi-there">>}], R1} =
        osiris_log:read_chunk_parsed(R0, with_header),
    ?assertMatch({ok, #{num_records := 1}, [{2, <<"hi-again">>}], _},
                 osiris_log:read_chunk_parsed(R1, with_header)),
    %% open another reader at a later index
    {ok, R2} = osiris_log:init_data_reader({2, {1, 0, 0}}, RConf),
    ?assertMatch({ok, #{num_records := 1}, [{2, <<"hi-again">>}], _},
                 osiris_log:read_chunk_parsed(R2, with_header)),
    ok.

read_header(Config) ->
    Conf = ?config(osiris_conf, Config),
    W0 = osiris_log:init(Conf),
    OffRef = osiris_log_shared:new(),
    {ok, R0} =
        osiris_log:init_offset_reader(first, Conf#{shared => OffRef}),
    {end_of_stream, R1} = osiris_log:read_header(R0),
    W1 = osiris_log:write([<<"hi">>, <<"ho">>], W0),
    _W = osiris_log:write([<<"hum">>], W1),
    osiris_log_shared:set_committed_chunk_id(OffRef, 3),
    {ok, H1, R2} = osiris_log:read_header(R1),
    ?assertMatch(#{chunk_id := 0,
                   epoch := 1,
                   type := 0,
                   num_records := 2,
                   num_entries := 2,
                   timestamp := _,
                   data_size := _,
                   trailer_size := 0},
                 H1),
    {ok, H2, R3} = osiris_log:read_header(R2),
    ?assertMatch(#{chunk_id := 2,
                   epoch := 1,
                   type := 0,
                   num_records := 1,
                   num_entries := 1,
                   timestamp := _,
                   data_size := _,
                   trailer_size := 0},
                 H2),
    {end_of_stream, _R} = osiris_log:read_header(R3),
    ok.

write_multi_log(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf#{max_segment_size_bytes => 10 * 1000 * 1000}),
    Data = crypto:strong_rand_bytes(10000),
    BatchOf10 = [Data || _ <- lists:seq(1, 10)],
    S1 = lists:foldl(fun(_, Acc0) ->
                              osiris_log:write(BatchOf10, Acc0) end,
                      S0, lists:seq(1, 101)),
    NextOffset = osiris_log:next_offset(S1),
    Segments =
        filelib:wildcard(
            filename:join(?config(dir, Config), "*.segment")),
    ?assertEqual(2, length(Segments)),

    OffRef = osiris_log_shared:new(),
    %% takes a single offset tracking data into account
    osiris_log_shared:set_committed_chunk_id(OffRef, NextOffset),
    %% ensure all records can be read
    {ok, R0} =
        osiris_log:init_offset_reader(first, Conf#{shared => OffRef}),

    R1 = lists:foldl(fun(_, Acc0) ->
                        {Records = [_ | _], Acc} =
                            osiris_log:read_chunk_parsed(Acc0),

                        ?assert(is_list(Records)),
                        ?assertEqual(10, length(Records)),
                        Acc
                     end,
                     R0, lists:seq(1, 101)),
    ?assertEqual(NextOffset, osiris_log:next_offset(R1)),
    ok.

tail_info_empty(Config) ->
    Conf = ?config(osiris_conf, Config),
    Log = osiris_log:init(Conf),
    %% {NextOffs, {LastEpoch, LastChunkOffset}}
    ?assertEqual({0, empty}, osiris_log:tail_info(Log)),
    osiris_log:close(Log),
    ok.

tail_info(Config) ->
    EChunks =
        [{1, [<<"one">>]}, {2, [<<"two">>]}, {4, [<<"three">>, <<"four">>]}],
    Log = seed_log(?config(dir, Config), EChunks, Config),
    %% {NextOffs, {LastEpoch, LastChunkOffset}}
    ?assertMatch({4, {4, 2, _}}, osiris_log:tail_info(Log)),
    osiris_log:close(Log),
    ok.

init_offset_reader_empty(Config) ->
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    LLog0 = seed_log(LDir, [], Config),
    osiris_log:close(LLog0),
    RConf = Conf#{dir => LDir},
    %% first and last falls back to next
    {ok, L1} = osiris_log:init_offset_reader(first, RConf),
    {ok, L2} = osiris_log:init_offset_reader(last, RConf),
    {ok, L3} = osiris_log:init_offset_reader(next, RConf),
    %% "larger" offset should fall back to next
    {ok, L4} = osiris_log:init_offset_reader(0, RConf),
    %% all 4 should have a next index of 0
    ?assertEqual(0, osiris_log:next_offset(L1)),
    ?assertEqual(0, osiris_log:next_offset(L2)),
    ?assertEqual(0, osiris_log:next_offset(L3)),
    ?assertEqual(0, osiris_log:next_offset(L4)),
    osiris_log:close(L1),
    osiris_log:close(L2),
    osiris_log:close(L3),
    osiris_log:close(L4),

    {error, {offset_out_of_range, empty}} =
        osiris_log:init_offset_reader({abs, 1}, RConf),
    ok.

init_offset_reader_empty_directory(Config) ->
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    RConf = Conf#{dir => LDir},
    ?assertEqual({error, no_index_file}, osiris_log:init_offset_reader(first, RConf)),
    ?assertEqual({error, no_index_file}, osiris_log:init_offset_reader(last, RConf)),
    ?assertEqual({error, no_index_file}, osiris_log:init_offset_reader(next, RConf)),
    ?assertEqual({error, no_index_file}, osiris_log:init_offset_reader(0, RConf)),
    ?assertEqual({error, no_index_file}, osiris_log:init_offset_reader({abs, 1}, RConf)),
    ok.

init_offset_reader(Config) ->
    init_offset_reader(Config, offset).

init_raw_offset_reader(Config) ->
    %% Raw readers behave like offset readers
    init_offset_reader(Config, raw).

init_offset_reader(Config, Mode) ->
    EpochChunks =
        [{1, [<<"one">>]}, {2, [<<"two">>]}, {3, [<<"three">>, <<"four">>]}],
    LDir = ?config(leader_dir, Config),
    Conf = ?config(osiris_conf, Config),
    set_shared(Conf, 3),
    LLog0 = seed_log(LDir, EpochChunks, Config),
    osiris_log:close(LLog0),
    RConf = Conf#{dir => LDir, mode => Mode},

    {ok, L1} = osiris_log:init_offset_reader(first, RConf),
    ?assertEqual(0, osiris_log:next_offset(L1)),
    osiris_log:close(L1),

    {ok, L2} = osiris_log:init_offset_reader(last, RConf),
    %% 3 is the actual last ones but we can only attach to the chunk offset
    %% containing the requested offset
    ?assertEqual(2, osiris_log:next_offset(L2)),
    osiris_log:close(L2),

    {ok, L3} = osiris_log:init_offset_reader(next, RConf),
    ?assertEqual(4, osiris_log:next_offset(L3)),
    osiris_log:close(L3),

    %% "larger" offset should fall back to next
    {ok, L4} = osiris_log:init_offset_reader(0, RConf),
    ?assertEqual(0, osiris_log:next_offset(L4)),
    osiris_log:close(L4),

    %% 2 is the chunk offset containin offset 2 and 3,
    {ok, L5} = osiris_log:init_offset_reader({abs, 3}, RConf),
    ?assertEqual(2, osiris_log:next_offset(L5)),
    osiris_log:close(L5),

    {ok, L6} = osiris_log:init_offset_reader({abs, 2}, RConf),
    ?assertEqual(2, osiris_log:next_offset(L6)),
    osiris_log:close(L6),

    {error, {offset_out_of_range, {0, 3}}} =
        osiris_log:init_offset_reader({abs, 4}, RConf),
    {error, {offset_out_of_range, {0, 3}}} =
        osiris_log:init_offset_reader({abs, 6}, RConf),
    ok.

init_offset_reader_last_chunk_is_not_user_chunk(Config) ->
    % | offset | chunk type |
    % | 0      | user       |
    % | 1      | user       |
    % | 2      | tracking   |
    % | 3      | tracking   |
    EpochChunks = [{1, [<<"one">>]}, {2, [<<"two">>]}],
    LDir = ?config(leader_dir, Config),
    S0 = seed_log(LDir, EpochChunks, Config),
    S1 = osiris_log:write([<<"1st tracking delta chunk">>],
                          ?CHNK_TRK_DELTA,
                          ?LINE,
                          make_trailer(offset, <<"id1">>, 10),
                          S0),
    S2 = osiris_log:write([<<"2nd tracking delta chunk">>],
                          ?CHNK_TRK_DELTA,
                          ?LINE,
                          make_trailer(offset, <<"id1">>, 11),
                          S1),
    osiris_log:close(S2),

    Conf = ?config(osiris_conf, Config),
    RConf = Conf#{dir => LDir},
    set_shared(RConf, 4),
    % Test that 'last' returns last user chunk
    {ok, L1} = osiris_log:init_offset_reader(last, RConf),
    ?assertEqual(1, osiris_log:next_offset(L1)),
    osiris_log:close(L1),

    % Test that 'next' returns next chunk
    {ok, L2} = osiris_log:init_offset_reader(next, RConf),
    ?assertEqual(4, osiris_log:next_offset(L2)),
    osiris_log:close(L2),
    ok.

init_offset_reader_no_user_chunk_in_last_segment(Config) ->
    % | offset | chunk type | segment |
    % | 0      | user       | 1       |
    % | 1      | tracking   | 1       |
    % | 2      | tracking   | 2       |
    Conf0 = ?config(osiris_conf, Config),
    Conf = Conf0#{max_segment_size_bytes => 120},
    S0 = seed_log(Conf, [{1, [<<"one">>]}], Config),
    set_shared(Conf, 2),
    S1 = osiris_log:write([<<"1st tracking delta chunk">>],
                          ?CHNK_TRK_DELTA,
                          ?LINE,
                          make_trailer(offset, <<"id1">>, 10),
                          S0),
    S2 = osiris_log:write([<<"2nd tracking delta chunk">>],
                          ?CHNK_TRK_DELTA,
                          ?LINE,
                          make_trailer(offset, <<"id1">>, 11),
                          S1),
    osiris_log:close(S2),

    RConf = Conf,
    % test that 'last' returns last user chunk
    {ok, L1} = osiris_log:init_offset_reader(last, RConf),
    ?assertEqual(0, osiris_log:next_offset(L1)),
    osiris_log:close(L1),

    % test that 'next' returns next chunk
    {ok, L2} = osiris_log:init_offset_reader(next, RConf),
    ?assertEqual(3, osiris_log:next_offset(L2)),
    osiris_log:close(L2),
    ok.

init_offset_reader_no_user_chunk_in_segments(Config) ->
    % | offset | chunk type |
    % | 0      | tracking   |
    LDir = ?config(leader_dir, Config),
    S0 = seed_log(LDir, [], Config),
    S1 = osiris_log:write([<<"1st tracking delta chunk">>],
                          ?CHNK_TRK_DELTA,
                          ?LINE,
                          make_trailer(offset, <<"id1">>, 10),
                          S0),
    osiris_log:close(S1),

    Conf = ?config(osiris_conf, Config),
    RConf = Conf#{dir => LDir},
    % Test that 'last' falls back to `next` behaviour when there is no user chunk
    % present in the log
    {ok, L1} = osiris_log:init_offset_reader(last, RConf),
    ?assertEqual(1, osiris_log:next_offset(L1)),
    osiris_log:close(L1),

    {ok, L2} = osiris_log:init_offset_reader(next, RConf),
    ?assertEqual(1, osiris_log:next_offset(L2)),
    osiris_log:close(L2),
    ok.

init_offset_reader_timestamp_empty(Config) ->
    ok = logger:set_primary_config(level, all),
    Now = now_ms(),
    EpochChunks = [],
    LDir = ?config(leader_dir, Config),
    Conf0 = ?config(osiris_conf, Config),
    %% TODO: separate multi segment test
    % application:set_env(osiris, max_segment_size_chunks, 1),
    Conf = Conf0#{max_segment_size_chunks => 1},
    LLog0 = seed_log(LDir, EpochChunks, Config),
    set_shared(Conf, 3),
    osiris_log:close(LLog0),
    RConf = Conf#{dir => LDir},

    {ok, L1} = osiris_log:init_offset_reader({timestamp, Now - 8000}, RConf),
    ?assertEqual(0, osiris_log:next_offset(L1)),
    osiris_log:close(L1),
    ok.

init_offset_reader_timestamp(Config) ->
    ok = logger:set_primary_config(level, all),
    Now = now_ms(),
    EpochChunks =
        [{1, Now - 10000, [<<"one">>]}, % 0
         {1, Now - 8000, [<<"two">>]},  % 1
         {1, Now - 5000, [<<"three">>, <<"four">>]}], % 2
    LDir = ?config(leader_dir, Config),
    Conf0 = ?config(osiris_conf, Config),
    Conf = Conf0#{max_segment_size_chunks => 1},
    LLog0 = seed_log(LDir, EpochChunks, Config),
    set_shared(Conf, 3),
    osiris_log:close(LLog0),
    RConf = Conf#{dir => LDir},

    {ok, L1} =
        osiris_log:init_offset_reader({timestamp, Now - 8000}, RConf),
    %% next offset is expected to be offset 1
    ?assertEqual(1, osiris_log:next_offset(L1)),
    osiris_log:close(L1),

    %% future case
    {ok, L2} = osiris_log:init_offset_reader({timestamp, Now}, RConf),
    ?assertEqual(4, osiris_log:next_offset(L2)),
    osiris_log:close(L2),

    %% past case
    {ok, L3} =
        osiris_log:init_offset_reader({timestamp, Now - 10000}, RConf),
    ?assertEqual(0, osiris_log:next_offset(L3)),
    osiris_log:close(L3),

    %% in between
    {ok, L4} =
        osiris_log:init_offset_reader({timestamp, Now - 6000}, RConf),
    ?assertEqual(2, osiris_log:next_offset(L4)),
    osiris_log:close(L4),
    ok.

init_offset_reader_timestamp_multi_segment(Config) ->
    ok = logger:set_primary_config(level, all),
    Now = now_ms(),
    EpochChunks =
        [{1, Now - 10000, [<<"one">>]}, % 0
         {1, Now - 8000, [<<"two">>]},  % 1
         {1, Now - 5000, [<<"three">>, <<"four">>]}], % 2
    LDir = ?config(leader_dir, Config),
    Conf0 = ?config(osiris_conf, Config),
    %% segment per chunk
    application:set_env(osiris, max_segment_size_chunks, 1),
    Conf = Conf0#{max_segment_size_chunks => 1},
    LLog0 = seed_log(LDir, EpochChunks, Config),

    set_shared(Conf, 3),
    osiris_log:close(LLog0),
    application:unset_env(osiris, max_segment_size_chunks),
    RConf = Conf#{dir => LDir},

    {ok, L1} =
        osiris_log:init_offset_reader({timestamp, Now - 8000}, RConf),
    %% next offset is expected to be offset 1
    ?assertEqual(1, osiris_log:next_offset(L1)),
    osiris_log:close(L1),

    %% future case
    {ok, L2} = osiris_log:init_offset_reader({timestamp, Now}, RConf),
    ?assertEqual(4, osiris_log:next_offset(L2)),
    osiris_log:close(L2),

    %% past case
    {ok, L3} =
        osiris_log:init_offset_reader({timestamp, Now - 10000}, RConf),
    ?assertEqual(0, osiris_log:next_offset(L3)),
    osiris_log:close(L3),

    %% in between
    {ok, L4} =
        osiris_log:init_offset_reader({timestamp, Now - 6000}, RConf),
    ?assertEqual(2, osiris_log:next_offset(L4)),
    osiris_log:close(L4),
    ok.
init_offset_reader_truncated(Config) ->
    Data = crypto:strong_rand_bytes(1500),
    EpochChunks =
        [begin {1, [Data || _ <- lists:seq(1, 50)]} end
         || _ <- lists:seq(1, 20)],
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    LLog0 = seed_log(LDir, EpochChunks, Config),
    set_shared(Conf, 1000),
    RConf = Conf#{dir => LDir},
    osiris_log:close(LLog0),

    %% "Truncate" log by deleting first segment
    ok =
        file:delete(
            filename:join(LDir, "00000000000000000000.index")),
    ok =
        file:delete(
            filename:join(LDir, "00000000000000000000.segment")),

    {ok, L1} = osiris_log:init_offset_reader(first, RConf),
    %% we can only check reliably that it is larger than 0
    ?assert(0 < osiris_log:next_offset(L1)),
    osiris_log:close(L1),

    {ok, L2} = osiris_log:init_offset_reader(last, RConf),
    %% the last batch offset should be 949 given 50 records per batch
    ?assertEqual(950, osiris_log:next_offset(L2)),
    osiris_log:close(L2),

    {ok, L3} = osiris_log:init_offset_reader(next, RConf),
    %% the last offset should be 999 + 1
    ?assertEqual(1000, osiris_log:next_offset(L3)),
    osiris_log:close(L3),

    {ok, L4} = osiris_log:init_offset_reader(1000, RConf),
    %% higher = next
    ?assertEqual(1000, osiris_log:next_offset(L4)),
    osiris_log:close(L4),

    {ok, L5} = osiris_log:init_offset_reader(5, RConf),
    %% lower = first
    ?assert(5 < osiris_log:next_offset(L5)),
    osiris_log:close(L5),
    ok.

init_data_reader_next(Config) ->
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    FDir = ?config(follower1_dir, Config),
    _LLog0 = seed_log(LDir, [{1, ["one"]}], Config),
    %% seed is up to date
    FLog0 = seed_log(FDir, [{1, ["one"]}], Config),
    RRConf = Conf#{dir => LDir,
                   shared => osiris_log:get_shared(FLog0)},
    %% the next offset, i.e. offset 0
    {ok, _RLog0} =
        osiris_log:init_data_reader(
            osiris_log:tail_info(FLog0), RRConf),
    ok.

init_data_reader_empty_log(Config) ->
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    LLog0 = seed_log(LDir, [], Config),
    %% an empty log
    FLog0 = seed_log(?config(follower1_dir, Config), [], Config),
    RRConf = Conf#{dir => ?config(leader_dir, Config),
                   shared => osiris_log:get_shared(FLog0)},
    %% the next offset, i.e. offset 0
    {ok, RLog0} =
        osiris_log:init_data_reader(
            osiris_log:tail_info(FLog0), RRConf),
    osiris_log:close(RLog0),
    %% too large
    {error, {offset_out_of_range, empty}} =
        osiris_log:init_data_reader({1, {0, 0, 0}}, RRConf),

    LLog = osiris_log:write([<<"hi">>], LLog0),

    %% init after write should also work
    {ok, RLog1} =
        osiris_log:init_data_reader(
            osiris_log:tail_info(FLog0), RRConf),
    ?assertEqual(0, osiris_log:next_offset(RLog1)),
    osiris_log:close(RLog1),

    ok = osiris_log:close(LLog),
    ok.

init_data_reader_truncated(Config) ->
    Data = crypto:strong_rand_bytes(1500),
    EpochChunks =
        [begin {1, [Data || _ <- lists:seq(1, 50)]} end
         || _ <- lists:seq(1, 20)],
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    LLog0 = seed_log(LDir, EpochChunks, Config),
    RConf = Conf#{dir => LDir,
                  shared => osiris_log:get_shared(LLog0)},
    osiris_log:close(LLog0),

    %% "Truncate" log by deleting first segment
    ok =
        file:delete(
            filename:join(LDir, "00000000000000000000.index")),
    ok =
        file:delete(
            filename:join(LDir, "00000000000000000000.segment")),

    %% when requesting a lower offset than the start of the log
    {error, {offset_out_of_range, _}} = osiris_log:init_data_reader({0, empty}, RConf),

    %% attaching inside the log should be ok too
    {ok, L2} = osiris_log:init_data_reader({750, {1, 700, ?LINE}}, RConf),
    ?assertEqual(750, osiris_log:next_offset(L2)),
    osiris_log:close(L2),

    % %% however attaching with a different epoch should be disallowed
    ?assertEqual({error, {invalid_last_offset_epoch, 2, 1}},
                 osiris_log:init_data_reader({750, {2, 700, ?LINE}}, RConf)),
    osiris_log:close(L2),
    ok.

init_epoch_offsets_empty(Config) ->
    EpochChunks =
        [{1, [<<"one">>]}, {1, [<<"two">>]}, {1, [<<"three">>, <<"four">>]}],
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    FDir = ?config(follower1_dir, Config),
    LogInit = seed_log(LDir, EpochChunks, Config),
    osiris_log:close(LogInit),
    EOffs = [{1, 0}],
    Range = {0, 3},
    Log0 =
        osiris_log:init_acceptor(Range, EOffs, Conf#{dir => FDir, epoch => 1}),
    {0, empty} = osiris_log:tail_info(Log0),
    osiris_log:close(Log0),
    ok.

init_epoch_offsets_empty_writer(Config) ->
    EpochChunks =
        [{1, [<<"one">>]}, {1, [<<"two">>]}, {1, [<<"three">>, <<"four">>]}],
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    LogInit = seed_log(LDir, EpochChunks, Config),
    osiris_log:close(LogInit),
    EOffs = [],
    Range = {0, 3},
    Log0 =
        osiris_log:init_acceptor(Range, EOffs, Conf#{dir => LDir, epoch => 2}),
    {0, empty} = osiris_log:tail_info(Log0),
    osiris_log:close(Log0),
    ok.

init_epoch_offsets_truncated_writer(Config) ->
    %% test acceptor initialisation where the acceptor has no log and the writer
    %% has had retention remove the head of it's log
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    EOffs = [{3, 100}],
    Range = {50, 100},
    Log0 =
    osiris_log:init_acceptor(Range, EOffs, Conf#{dir => LDir,
                                                 epoch => 2}),
    {50, empty} = osiris_log:tail_info(Log0),
    osiris_log:close(Log0),

    ?assert(filelib:is_file(filename:join(LDir, "00000000000000000050.index"))),
    ok.

init_epoch_offsets(Config) ->
    EpochChunks =
        [{1, [<<"one">>]}, {1, [<<"two">>]}, {1, [<<"three">>, <<"four">>]}],
    LDir = ?config(leader_dir, Config),
    LogInit = seed_log(LDir, EpochChunks, Config),
    osiris_log:close(LogInit),
    EOffs = [{1, 1}],
    Range = {0, 1},
    Log0 =
        osiris_log:init_acceptor(Range, EOffs,
                                 #{dir => LDir,
                                   name => ?config(test_case, Config),
                                   epoch => 2}),
    {2, {1, 1, _}} = osiris_log:tail_info(Log0),
    osiris_log:close(Log0),
    ok.

init_epoch_offsets_multi_segment(Config) ->
    Data = crypto:strong_rand_bytes(1500),
    EpochChunks =
        [begin {1, [Data || _ <- lists:seq(1, 50)]} end
         || _ <- lists:seq(1, 20)],
    LDir = ?config(leader_dir, Config),
    osiris_log:close(seed_log(LDir, EpochChunks, Config)),
    ct:pal("~p", [osiris_log:overview(LDir)]),
    EOffs = [{1, 650}],
    Range = {0, 650},
    Log0 =
        osiris_log:init_acceptor(Range, EOffs,
                                 #{dir => LDir,
                                   name => ?config(test_case, Config),
                                   epoch => 2}),
    {700, {1, 650, _}} = osiris_log:tail_info(Log0),
    osiris_log:close(Log0),
    ok.

init_epoch_offsets_multi_segment2(Config) ->
    Data = crypto:strong_rand_bytes(1500),
    EpochChunks =
        [{1, [Data || _ <- lists:seq(1, 50)]} || _ <- lists:seq(1, 15)]
        ++ [{2, [Data || _ <- lists:seq(1, 50)]} || _ <- lists:seq(1, 5)],
    LDir = ?config(leader_dir, Config),
    osiris_log:close(seed_log(LDir, EpochChunks, Config)),
    ct:pal("~p", [osiris_log:overview(LDir)]),
    EOffs = [{3, 750}, {1, 650}],
    Range = {0, 750},
    Log0 =
        osiris_log:init_acceptor(Range, EOffs,
                                 #{dir => LDir,
                                   name => ?config(test_case, Config),
                                   epoch => 2}),
    {700, {1, 650, _}} = osiris_log:tail_info(Log0),
    osiris_log:close(Log0),
    ok.

accept_chunk(Config) ->
    ok = logger:set_primary_config(level, all),
    Conf = ?config(osiris_conf, Config),
    LConf = Conf#{dir => ?config(leader_dir, Config)},
    FConf = Conf#{dir => ?config(follower1_dir, Config)},
    L0 = osiris_log:init(LConf),
    %% write an entry with just tracking
    L1 = osiris_log:write([<<"hi">>], ?CHNK_USER, ?LINE, <<>>, L0),
    % L1 = osiris_log:write_tracking(#{<<"id1">> => {offset, 1}}, delta, L0),
    timer:sleep(100),

    Now = ?LINE,
    L2 = osiris_log:write([<<"hi">>], ?CHNK_USER, Now, <<>>, L1),

    F0 = osiris_log:init(FConf),

    RConf = LConf#{shared => osiris_log:get_shared(L2)},

    {ok, R0} =
        osiris_log:init_data_reader(
            osiris_log:tail_info(F0), RConf),
    {Chunk1, R1} = read_chunk(R0),
    % ct:pal("Chunk1 ~w", [Chunk1]),
    F1 = osiris_log:accept_chunk(Chunk1, F0),
    {Chunk2, R2} = read_chunk(R1),
    F2 = osiris_log:accept_chunk(Chunk2, F1),

    osiris_log:close(L2),
    osiris_log:close(R2),
    osiris_log:close(F2),
    FL0 = osiris_log:init(FConf),
    osiris_log:close(FL0),
    ok.

read_chunk(S0) ->
    {ok, {_, _, _, Hd, Ch, Tr}, S1} = osiris_log:read_chunk(S0),
    {[Hd, Ch, Tr], S1}.

accept_chunk_truncates_tail(Config) ->
    ok = logger:set_primary_config(level, all),
    EpochChunks =
        [{1, [<<"one">>]}, {2, [<<"two">>]}, {3, [<<"three">>, <<"four">>]}],
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    LLog = seed_log(LDir, EpochChunks, Config),
    LTail = osiris_log:tail_info(LLog),
    ?assertMatch({4, {3, 2, _}}, LTail), %% {NextOffs, {LastEpoch, LastChunkOffset}}
    ok = osiris_log:close(LLog),

    FollowerEpochChunks =
        [{1, [<<"one">>]}, {2, [<<"two">>]},
         {2, [<<"three">>]}], %% should be truncated next accept
    FDir = ?config(follower1_dir, Config),
    FLog0 = seed_log(FDir, FollowerEpochChunks, Config),
    osiris_log:close(FLog0),

    {Range, EOffs} = osiris_log:overview(LDir),
    ALog0 =
        osiris_log:init_acceptor(Range, EOffs, Conf#{dir => FDir, epoch => 2}),

    RConf = Conf#{dir => LDir,
                  shared => osiris_log:get_shared(FLog0)},
    {ok, RLog0} =
        osiris_log:init_data_reader(osiris_log:tail_info(ALog0), RConf),
    {ok, {_, _, _, Hd, Ch, Tr}, _RLog} = osiris_log:read_chunk(RLog0),
    ALog = osiris_log:accept_chunk([Hd, Ch, Tr], ALog0),
    osiris_log:close(ALog),
    % validate equal
    ?assertMatch({Range, EOffs}, osiris_log:overview(FDir)),
    ok.

accept_chunk_does_not_truncate_tail_in_same_epoch(Config) ->
    ok = logger:set_primary_config(level, all),
    EpochChunks =
        [{1, [<<"one">>]},
         {1, [<<"two">>, <<"two">>]},
         {1, [<<"three">>]},
         {1, [<<"four">>]}],
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    LLog = seed_log(LDir, EpochChunks, Config),
    LTail = osiris_log:tail_info(LLog),
    ?assertMatch({5, {1, 4, _}}, LTail), %% {NextOffs, {LastEpoch, LastChunkOffset}}
    ok = osiris_log:close(LLog),
    FollowerEpochChunks =
        [{1, [<<"one">>]},
         {1, [<<"two">>, <<"two">>]}],
    FDir = ?config(follower1_dir, Config),
    FLog0 = seed_log(FDir, FollowerEpochChunks, Config),
    osiris_log:close(FLog0),

    {Range, EOffs} = osiris_log:overview(LDir),
    ALog0 = osiris_log:init_acceptor(Range, EOffs, Conf#{dir => FDir, epoch => 2}),
    ATail = osiris_log:tail_info(ALog0),
    osiris_log:close(ALog0),
    %% ensure we don't truncate too much
    ?assertMatch({3, {1, 1, _}}, ATail),
    ok.

accept_chunk_in_other_epoch(Config) ->
    ok = logger:set_primary_config(level, all),
    EpochChunks =
        [{1, [<<"one">>]},
         {1, [<<"two">>, <<"two">>]},
         {1, [<<"three">>]},
         {2, [<<"four">>]}],
    Conf = ?config(osiris_conf, Config),
    LDir = ?config(leader_dir, Config),
    LLog = seed_log(LDir, EpochChunks, Config),
    LTail = osiris_log:tail_info(LLog),
    ?assertMatch({5, {2, 4, _}}, LTail), %% {NextOffs, {LastEpoch, LastChunkOffset}}
    ok = osiris_log:close(LLog),
    FollowerEpochChunks =
        [{1, [<<"one">>]},
         {1, [<<"two">>, <<"two">>]}],
    FDir = ?config(follower1_dir, Config),
    FLog0 = seed_log(FDir, FollowerEpochChunks, Config),
    osiris_log:close(FLog0),

    {Range,  EOffs} = osiris_log:overview(LDir),
    ALog0 = osiris_log:init_acceptor(Range, EOffs, Conf#{dir => FDir, epoch => 2}),
    ATail = osiris_log:tail_info(ALog0),
    osiris_log:close(ALog0),
    %% ensure we don't truncate too much
    ?assertMatch({3, {1, 1, _}}, ATail),
    ok.


init_epoch_offsets_discards_all_when_no_overlap_in_same_epoch(Config) ->
    EpochChunks =
        [{1, [<<"one">>]},
         {1, [<<"two">>]},
         {1, [<<"three">>, <<"four">>]}],
    LDir = ?config(leader_dir, Config),
    LogInit = seed_log(LDir, EpochChunks, Config),
    osiris_log:close(LogInit),
    EOffs = [{1, 10}],
    Range = {5, 10}, %% replica's range is 0, 3
    Log0 =
        osiris_log:init_acceptor(Range, EOffs,
                                 #{dir => LDir,
                                   name => ?config(test_case, Config),
                                   epoch => 2}),
    {5, empty} = osiris_log:tail_info(Log0),
    osiris_log:close(Log0),
    ok.

overview(Config) ->
    EpochChunks =
        [{1, [<<"one">>]},
         {1, [<<"two">>]},
         {2, [<<"three">>, <<"four">>]},
         {2, [<<"five">>]}],
    LDir = ?config(leader_dir, Config),
    Log0 = seed_log(LDir, EpochChunks, Config),
    osiris_log:close(Log0),
    {{0, 4}, [{1, 1}, {2, 4}]} = osiris_log:overview(LDir),
    %% non existant dir should return empty
    {empty, []} = osiris_log:overview("/tmp/blahblah"),
    ok.

init_corrupted_log(Config) ->
    % this test intentionally corrupts the log in a way we observed
    % when a working system was suddenly powered off; since index
    % is written first, it contains an entry for a chunk that was not
    % written; additionally the index contains some trailing zeros
    % index:
    % | index header
    % | chunk0 record
    % | chunk1 record
    % | chunk2 record
    % | chunk3 record
    % | 000000000000000000000000000000000000000000000000000000000000
    % segment:
    % | segment header
    % | {0, <<one>>}
    % | {1, <<two>>}
    % | {2, <<three   (this chunk is corrupted)
    % | eof           (chunk3 is missing)
    EpochChunks = [{1, [<<"one">>]}, {1, [<<"two">>]}],
    LDir = ?config(leader_dir, Config),
    Log0 = seed_log(LDir, EpochChunks, Config),
    SegPath = filename:join(LDir, "00000000000000000000.segment"),
    IdxPath = filename:join(LDir, "00000000000000000000.index"),
    % record the segment and index sizes before corrupting the log
    ValidSegSize = filelib:file_size(SegPath),
    ValidIdxSize = filelib:file_size(IdxPath),
    {{0, 1}, _} = osiris_log:overview(LDir),

    % add one more chunk and truncate it from the segment but leave in the index)
    Log1 = osiris_log:write([<<"three">>], Log0),
    SegSizeWith3Chunks = filelib:file_size(SegPath),
    Log2 = osiris_log:write([<<"four">>], Log1),
    osiris_log:close(Log2),
    {ok, SegFd} = file:open(SegPath, [raw, binary, read, write]),
    % truncate the file so that chunk <<four>> is missing and <<three>> is corrupted
    {ok, _} = file:position(SegFd, SegSizeWith3Chunks - 3),
    _ = file:truncate(SegFd),
    _ = file:close(SegFd),
    % append 60 zeros to the index file
    {ok, IdxFd} =
    _ = file:open(IdxPath, [raw, binary, read, write]),
    {ok, _} = file:position(IdxFd, eof),
    ok = file:write(IdxFd, <<0:480>>),
    ok = file:close(IdxFd),

    % the overview should work even before init
    {Range, _} = osiris_log:overview(LDir),
    ?assertEqual({0, 1}, Range),

    Conf0 = ?config(osiris_conf, Config),
    Conf = Conf0#{dir => LDir},
    _ = osiris_log:init(Conf),
    set_shared(Conf, 2),

    % after osiris_log:init, the sizes of the index and segment files
    % should be as they were before they got corrrupted
    ?assertEqual(ValidIdxSize, filelib:file_size(IdxPath)),
    ?assertEqual(ValidSegSize, filelib:file_size(SegPath)),

    % the range should not include the corrupted chunk
    {Range, _} = osiris_log:overview(LDir),
    ?assertEqual({0, 1}, Range),

    % a consumer asking for the last chunk, should receive "two"
    {ok, R0} = osiris_log:init_offset_reader(last, Conf),
    {ReadChunk, R1} = osiris_log:read_chunk_parsed(R0),
    ?assertMatch([{1, <<"two">>}], ReadChunk),
    osiris_log:close(R1),
    ok.

init_only_one_corrupted_segment(Config) ->
    Data = crypto:strong_rand_bytes(1500),
    EpochChunks =
    [begin {1, [Data || _ <- lists:seq(1, 50)]} end
     || _ <- lists:seq(1, 20)],
    LDir = ?config(leader_dir, Config),
    Log = seed_log(LDir, EpochChunks, Config),
    osiris_log:close(Log),

    % we should have 2 segments for this test
    IdxFiles =
    filelib:wildcard(
      filename:join(LDir, "*.index")),
    ?assertEqual(2, length(IdxFiles)),
    SegFiles =
    filelib:wildcard(
      filename:join(LDir, "*.segment")),
    ?assertEqual(2, length(SegFiles)),

    % delete the first segment
    ok = file:delete(hd(IdxFiles)),
    ok = file:delete(hd(SegFiles)),

    % truncate the last segment
    LastIdxFile = lists:last(IdxFiles),
    LastSegFile = lists:last(SegFiles),
    {ok, IdxFd} = file:open(LastIdxFile, [raw, binary, write]),
    ok = file:close(IdxFd),
    {ok, SegFd} = file:open(LastSegFile, [raw, binary, write]),
    ok = file:close(SegFd),

    % init
    Conf0 = ?config(osiris_conf, Config),
    Conf = Conf0#{dir => LDir},
    _ = osiris_log:init(Conf),
    set_shared(Conf, 1000),

    % there should be one segment, with nothing but headers
    % and its name should be the same as it was before
    % (the file is used to store the last known chunk ID)
    ?assertEqual(?LOG_HEADER_SIZE, filelib:file_size(LastSegFile)),
    ?assertEqual(?IDX_HEADER_SIZE, filelib:file_size(LastIdxFile)),
    {ok, IdxFd2} = file:open(LastIdxFile, [read, raw, binary]),
    {ok, ?IDX_HEADER} = file:read(IdxFd2, ?IDX_HEADER_SIZE),
    ok = file:close(IdxFd2),
    {ok, SegFd2} = file:open(LastSegFile, [read, raw, binary]),
    {ok, ?LOG_HEADER} = file:read(SegFd2, ?LOG_HEADER_SIZE),
    ok = file:close(SegFd2),
    ok.

init_empty_last_files(Config) ->
    % this test intentionally corrupts the log by truncating
    % both the segment and the index files to zero bytes
    Data = crypto:strong_rand_bytes(1500),
    EpochChunks =
    [begin {1, [Data || _ <- lists:seq(1, 50)]} end
     || _ <- lists:seq(1, 20)],
    LDir = ?config(leader_dir, Config),
    Log = seed_log(LDir, EpochChunks, Config),
    osiris_log:close(Log),

    % we should have 2 segments for this test
    IdxFiles =
    filelib:wildcard(
      filename:join(LDir, "*.index")),
    ?assertEqual(2, length(IdxFiles)),
    SegFiles =
    filelib:wildcard(
      filename:join(LDir, "*.segment")),
    ?assertEqual(2, length(SegFiles)),

    % truncate both files (by opening with "write" but without "read")
    LastIdxFile = lists:last(IdxFiles),
    LastSegFile = lists:last(SegFiles),
    {ok, IdxFd} = file:open(LastIdxFile, [raw, binary, write]),
    _ =file:close(IdxFd),
    {ok, SegFd} = file:open(LastSegFile, [raw, binary, write]),
    _ = file:close(SegFd),

    ?assertEqual({{0,699},[{1,650}]}, osiris_log:overview(LDir)),

    Conf0 = ?config(osiris_conf, Config),
    Conf = Conf0#{dir => LDir},
    _ = osiris_log:init(Conf),
    set_shared(Conf, 2),

    % the last segment and index files should no longer exist
    RecoveredIdxFiles =
        lists:map(fun filename:basename/1,
                  filelib:wildcard(
                    filename:join(LDir, "*.index"))),
    ?assertEqual(["00000000000000000000.index"],
                 RecoveredIdxFiles, "an empty index file was not deleted"),
    RecoveredSegFiles =
        lists:map(fun filename:basename/1,
                  filelib:wildcard(
                    filename:join(LDir, "*.segment"))),
    ?assertEqual(["00000000000000000000.segment"],
                 RecoveredSegFiles, "an empty segment file was not deleted"),
    ok.

evaluate_retention_max_bytes(Config) ->
    Data = crypto:strong_rand_bytes(1500),
    EpochChunks =
        [begin {1, [Data || _ <- lists:seq(1, 50)]} end
         || _ <- lists:seq(1, 20)],
    LDir = ?config(leader_dir, Config),
    Log = seed_log(LDir, EpochChunks, Config),
    osiris_log:close(Log),
    %% this should delete at least one segment
    Spec = {max_bytes, 1500 * 100},
    Range = osiris_log:evaluate_retention(LDir, [Spec]),
    %% idempotency check
    Range = osiris_log:evaluate_retention(LDir, [Spec]),
    SegFiles =
        filelib:wildcard(
            filename:join(LDir, "*.segment")),
    ?assertEqual(1, length(SegFiles)),
    ?assertEqual([],
                 lists:filter(fun(S) ->
                                 lists:suffix("00000000000000000000.segment", S)
                              end,
                              SegFiles),
                 "the retention process didn't delete the oldest segment"),
    ok.

evaluate_retention_max_age_empty(Config) ->
    %% simulates what may occur if retention is evaluated whilst
    %% the stream member is being deleted
    %% it should not crash
    LDir = ?config(leader_dir, Config),
    Spec = [{max_bytes, 100000000}, {max_age, 1000}],
    _ = osiris_log:evaluate_retention(LDir, Spec),
    ok.

evaluate_retention_max_age(Config) ->
    Conf = ?config(osiris_conf, Config),
    Data = crypto:strong_rand_bytes(1500),
    %% all chunks are at least 2000ms old
    Ts = now_ms() - 2000,
    EpochChunks =
        [begin {1, Ts, [Data || _ <- lists:seq(1, 50)]} end
         || _ <- lists:seq(1, 20)],
    LDir = ?config(dir, Config),
    %% this should create at least two segments
    Log = seed_log(Conf#{max_segment_size_bytes => 1000 * 1000}, EpochChunks,
                   Config),
    osiris_log:close(Log),
    SegFilesPre =
        filelib:wildcard(
            filename:join(LDir, "*.segment")),
    ?assertEqual(2, length(SegFilesPre)),
    %% this should delete at least one segment as all chunks should be older
    %% than the retention of 1000ms; max_bytes shouldn't affect the result
    Spec = [{max_bytes, 100000000}, {max_age, 1000}],
    Range = osiris_log:evaluate_retention(LDir, Spec),
    %% idempotency
    Range = osiris_log:evaluate_retention(LDir, Spec),
    SegFiles =
        filelib:wildcard(
            filename:join(LDir, "*.segment")),
    ?assertEqual(1, length(SegFiles)),
    ?assertEqual([],
                 lists:filter(fun(S) ->
                                 lists:suffix("00000000000000000000.segment", S)
                              end,
                              SegFiles),
                 "the retention process didn't delete the oldest segment"),
    ok.

offset_tracking(Config) ->
    Conf = ?config(osiris_conf, Config),
    S0 = osiris_log:init(Conf),
    T0 = osiris_tracking:add(<<"id1">>, offset, 0, undefined,
                             osiris_tracking:init(undefined, #{})),
    {Trailer, T1} = osiris_tracking:flush(T0),
    ?assertEqual(0, osiris_log:next_offset(S0)),
    S1 = osiris_log:write([<<"hi">>], ?CHNK_USER, ?LINE, Trailer, S0),
    ?assertEqual(1, osiris_log:next_offset(S1)),
    T2 = osiris_tracking:add(<<"id1">>, offset, 1, osiris_log:next_offset(S1), T1),
    {Trailer2, _T3} = osiris_tracking:flush(T2),
    S2 = osiris_log:write([<<"hi">>], ?CHNK_USER, ?LINE, Trailer2, S1),
    %% test recovery
    osiris_log:close(S2),
    S3 = osiris_log:init(Conf),
    T = osiris_log:recover_tracking(S3),
    ?assertMatch(#{offsets := #{<<"id1">> := 1}}, osiris_tracking:overview(T)),
    osiris_log:close(S3),
    ok.

offset_tracking_snapshot(Config) ->
    Conf0 = ?config(osiris_conf, Config),
    Conf = Conf0#{max_segment_size_bytes => 1000 * 1000},
    Data = crypto:strong_rand_bytes(1500),
    %% all chunks are at least 2000ms old
    Ts = now_ms() - 2000,
    EpochChunks =
        [begin {1, Ts, [Data || _ <- lists:seq(1, 50)]} end
         || _ <- lists:seq(1, 20)],
    S00 = osiris_log:init(Conf),

    T0 = osiris_tracking:add(<<"wid1">>, sequence, 2, 0,
           osiris_tracking:add(<<"id1">>, offset, 1, undefined,
                             osiris_tracking:init(undefined, #{}))),
    S0 = osiris_log:write([<<"hi">>],
                          ?CHNK_USER,
                          ?LINE,
                          make_trailer(sequence, <<"wid1">>, 2),
                          S00),
    %% write a tracking entry
    S1 = osiris_log:write([],
                          ?CHNK_TRK_DELTA,
                          ?LINE,
                          make_trailer(offset, <<"id1">>, 1),
                          S0),
    %% this should create at least two segments
    {_, S2} = seed_log(Conf, S1, EpochChunks, Config, T0),
    osiris_log:close(S2),
    S3 = osiris_log:init(Conf),
    T = osiris_log:recover_tracking(S3),
    ?assertMatch(#{offsets := #{<<"id1">> := 1},
                   sequences := #{<<"wid1">> := {_, 2}}},
                 osiris_tracking:overview(T)),
    osiris_log:close(S3),
    ok.

many_segment_overview(Config) ->
    Data = crypto:strong_rand_bytes(1000),
    EpochChunks =
    [{1, [Data || _ <- lists:seq(1, 8)]} || _ <- lists:seq(1, 1024)] ++
    [{2, [Data || _ <- lists:seq(1, 8)]} || _ <- lists:seq(1, 1024)] ++
    [{3, [Data || _ <- lists:seq(1, 8)]} || _ <- lists:seq(1, 1024)] ++
    [{4, [Data || _ <- lists:seq(1, 8)]} || _ <- lists:seq(1, 1024)] ++
    [{5, [Data || _ <- lists:seq(1, 8)]} || _ <- lists:seq(1, 1024)],
    Conf0 = ?config(osiris_conf, Config),
    Conf = Conf0#{max_segment_size_bytes => 64000},
    osiris_log:close(seed_log(Conf, EpochChunks, Config)),
    %% {40051,{{0,40959},[{1,8184},{2,16376},{3,24568},{4,32760},{5,40952}]}}
    {OverviewTaken, LogOverview} = timer:tc(fun () ->
                                                    osiris_log:overview(maps:get(dir, Conf))
                                            end),
    ct:pal("OverviewTaken ~p", [OverviewTaken]),
    ct:pal("~p", [LogOverview]),
    %% {{0,40959},[{-1,-1},{1,8184},{2,16376},{3,24568},{4,32760},{5,40952}]}
    ?assertEqual({{0,40959},
                  [{1,8184},{2,16376},{3,24568},{4,32760},{5,40952}]}, LogOverview),
    Conf6 = Conf#{epoch => 6},

    {InitTaken, _} = timer:tc(
                       fun () ->
                               osiris_log:close(osiris_log:init(Conf6))
                       end),
    ct:pal("InitTaken ~p", [InitTaken]),

    {OffsLastTaken, _} =
        timer:tc(fun () ->
                         {ok, L} = osiris_log:init_offset_reader(last, Conf6),
                         osiris_log:close(L)
                 end),
    ct:pal("OffsLastTaken ~p", [OffsLastTaken]),

    {OffsFirstTaken, _} =
        timer:tc(fun () ->
                         {ok, L} = osiris_log:init_offset_reader(first, Conf6),
                         osiris_log:close(L)
                 end),
    ct:pal("OffsFirstTaken ~p", [OffsFirstTaken]),

    {OffsNextTaken, _} =
        timer:tc(fun () ->
                         {ok, L} = osiris_log:init_offset_reader(next, Conf6),
                         osiris_log:close(L)
                 end),
    ct:pal("OffsNextTaken ~p", [OffsNextTaken]),

    {OffsOffsetTakenHi, _} =
        timer:tc(fun () ->
                         {ok, L} = osiris_log:init_offset_reader(40000, Conf6),
                         osiris_log:close(L)
                 end),
    ct:pal("OffsOffsetTakenHi ~p", [OffsOffsetTakenHi]),
    {OffsOffsetTakenLow, _} =
        timer:tc(fun () ->
                         {ok, L} = osiris_log:init_offset_reader(400, Conf6),
                         osiris_log:close(L)
                 end),
    ct:pal("OffsOffsetTakenLow ~p", [OffsOffsetTakenLow]),


    {OffsOffsetTakenMid, _} =
        timer:tc(fun () ->
                         {ok, L} = osiris_log:init_offset_reader(20000, Conf6),
                         osiris_log:close(L)
                 end),
    ct:pal("OffsOffsetTakenMid ~p", [OffsOffsetTakenMid]),

    %% TODO: timestamp
    Ts = erlang:system_time(millisecond) - 100,
    {TimestampTaken, _} =
        timer:tc(fun () ->
                         {ok, L} = osiris_log:init_offset_reader({timestamp, Ts},
                                                                 Conf6),
                         osiris_log:close(L)
                 end),
    ct:pal("TimestampTaken ~p", [TimestampTaken]),

    %% acceptor
    {Range, EOffs} = LogOverview,
    {InitAcceptorTaken, AcceptorLog} =
        timer:tc(fun () ->
                         osiris_log:init_acceptor(Range, EOffs, Conf6)
                 end),
    ct:pal("InitAcceptor took ~bus", [InitAcceptorTaken]),

    {InitDataReaderTaken, _} =
        timer:tc(fun () ->
                         {ok, L} = osiris_log:init_data_reader(
                                     osiris_log:tail_info(AcceptorLog), Conf6),
                         osiris_log:close(L)
                 end),
    ct:pal("InitDataReaderTaken ~p", [InitDataReaderTaken]),

    %% evaluate_retention
    Specs = [{max_age, 60000}, {max_bytes, 5_000_000_000}],
    {RetentionTaken, _} =
        timer:tc(fun () ->
                         osiris_log:evaluate_retention(maps:get(dir, Conf), Specs)
                 end),
    ct:pal("RetentionTaken ~p", [RetentionTaken]),
    ok.

%% Utility

seed_log(Conf, EpochChunks, Config) ->
    Trk = osiris_tracking:init(undefined, #{}),
    element(2, seed_log(Conf, EpochChunks, Config, Trk)).

seed_log(Conf, EpochChunks, Config, Trk) when is_map(Conf) ->
    Log0 = osiris_log:init(Conf),
    seed_log(Conf, Log0, EpochChunks, Config, Trk);
seed_log(Dir, EpochChunks, Config, Trk) when is_list(Dir) ->
    seed_log(#{dir => Dir,
               epoch => 1,
               max_segment_size_bytes => 1000 * 1000,
               name => ?config(test_case, Config)},
             EpochChunks, Config, Trk).

seed_log(Conf, Log, EpochChunks, _Config, Trk) ->
    lists:foldl(fun ({Epoch, Records}, {T, L}) ->
                        write_chunk(Conf, Epoch, now_ms(), Records, T, L);
                    ({Epoch, Ts, Records}, {T, L}) ->
                        write_chunk(Conf, Epoch, Ts, Records, T, L)
                end,
                {Trk, Log}, EpochChunks).

write_chunk(Conf, Epoch, Now, Records, Trk0, Log0) ->
    {Log1, Trk1} = osiris_log:evaluate_tracking_snapshot(Log0, Trk0),
    case osiris_log:get_current_epoch(Log1) of
        Epoch ->
            {Trk1, osiris_log:write(Records, Now, Log1)};
        _ ->
            %% need to re-init as new epoch
            osiris_log:close(Log1),
            Log = osiris_log:init(Conf#{epoch => Epoch}),
            {Trk1, osiris_log:write(Records, Log)}
    end.

now_ms() ->
    erlang:system_time(millisecond).

make_trailer(Type, K, V) ->
    T = case Type of
            sequence -> 0;
            offset -> 1
        end,
    <<T:8/unsigned,
      (byte_size(K)):8/unsigned,
      K/binary,
      V:64/unsigned>>.

set_shared(#{shared := Ref}, Value) ->
    osiris_log_shared:set_committed_chunk_id(Ref, Value).
