-module(shard_suite_test).
-include_lib("eunit/include/eunit.hrl").

%% A basic eunit test, to prove that the eunit rule works

basic_test() ->
    SuiteModule = example_suite,
    S = shard_suite:structure(SuiteModule),
    Cases = shard_suite:ordered_cases(S),
    ?assertMatch({ok, _},
                 shard_suite:shard(group, Cases, 2, 3)).
