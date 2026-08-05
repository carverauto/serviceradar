-module(compile_first).

-mode(compile).

-export([main/1]).

-spec main([string()]) -> no_return().

main(ErlFiles) ->

    %% This can be a simplified analysis, as deps
    %% are already compiled. We just need to cover
    %% things like behaviors within the set of
    %% ErlFiles

    E = ets:new(makedep, [bag]),
    F = ets:new(visitedfiles, [bag]),

    walk_files(ErlFiles, E, F),

    CompileFirst = lists:filter(fun (File) ->
                                        Mod = list_to_atom(filename:basename(File, ".erl")),
                                        ets:member(E, Mod)
                                end, ErlFiles),
    io:format("~s~n", [string:join(CompileFirst, " ")]),
    ok.

walk_files(ErlFiles, E, F) ->
    [begin
         case file:open(File, [read]) of
             {ok, Fd} ->
                 walk_forms(E, F, filename:dirname(File), Fd, 0);
            Other -> io:format("ERROR ~p for file ~p~n", [Other, File])
         end
     end || File <- ErlFiles].

walk_forms(E, F, Dir, Fd, StartLocation) ->
    case io:parse_erl_form(Fd, undefined, StartLocation) of
        {ok, AbsData, EndLocation} ->
            case AbsData of
                {attribute, _, Key, Value} ->
                    record_attr(E, F, Dir, Key, Value),
                    walk_forms(E, F, Dir, Fd, EndLocation);
                _ ->
                    walk_forms(E, F, Dir, Fd, EndLocation)
            end;
        {eof, _} ->
            file:close(Fd);
        {error, _} ->
            file:close(Fd);
        {error, _, ErrorLocation} ->
            walk_forms(E, F, Dir, Fd, ErrorLocation)
    end.

record_attr(E, _F, _Dir, behavior, Dep) ->
    ets:insert(E, {Dep});
record_attr(E, _F, _Dir, behaviour, Dep) ->
    ets:insert(E, {Dep});
record_attr(E, _F, _Dir, compile, {parse_transform, Dep}) ->
    ets:insert(E, {Dep});
record_attr(E, _F, _Dir, compile, Opts) when is_list(Opts) ->
    case proplists:get_value(parse_transform, Opts) of
        undefined -> ok;
        Dep -> ets:insert(E, {Dep})
    end;
record_attr(E, F, Dir, include, Path) ->
    case ets:member(F, Path) of
        false ->
            ets:insert(F, {Path}),
            RelPath = filename:join([Dir, Path]),
            case filelib:is_file(RelPath) of
                true ->
                    walk_files([filename:join([RelPath])], E, F);
                false ->
                    IncludePath = filename:join([Dir, "../include", Path]),
                    case filelib:is_file(IncludePath) of
                        true ->
                            walk_files([IncludePath], E, F);
                        false ->
                            ok
                    end
            end;
        true ->
            ok
    end;
record_attr(_, _, _, _, _) ->
    ok.