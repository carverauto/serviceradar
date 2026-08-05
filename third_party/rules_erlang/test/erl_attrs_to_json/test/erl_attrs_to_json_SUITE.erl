-module(erl_attrs_to_json_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all() -> [
          conform_command,
          basic,
          test_src
         ].

conform_command(_) ->
    Command1 = thoas:encode(
                 #{path => <<"/some/path/foo.erl">>,
                   macros => #{'TEST' => null},
                   includes => [<<"/some/path">>]}),
    ct:pal(?LOW_IMPORTANCE, "Command1: ~p", [Command1]),
    {ok, Command1Decoded} = thoas:decode(Command1),
    ?assertEqual(
       #{path => "/some/path/foo.erl",
         macros => ['TEST'],
         includes => ["/some/path"]},
       erl_attrs_to_json:conform_command(Command1Decoded)),

    Command2 = thoas:encode(
                 #{path => <<"/some/path/bar.erl">>,
                   macros => #{'TEST' => <<"1">>},
                   includes => [<<"/some/path">>]}),
    ct:pal(?LOW_IMPORTANCE, "Command2: ~p", [Command2]),
    {ok, Command2Decoded} = thoas:decode(Command2),
    ?assertEqual(
       #{path => "/some/path/bar.erl",
         macros => [{'TEST', "1"}],
         includes => ["/some/path"]},
       erl_attrs_to_json:conform_command(Command2Decoded)).

basic(Config) ->
    ?assertEqual(
       #{
         include_lib => [],
         include => [<<"my_header.hrl">>, <<"basic.hrl">>],
         behaviour => [],
         parse_transform => [my_pt],
         call => #{
                   filename => [split],
                   io => [format],
                   maps => [merge],
                   other_lib => [foo, bar, finalize, encode, calc],
                   some_other_lib => [bar, baz, fizz]
                  }
        },
       erl_attrs_to_json:parse(
         filename:join([?config(data_dir, Config), "basic.erl"]),
         [], ["test"])),
    ?assertEqual(
       #{
         include_lib => [<<"some_lib/include/some_header.hrl">>],
         include => [<<"my_header.hrl">>, <<"basic.hrl">>],
         behaviour => [],
         parse_transform => [my_pt],
         call => #{
                   filename => [split],
                   io => [format],
                   maps => [merge],
                   other_lib => [foo, bar, finalize, encode, calc],
                   some_other_lib => [bar, baz, fizz]
                  }
        },
       erl_attrs_to_json:parse(
         filename:join([?config(data_dir, Config), "basic.erl"]),
         ['TEST'], ["test"])).

test_src(Config) ->
   ?assertMatch(
      #{
        include_lib := [<<"proper/include/proper.hrl">>],
        parse_transform := [eunit_autoexport],
        call := #{
         proper := [counterexample]
        }
       },
      erl_attrs_to_json:parse(
        filename:join([?config(data_dir, Config), "test.erl"]),
        ['TEST'], ["test"])).
