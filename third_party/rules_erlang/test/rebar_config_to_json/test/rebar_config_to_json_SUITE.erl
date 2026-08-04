-module(rebar_config_to_json_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all() -> [
          basic
         ].

basic(_) ->
    Json = rebar_config_to_json:parse(fixture_path("test/rebar.config")),
    ct:pal(?LOW_IMPORTANCE, "Json: ~p", [Json]),
    {ok, Parsed} = thoas:decode(Json),
    ?assertMatch(
       #{<<"deps">> := Deps,
         <<"erl_opts">> := Opts} when is_list(Deps) andalso is_list(Opts),
                                      Parsed),
    ?assertMatch(
       [#{<<"kind">> := <<"hex">>,
          <<"name">> := <<"app_name">>},
        #{<<"kind">> := <<"hex">>,
          <<"name">> := <<"rebar">>,
          <<"version">> := <<"1.0.0">>},
        #{<<"kind">> := <<"git">>,
          <<"name">> := <<"rebar">>,
          <<"ref">> := <<"{branch,\"main\"}">>,
          <<"remote">> :=
              <<"git://github.com/rebar/rebar.git">>},
        #{<<"kind">> := <<"git">>,
          <<"name">> := <<"rebar">>,
          <<"ref">> := <<"{branch,\"main\"}">>,
          <<"remote">> :=
              <<"https://github.com/rebar/rebar.git">>},
        #{<<"kind">> := <<"git">>,
          <<"name">> := <<"rebar">>,
          <<"ref">> := <<"{tag,\"1.0.0\"}">>,
          <<"remote">> :=
              <<"https://github.com/rebar/rebar.git">>},
        #{<<"kind">> := <<"git">>,
          <<"name">> := <<"rebar">>,
          <<"ref">> := <<"{ref,\"7f73b8d6\"}">>,
          <<"remote">> :=
              <<"https://github.com/rebar/rebar.git">>},
        #{<<"kind">> := <<"hg">>,<<"name">> := <<"rebar">>,
          <<"ref">> := <<"{tag,\"1.0.0\"}">>,
          <<"remote">> :=
              <<"https://github.com/rebar/rebar.git">>},
        #{<<"kind">> := <<"git">>,
          <<"name">> := <<"rebar">>,
          <<"remote">> :=
              <<"git://github.com/rebar/rebar.git">>},
        #{<<"kind">> := <<"git">>,
          <<"name">> := <<"rebar">>,
          <<"remote">> :=
              <<"git://github.com/rebar/rebar.git">>,
          <<"version">> := <<"1.0.*">>},
        #{<<"kind">> := <<"git">>,
          <<"name">> := <<"rebar">>,<<"ref">> := <<"Rev">>,
          <<"remote">> :=
              <<"git://github.com/rebar/rebar.git">>,
          <<"version">> := <<"1.0.*">>},
        #{<<"kind">> := <<"git">>,
          <<"name">> := <<"rebar">>,
          <<"ref">> := <<"{branch,\"main\"}">>,
          <<"remote">> :=
              <<"git://github.com/rebar/rebar.git">>,
          <<"version">> := <<".*">>}],
       maps:get(<<"deps">>, Parsed)),
    ?assertMatch(
       [#{<<"kind">> := <<"erlc">>,
          <<"value">> := <<"no_debug_info">>} | _],
       maps:get(<<"erl_opts">>, Parsed)),
    ok.

fixture_path(File) ->
    filename:join([os:getenv("TEST_SRCDIR"),
                   os:getenv("TEST_WORKSPACE"),
                   "rebar_config_to_json",
                   File]).
