-module(own_header_include_lib).

-include_lib("own_header_include_lib/include/own_header_include_lib.hrl").
-include_lib("other_lib/include/foo.hrl").

main(_) ->
    io:format("Message: ~p~n", [?WHY]).
