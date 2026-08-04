-module(shard_suite_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all() -> [
          structure,
          ordered_cases,
          cases_by_group,
          shard_by_group,
          shard_by_case,
          flatten_shard,
          flatten_shard_with_nested_group,
          to_ct_run_args,
          when_all_references_missing_group
         ].

structure(_) ->
    ?assertEqual([{a_group,
                   [one_test, two_test]},
                  {another_group,
                   [two_test,
                    {nested_group, [nested_test]},
                    three_test]}],
                 shard_suite:structure(example_suite)).

ordered_cases(_) ->
    S = shard_suite:structure(example_suite),
    ?assertEqual([
                  {[a_group], one_test},
                  {[a_group], two_test},
                  {[another_group], two_test},
                  {[another_group, nested_group], nested_test},
                  {[another_group], three_test}
                 ],
                 shard_suite:ordered_cases(S)).

cases_by_group(_) ->
    S = shard_suite:structure(example_suite),
    Cases = shard_suite:ordered_cases(S),
    ?assertEqual([{[a_group], [one_test,two_test]},
                  {[another_group], [two_test,three_test]},
                  {[another_group,nested_group], [nested_test]}],
                 shard_suite:cases_by_grouppath(Cases, [])).

shard_by_group(_) ->
    S = shard_suite:structure(example_suite),
    Cases = shard_suite:ordered_cases(S),
    ?assertEqual({ok, [{[a_group], one_test},
                       {[a_group], two_test}]},
                 shard_suite:shard(group, Cases, 0, 3)),
    ?assertEqual({ok, [{[another_group], two_test},
                       {[another_group], three_test}]},
                 shard_suite:shard(group, Cases, 1, 3)),
    ?assertEqual({ok, [{[another_group, nested_group], nested_test}]},
                 shard_suite:shard(group, Cases, 2, 3)).

shard_by_case(_) ->
    S = shard_suite:structure(example_suite),
    Cases = shard_suite:ordered_cases(S),
    ?assertEqual({ok, [{[a_group], one_test}]},
                 shard_suite:shard('case', Cases, 0, 5)).

flatten_shard(_) ->
    S = shard_suite:structure(example_suite),
    Cases = shard_suite:ordered_cases(S),
    {ok, ShardOne} = shard_suite:shard(group, Cases, 0, 3),
    ?assertEqual(#{grouppaths => [[a_group]],
                   cases => [one_test,two_test]},
                 shard_suite:flatten_shard(ShardOne)).

flatten_shard_with_nested_group(_) ->
    S = shard_suite:structure(example_suite),
    Cases = shard_suite:ordered_cases(S),
    {ok, ShardThree} = shard_suite:shard(group, Cases, 2, 3),
    ?assertEqual(#{grouppaths => [[another_group, nested_group]],
                   cases => [nested_test]},
                 shard_suite:flatten_shard(ShardThree)).

to_ct_run_args(_) ->
    SuiteModule = example_suite,
    S = shard_suite:structure(SuiteModule),
    Cases = shard_suite:ordered_cases(S),
    {ok, ShardThree} = shard_suite:shard(group, Cases, 2, 3),
    ?assertEqual("-suite example_suite -group [another_group,nested_group] -case nested_test",
                 lists:flatten(
                   shard_suite:to_ct_run_args(SuiteModule,
                                              shard_suite:flatten_shard(ShardThree)))).

%% errors for missing groups are build into otp 26.2
%% but since we test with otp 25.x as well, we can
%% use 25.x for testing the old behaviour in
%% rules_erlang
-if(?OTP_RELEASE >= 25).
when_all_references_missing_group(_) ->
    ok.
-else.
when_all_references_missing_group(_) ->
    ?assertThrow(missing_group, shard_suite:structure(example_suite_missing_group)).
-endif.
