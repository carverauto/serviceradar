-module(erl_attrs_to_json).

-export([main/1]).

-ifdef(TEST).
-export([parse/3,
         conform_command/1]).
-endif.

-type macro() :: [atom() | {atom(), term()}].

-spec main([string()]) -> no_return().
main(Args) ->
    case io:get_line("") of
        eof ->
            ok;
        Line ->
            {ok, Command} = thoas:decode(Line),
            %% io:format(standard_error, "Command: ~p~n", [Command]),
            #{path := Filename,
              macros := Macros,
              includes := Includes} = conform_command(Command),
            Map = parse(Filename, Macros, Includes),
            %% io:format(standard_error, "Map: ~p~n", [Map]),
            Json = thoas:encode(Map),
            io:format("~ts", [Json]),
            % signal to erl_parser_impl.go that the json is written
            io:format(<<0>>),
            main(Args)
    end.

-spec conform_command(thoas:json_term()) -> #{path := string(), macros := [macro()], includes := [string()]}.
conform_command(JsonTerm) when is_map(JsonTerm) ->
    maps:from_list(
     lists:map(fun
                   ({<<"path">> = K, V}) ->
                       {binary_to_atom(K), binary_to_list(V)};
                   ({<<"macros">> = K, V}) ->
                       {binary_to_atom(K), conform_macros(V)};
                   ({<<"includes">> = K, V}) ->
                       {binary_to_atom(K), lists:map(fun erlang:binary_to_list/1, V)}
               end, maps:to_list(JsonTerm))).

conform_macros(M) when is_map(M) ->
    lists:map(fun
                  ({K, null}) ->
                      binary_to_atom(K);
                  ({K, V}) ->
                      {binary_to_atom(K), binary_to_list(V)}
              end, maps:to_list(M)).

drop_common([C | L], [C | R]) ->
    drop_common(L, R);
drop_common(L, R) ->
    {L, R}.

relpath(Base, File) ->
    BaseComponents = filename:split(Base),
    FileComponents = filename:split(File),
    {BC, FC} = drop_common(BaseComponents, FileComponents),
    case {BC, FC} of
        {[_], [R]} -> R;
        {[_], C} -> filename:join(C);
        {BC, FC} -> filename:join([".." || _ <- BC] ++ FC)
    end.

record_attr(E, _, behavior, Dep) ->
    ets:insert(E, {behaviour, Dep});
record_attr(E, _, behaviour, Dep) ->
    ets:insert(E, {behaviour, Dep});
record_attr(E, _, compile, {parse_transform, Dep}) ->
    ets:insert(E, {parse_transform, Dep});
record_attr(E, _, compile, Opts) when is_list(Opts) ->
    case proplists:get_value(parse_transform, Opts) of
        undefined -> ok;
        Dep -> ets:insert(E, {parse_transform, Dep})
    end;
record_attr(E, File, file, {Path, _}) when File =/= Path ->
    case string:reverse(Path) of
        "lrh." ++ _ ->
            RelPath = relpath(File, Path),
            ets:insert(E, {include, RelPath});
        _ ->
            ok
    end;
record_attr(E, _, include, Path) ->
    ets:insert(E, {include, Path});
record_attr(E, _, include_lib, Path) ->
    ets:insert(E, {include_lib, Path});
record_attr(_, _, _Name, _Value) ->
    %% io:format(standard_error, "record_attr: ~p:~p~n", [Name, Value]),
    ok.

record_expression(E, {remote, _, {atom, _, M}, {atom, _, F}}) ->
    %% io:format(standard_error, "remote: ~p:~p~n", [M, F]),
    ets:insert(E, {call, M, F});
record_expression(E, {call, _, F, Args}) ->
    lists:foreach(
      fun (Arg) -> record_expression(E, Arg) end,
      Args),
    record_expression(E, F);
record_expression(E, {'fun', _, {clauses, Clauses}}) ->
    lists:foreach(
      fun (Clause) -> record_expression(E, Clause) end,
      Clauses);
record_expression(E, {clause, _, Args, _Guards, Expressions}) ->
    lists:foreach(
      fun (Arg) -> record_expression(E, Arg) end,
      Args),
    lists:foreach(
      fun (Expression) -> record_expression(E, Expression) end,
      Expressions);
record_expression(E, {block, _, Expressions}) ->
    lists:foreach(
      fun (Expression) -> record_expression(E, Expression) end,
      Expressions);
record_expression(E, {'case', _, Arg, Expressions}) ->
    %% io:format(standard_error, "case: ~p~n", [Arg]),
    record_expression(E, Arg),
    lists:foreach(
      fun (Expression) -> record_expression(E, Expression) end,
      Expressions);
