-module(example_suite).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, groups/0]).

all() ->
    [{group, a_group},
     {group, another_group}].

groups() ->
    [{a_group, [], [one_test, two_test]},
     {another_group, [], [
         two_test,
         {nested_group, [], [nested_test]},
         three_test]},
     {unused_group, [], [four_test]}].

one_test(_Config) ->
    ?assertEqual(true, true).

two_test(_Config) ->
    ?assertEqual(true, true).

three_test(_Config) ->
    ?assertEqual(true, true).

four_test(_Config) ->
    ?assertEqual(false, true).

nested_test(_Config) ->
    ?assertEqual(true, true).
