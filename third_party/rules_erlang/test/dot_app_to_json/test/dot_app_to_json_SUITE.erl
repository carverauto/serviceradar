-module(dot_app_to_json_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all() -> [
          basic
         ].

basic(_) ->
    Json = dot_app_to_json:parse(fixture_path("test/basic.app.src")),
    ct:pal(?LOW_IMPORTANCE, "Json: ~p", [Json]),
    {ok, Parsed} = thoas:decode(Json),
    ?assertMatch(
       #{<<"basic">> :=
             #{<<"applications">> :=
                   [<<"kernel">>,<<"stdlib">>],
               <<"description">> := <<"Basic App">>,
               <<"licenses">> := [<<"Apache-2.0">>],
               <<"vsn">> :=
                   #{<<"cmd">> :=
                         <<"git describe --tags --always">>}}},
       Parsed).

fixture_path(File) ->
    filename:join([os:getenv("TEST_SRCDIR"),
                   os:getenv("TEST_WORKSPACE"),
                   "dot_app_to_json",
                   File]).
