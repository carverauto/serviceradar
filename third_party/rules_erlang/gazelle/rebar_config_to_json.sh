#!/usr/bin/env escript
%% -*- erlang -*-
%%! -nocookie
-mode(compile).

-export([main/1]).

-ifdef(TEST).
-export([parse/1]).
-endif.

main(Args) ->
    case io:get_line("") of
        eof ->
            ok;
        Line ->
            Filename = parse_json_string(string:trim(Line, trailing, "\n")),
            Json = parse(Filename),
            io:format("~s", [Json]),
            % signal to hex_metadata.go that the json is written
            io:format(<<0>>),
            main(Args)
    end.

parse_json_string("\"" ++ Tail) ->
    case string:reverse(Tail) of
        "\"" ++ Middle ->
            string:reverse(Middle)
    end.

mapify_dep(Name) when is_atom(Name) ->
    #{name => Name,
      kind => hex};
mapify_dep({Name, Version}) when is_list(Version) ->
    #{name => Name,
      kind => hex,
      version => Version};
mapify_dep({Name, Version, {git = Kind, Remote, Ref}}) ->
    #{name => Name,
      kind => Kind,
      version => Version,
      remote => Remote,
      ref => Ref};
mapify_dep({Name, {git = Kind, Remote, Ref}}) ->
    #{name => Name,
      kind => Kind,
      remote => Remote,
      ref => Ref};
mapify_dep({Name, {hg = Kind, Remote, Ref}}) ->
    #{name => Name,
      kind => Kind,
      remote => Remote,
      ref => Ref};
%% legacy formats
mapify_dep({Name, {git = Kind, Remote}}) ->
    #{name => Name,
      kind => Kind,
      remote => Remote};
mapify_dep({Name, Version, {git = Kind, Remote}}) ->
    #{name => Name,
      kind => Kind,
      version => Version,
      remote => Remote};
mapify_dep({Name, Version, {git = Kind, Remote, Ref}, [raw]}) ->
    #{name => Name,
      kind => Kind,
      version => Version,
      remote => Remote,
      ref => Ref};
%% other formats
mapify_dep({Name, {pkg, _}}) ->
    #{name => Name,
      kind => hex};
mapify_dep({Name, Version, {pkg, _}}) ->
    #{name => Name,
      version => Version,
      kind => hex}.

conformErlOpt(Opt) when is_atom(Opt)->
    #{kind => erlc,
      value => Opt};
conformErlOpt({i, Include}) ->
    #{kind => include,
      value => Include};
conformErlOpt({platform_define, _Platform, _Key}) ->
    #{kind => platform_define,
      value => ignored};
conformErlOpt({platform_define, _Platform, _Key, _Value}) ->
    #{kind => platform_define,
      value => ignored};
conformErlOpt({src_dirs, _SrcDirs}) ->
    #{kind => src_dirs,
      value => ignored};
conformErlOpt(Opt) ->
    #{kind => unknown,
      value => Opt}.

conformConfig(List) ->
    maps:map(
        fun
            (erl_opts, Opts) ->
                [conformErlOpt(O) || O <- Opts];
            (deps, Deps) ->
                [mapify_dep(D) || D <- Deps];
            (_, _) ->
                ignored
        end,
        proplists:to_map(List)).

mapify_pkg({Name, {pkg, Pkg, Version}, _}) ->
    #{name => Name,
      pkg => Pkg,
      version => Version}.

conformLock([{V, Pkgs} | _]) when is_list(Pkgs) ->
    #{version => V,
      pkgs => [mapify_pkg(P) || P <- Pkgs]}.

parse(MetadataFile) ->
    {ok, Metadata} = file:consult(MetadataFile),
    Map = case filename:basename(MetadataFile) of
        "rebar.config" -> conformConfig(Metadata);
        "rebar.lock" -> conformLock(Metadata)
    end,
    %% io:format(standard_error, "Map: ~p~n", [Map]),
    to_json(Map).

to_json(M) when is_map(M) ->
    Pairs = [to_json(K) ++ ": " ++ to_json(V) || {K, V} <- maps:to_list(M)],
    "{" ++ string:join(Pairs, ",") ++ "}";
to_json(S) when is_binary(S) ->
    "\"" ++ binary_to_list(S) ++ "\"";
to_json(A) when is_atom(A) ->
    "\"" ++ atom_to_list(A) ++ "\"";
to_json(T) when is_tuple(T) ->
    "\"" ++ string:replace(
              lists:flatten(io_lib:format("~p", [T])),
              "\"", "\\\"", all) ++ "\"";
to_json([]) ->
    "[]";
to_json(L) when is_list(L) ->
    case io_lib:printable_list(L) of
        true ->
            "\"" ++ L ++ "\"";
        _ ->
            Items = lists:map(fun to_json/1, L),
            "[" ++ string:join(Items, ",") ++ "]"
    end.
