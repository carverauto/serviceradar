-module(basic).

-compile({parse_transform, my_pt}).

-include("basic.hrl").
-include("my_header.hrl").

-export([main/1]).

-ifdef(TEST).
-include_lib("some_lib/include/some_header.hrl").
-endif.

other_func(X, N) ->
    other_lib:calc(X) rem N.

myfunc(M) when is_map(M) ->
    try maps:merge(M, #{k2 => other_lib:encode(<<"string">>)})
    catch _:_ ->
        invalid
    after
        other_lib:finalize()
    end,
    io:format("Hello~n", []),
    {ok, some_other_lib:fizz()}.

on_a_record_func(#'v1_0.source'{name = foo} = R) ->
    ?SOME_CONST;
on_a_record_func(#'v1_0.source'{name = Name} = R) ->
    case Name of
        _ -> case other_lib:bar(R) of
            _ -> ok
        end
    end.

main(_) ->
    myfunc(#{k => v}),
    other_func(10, 3),
    on_a_record_func(#'v1_0.source'{}),
    filename:split(some_other_lib:baz()),
    _ = some_other_lib:bar(2),
    other_lib:foo(1).
