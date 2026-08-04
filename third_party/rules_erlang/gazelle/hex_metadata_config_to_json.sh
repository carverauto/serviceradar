#!/usr/bin/env escript
%% -*- erlang -*-
%%! -nocookie
-mode(compile).

-export([main/1]).

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

deep_mapify(List) ->
    maps:map(
        fun
            (_, [[{_, _} | _] | _] = L) ->
                [deep_mapify(E) || E <- L];
            (_, [{_, _} | _] = V) ->
                deep_mapify(V);
            (_, V) ->
                V
        end,
        proplists:to_map(List)).

parse(MetadataFile) ->
    {ok, Metadata} = file:consult(MetadataFile),
    Map = deep_mapify(Metadata),
    to_json(Map).

to_json(M) when is_map(M) ->
    Pairs = [to_json(K) ++ ": " ++ to_json(V) || {K, V} <- maps:to_list(M)],
    "{" ++ string:join(Pairs, ",") ++ "}";
to_json(S) when is_binary(S) ->
    "\"" ++ binary_to_list(S) ++ "\"";
to_json(A) when is_atom(A) ->
    atom_to_list(A);
to_json(L) when is_list(L) ->
    Items = lists:map(fun to_json/1, L),
    "[" ++ string:join(Items, ",") ++ "]".
