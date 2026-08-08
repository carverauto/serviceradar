%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(seshat_test).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(seshat).

cleanup(_) ->
    ok = application:stop(seshat).

test_suite_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [ fun overview/0,
       fun prometheus_format_multiple_names/0,
       fun invalid_fields/0 ]}.

overview() ->
    Group = "pets",
    Counters = [
                {
                 carrots_eaten_total, 1, counter,
                 "Total number of carrots eaten on a meal"
                },
                {
                 holes_dug_total, 2, counter,
                 "Total number of holes dug in an afternoon"
                }
               ],
    seshat:new_group(Group),
    seshat:new(Group, "rabbit", Counters),
    Ref = seshat:fetch(Group, "rabbit"),
    counters:add(Ref, 1, 3),
    counters:add(Ref, 2, 1),
    Overview = seshat:overview(Group),
    ?assertEqual(
       #{"rabbit" => #{carrots_eaten_total => 3,
                       holes_dug_total => 1}},
       Overview),

    ?assertMatch(#{carrots_eaten_total := 3,
                   holes_dug_total := 1},
                 seshat:overview(Group, "rabbit")),
    ok.

prometheus_format_multiple_names() ->
    Group = people,
    Counters = [{foo, 1, counter, "Total foos given"}],
    seshat:new_group(Group),
    seshat:new(Group, {name, you}, Counters),
    seshat:new(Group, {name, me}, Counters),
    PrometheusFormat = seshat:format(Group),
    ExpectedPrometheusFormat = #{foo => #{type => counter,
                                          help => "Total foos given",
                                          values => #{{name, me} => 0,
                                                      {name, you} => 0}}},
    ?assertEqual(ExpectedPrometheusFormat, PrometheusFormat),
    ok.

invalid_fields() ->
    Group = people,
    Fields = [{foo, 1, counter, "Total foos given"},
              {boo, 3, counter, "Total boos given"}],
    seshat:new_group(Group),
    ?assertError(invalid_field_specification,
                 seshat:new(Group, invalid_fields, Fields)),

    ok.