record_expression(E, {'try', _, Expressions, _, Clauses, Afters}) ->
    lists:foreach(
      fun (Expression) -> record_expression(E, Expression) end,
      Expressions),
    lists:foreach(
      fun (Clause) -> record_expression(E, Clause) end,
      Clauses),
    lists:foreach(
      fun (After) -> record_expression(E, After) end,
      Afters);
record_expression(E, {match, _, Lhs, Rhs}) ->
    record_expression(E, Lhs),
    record_expression(E, Rhs);
record_expression(E, {tuple, _, Elements}) ->
    lists:foreach(
      fun (Element) -> record_expression(E, Element)end,
      Elements);
record_expression(E, {map, _, Assocs}) ->
    lists:foreach(
      fun
          ({map_field_assoc, _, Lhs, Rhs}) ->
              record_expression(E, Lhs),
              record_expression(E, Rhs);
          (_) ->
              ok
      end,
      Assocs);
record_expression(E, {cons, _, Head, Tail}) ->
    record_expression(E, Head),
    record_expression(E, Tail);
record_expression(E, {op, _, _, Lhs, Rhs}) ->
    record_expression(E, Lhs),
    record_expression(E, Rhs);
record_expression(_, _Exp) ->
    %% io:format(standard_error, "E: ~p~n", [Exp]),
    ok.

note_form(_, _, {eof, _}) ->
    ok;
note_form(E, File, {error, {_, epp, {include, lib, Dep}}}) ->
    record_attr(E, File, include_lib, Dep);
note_form(E, File, {error, {_, epp, {include, file, Dep}}}) ->
    record_attr(E, File, include, Dep);
note_form(_, _, {error, _Reason}) ->
    %% io:format(standard_error, "error: ~p~n", [Reason]),
    ok;
note_form(E, File, {attribute, _, Key, Value} = _AbsData) ->
    %% io:format(standard_error, "AbsData: ~p~n", [AbsData]),
    record_attr(E, File, Key, Value);
note_form(E, _, {function, _, _, _, Clauses} = _AbsData) ->
    %% io:format(standard_error, "AbsData: ~p~n", [AbsData]),
    lists:foreach(
      fun (Clause) -> record_expression(E, Clause) end,
      Clauses);
note_form(_, _, _AbsData) ->
    %% io:format(standard_error, "AbsData: ~p~n", [AbsData]),
    ok.

deps(E) ->
    ets:foldl(
      fun
          ({include_lib, Path}, #{include_lib := IncludeLib} = Acc) ->
              Acc#{include_lib := [list_to_binary(Path) | IncludeLib]};
          ({include, Path}, #{include := Include} = Acc) ->
              Acc#{include := [list_to_binary(Path) | Include]};
          ({behaviour, Dep}, #{behaviour := Behaviours} = Acc) ->
              Acc#{behaviour := [Dep | Behaviours]};
          ({parse_transform, Dep}, #{parse_transform := Transforms} = Acc) ->
              Acc#{parse_transform := [Dep | Transforms]};
          ({call, M, F}, #{call := Calls0} = Acc) ->
              Calls = maps:update_with(M,
                                       fun(Fs) ->
                                               case lists:member(F, Fs) of
                                                   false ->
                                                       [F | Fs];
                                                   _ ->
                                                       Fs
                                               end
                                       end,
                                       [F],
                                       Calls0),
              Acc#{call := Calls};
          (_, Acc) ->
              Acc
      end,
      #{
        include_lib => [],
        include => [],
        behaviour => [],
        parse_transform => [],
        call => #{}
       },
      E).

-spec parse(file:name(), [macro()], [string()]) -> map() | 'null'.
parse(File, Macros, Includes) ->
    Opts0 = [],
    Opts1 = case Macros of
                Ms when length(Ms) > 0 ->
                    [{macros, Ms} | Opts0];
                _ ->
                    Opts0
            end,
    Opts = case Includes of
               Is when length(Is) > 0 ->
                   [{includes, Is} | Opts1];
               _ ->
                   Opts1
           end,
    case epp:parse_file(File, Opts) of
        {ok, Forms} ->
            %% io:format(standard_error, "Forms: ~p~n", [Forms]),
            E = ets:new(makedep, [bag]),
            lists:foreach(fun (Form) -> note_form(E, File, Form) end, Forms),
            deps(E);
        {error, Reason} ->
            io:format(standard_error,
                      "~s: error opening ~s: ~p~n",
                      [script_name(), File, Reason]),
            null
    end.

script_name() ->
    try escript:script_name() of
        Name ->
            filename:basename(Name)
    catch
        _:_ ->
            atom_to_list(?MODULE)
    end.
