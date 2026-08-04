-module(app_file_tool).

-mode(compile).

-export([main/1]).

-spec main([string()]) -> no_return().
main([KeyString, AppSrc]) ->
    Key = list_to_atom(KeyString),
    {ok, Value} = io:read(""),
    {ok, [AppInfo]} = file:consult(AppSrc),
    {application, AppName, Props} = AppInfo,
    NewProps = lists:keystore(Key, 1, Props, {Key, Value}),
    io:format("~tp.~n", [{application, AppName, NewProps}]),
    halt();
main([AppSrc]) ->
    {ok, Entries} = io:read(""),
    {ok, [AppInfo]} = file:consult(AppSrc),
    {application, AppName, Props} = AppInfo,
    NewProps = Props ++ Entries,
    io:format("~tp.~n", [{application, AppName, NewProps}]),
    halt();
main(_) ->
    halt(1).
