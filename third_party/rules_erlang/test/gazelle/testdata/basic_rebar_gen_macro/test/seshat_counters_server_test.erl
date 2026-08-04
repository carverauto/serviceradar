%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(seshat_counters_server_test).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seshat).

cleanup(_) ->
    ok = application:stop(seshat).

test_suite_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [ fun get_table/0,
       fun get_tables/0,
       fun delete_table/0 ]}.

get_table() ->
    CreatedTable = seshat_counters_server:create_table("burrows"),
    QueriedTable = seshat_counters_server:get_table("burrows"),
    ?assertEqual(CreatedTable, QueriedTable),
    ?assertNotEqual(undefined, ets:info(CreatedTable)).

get_tables() ->
    seshat_counters_server:create_table("burrows"),
    seshat_counters_server:create_table("nests"),
    Tables = lists:sort(maps:keys(seshat_counters_server:get_tables())),
    ?assertEqual(["burrows", "nests"], Tables).

delete_table() ->
    seshat_counters_server:create_table("burrows"),
    seshat_counters_server:create_table("nests"),
    Tables = lists:sort(maps:keys(seshat_counters_server:get_tables())),
    ?assertMatch(["burrows", "nests"], Tables),
    seshat_counters_server:delete_table("nests"),
    seshat_counters_server:delete_table("nests"),
    Tables1 = lists:sort(maps:keys(seshat_counters_server:get_tables())),
    ?assertMatch(["burrows"], Tables1).
