-module(example_suite_missing_group).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, groups/0]).

%% errors for missing groups are build into otp 26.2
%% but since we test with otp 25.x as well, we can
%% use 25.x for testing the old behaviour in
%% rules_erlang
-if(?OTP_RELEASE >= 25).
all() ->
    [{group, a_group}].
-else.
all() ->
    [{group, a_group},
     {group, missing_group}].
-endif.

groups() ->
    [{a_group, [], [one_test, two_test]}].

one_test(_Config) ->
    ?assertEqual(true, true).

two_test(_Config) ->
    ?assertEqual(true, true).
