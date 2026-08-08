%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_util).

-include("osiris.hrl").

-export([validate_base64uri/1,
         to_base64uri/1,
         id/1,
         lists_find/2,
         hostname_from_node/0,
         get_replication_configuration_from_tls_dist/0,
         get_replication_configuration_from_tls_dist/1,
         get_replication_configuration_from_tls_dist/2,
         partition_parallel/3,
         normalise_name/1
        ]).

%% For testing
-export([inet_tls_enabled/1,
         replication_over_tls_configuration/3]).

-define(BASE64_URI_CHARS,
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz01"
        "23456789_-=").

-spec validate_base64uri(string() | binary()) -> boolean().
validate_base64uri(Str) when ?IS_STRING(Str) ->
    catch begin
              [begin
                   case lists:member(C, ?BASE64_URI_CHARS) of
                       true ->
                           ok;
                       false ->
                           throw(false)
                   end
               end
               || C <- string:to_graphemes(Str)],
              string:is_empty(Str) == false
          end.

-spec to_base64uri(string() | binary()) -> string().
to_base64uri(Str) when ?IS_STRING(Str) ->
    lists:foldr(fun(G, Acc) ->
                   case lists:member(G, ?BASE64_URI_CHARS) of
                       true -> [G | Acc];
                       false -> [$_ | Acc]
                   end
                end,
                [], string:to_graphemes(Str)).

-spec id(term()) -> term().
id(X) ->
    X.

-spec lists_find(fun((term()) -> boolean()), list()) ->
                    {ok, term()} | not_found.
lists_find(_Pred, []) ->
    not_found;
lists_find(Pred, [Item | Rem]) ->
    case Pred(Item) of
        true ->
            {ok, Item};
        false ->
            lists_find(Pred, Rem)
    end.

hostname_from_node() ->
    case re:split(atom_to_list(node()), "@", [{return, list}, {parts, 2}])
    of
        [_, Hostname] ->
            Hostname;
        [_] ->
            {ok, H} = inet:gethostname(),
            H
    end.

get_replication_configuration_from_tls_dist() ->
    get_replication_configuration_from_tls_dist(fun (debug, Fmt, Args) ->
                                                        ?DEBUG(Fmt, Args);
                                                    (warn, Fmt, Args) ->
                                                        ?WARN(Fmt, Args);
                                                    (warning, Fmt, Args) ->
                                                        ?WARN(Fmt, Args);
                                                    (_, Fmt, Args) ->
                                                        ?INFO(Fmt, Args)
                                                end).

get_replication_configuration_from_tls_dist(LogFun) ->
    get_replication_configuration_from_tls_dist(fun file:consult/1,
                                                LogFun).

get_replication_configuration_from_tls_dist(FileConsultFun, LogFun) ->
    InitArguments = init:get_arguments(),
    case inet_tls_enabled(InitArguments) of
        true ->
            LogFun(debug,
                   "Inter-node TLS enabled, "
                   ++ "configuring stream replication over TLS",
                   []),
            replication_over_tls_configuration(InitArguments, FileConsultFun, LogFun);
        false ->
            LogFun(debug, "Inter-node TLS not enabled", []),
            []
    end.

replication_over_tls_configuration(InitArgs, FileConsultFun, LogFun) ->
    case proplists:lookup(ssl_dist_optfile, InitArgs) of
        none ->
            LogFun(debug,
                   "Using ssl_dist_opt to configure "
                   ++ "stream replication over TLS",
                   []),
            SslDistOpt = proplists:lookup_all(ssl_dist_opt, InitArgs),
            [{replication_transport, ssl},
             {replication_server_ssl_options,
              build_replication_over_tls_options("server_", SslDistOpt, [])},
             {replication_client_ssl_options,
              build_replication_over_tls_options("client_", SslDistOpt, [])}];
        {ssl_dist_optfile, [OptFile]} ->
            LogFun(debug,
                   "Using ssl_dist_optfile to configure "
                   ++ "stream replication over TLS",
                   []),
            case FileConsultFun(OptFile) of
                {ok, [TlsDist]} ->
                    SslServerOptions = proplists:get_value(server, TlsDist, []),
                    SslClientOptions = proplists:get_value(client, TlsDist, []),
                    [{replication_transport, ssl},
                     {replication_server_ssl_options, SslServerOptions},
                     {replication_client_ssl_options, SslClientOptions}];
                {error, Error} ->
                    LogFun(warn,
                           "Error while reading TLS "
                           ++ "distributon option file ~s: ~p",
                           [OptFile, Error]),
                    LogFun(warn,
                           "Stream replication over TLS will NOT be enabled",
                           []),
                    [];
                R ->
                    LogFun(warn,
                           "Unexpected result while reading TLS distributon "
                           "option file ~s: ~p",
                           [OptFile, R]),
                    LogFun(warn,
                           "Stream replication over TLS will NOT be enabled",
                           []),
                    []
            end
    end.

build_replication_over_tls_options(_Prefix, [], Acc) ->
    Acc;
build_replication_over_tls_options("server_" = Prefix,
                                   [{ssl_dist_opt, ["server_" ++ Key, Value]}
                                    | Tail],
                                   Acc) ->
    Option = list_to_atom(Key),
    build_replication_over_tls_options(Prefix, Tail,
                                       Acc
                                       ++ [extract_replication_over_tls_option(Option,
                                                                               Value)]);
build_replication_over_tls_options("client_" = Prefix,
                                   [{ssl_dist_opt, ["client_" ++ Key, Value]}
                                    | Tail],
                                   Acc) ->
    Option = list_to_atom(Key),
    build_replication_over_tls_options(Prefix, Tail,
                                       Acc
                                       ++ [extract_replication_over_tls_option(Option,
                                                                               Value)]);
build_replication_over_tls_options(Prefix,
                                   [{ssl_dist_opt, [Key1, Value1, Key2, Value2]}
                                    | Tail],
                                   Acc) ->
    %% For -ssl_dist_opt server_secure_renegotiate true client_secure_renegotiate true
    build_replication_over_tls_options(Prefix,
                                       [{ssl_dist_opt, [Key1, Value1]},
                                        {ssl_dist_opt, [Key2, Value2]}]
                                       ++ Tail,
                                       Acc);
build_replication_over_tls_options(Prefix,
                                   [{ssl_dist_opt, [_Key, _Value]} | Tail],
                                   Acc) ->
    build_replication_over_tls_options(Prefix, Tail, Acc).

extract_replication_over_tls_option(certfile, V) ->
    {certfile, V};
extract_replication_over_tls_option(keyfile, V) ->
    {keyfile, V};
extract_replication_over_tls_option(password, V) ->
    {password, V};
extract_replication_over_tls_option(cacertfile, V) ->
    {cacertfile, V};
extract_replication_over_tls_option(verify, V) ->
    {verify, list_to_atom(V)};
extract_replication_over_tls_option(verify_fun, V) ->
    %% Write as {Module, Function, InitialUserState}
    {verify_fun, eval_term(V)};
extract_replication_over_tls_option(crl_check, V) ->
    {crl_check, list_to_atom(V)};
extract_replication_over_tls_option(crl_cache, V) ->
    %% Write as Erlang term
    {crl_cache, eval_term(V)};
extract_replication_over_tls_option(reuse_sessions, V) ->
    %% boolean() | save
    {reuse_sessions, eval_term(V)};
extract_replication_over_tls_option(secure_renegotiate, V) ->
    {secure_renegotiate, list_to_atom(V)};
extract_replication_over_tls_option(depth, V) ->
    {depth, list_to_integer(V)};
extract_replication_over_tls_option(hibernate_after, "undefined") ->
    {hibernate_after, undefined};
extract_replication_over_tls_option(hibernate_after, V) ->
    {hibernate_after, list_to_integer(V)};
extract_replication_over_tls_option(ciphers, V) ->
    %% Use old string format
    %% e.g. TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256
    {ciphers, V};
extract_replication_over_tls_option(fail_if_no_peer_cert, V) ->
    {fail_if_no_peer_cert, list_to_atom(V)};
extract_replication_over_tls_option(dhfile, V) ->
    {dhfile, V}.

eval_term(V) ->
    {ok, Tokens, _EndLine} = erl_scan:string(V ++ "."),
    {ok, AbsForm} = erl_parse:parse_exprs(Tokens),
    {value, Term, _Bs} = erl_eval:exprs(AbsForm, erl_eval:new_bindings()),
    Term.

inet_tls_enabled([]) ->
    false;
inet_tls_enabled([{proto_dist, ["inet_tls"]} | _]) ->
    true;
inet_tls_enabled([_Opt | Tail]) ->
    inet_tls_enabled(Tail).

partition_parallel(F, Es, Timeout) ->
    Parent = self(),
    Running = [{spawn_monitor(fun() -> Parent ! {self(), F(E)} end), E}
               || E <- Es],
    collect(Running, {[], []}, Timeout).

collect([], Acc, _Timeout) ->
    Acc;
collect([{{Pid, MRef}, E} | Next], {Left, Right}, Timeout) ->
    receive
        {Pid, true} ->
            erlang:demonitor(MRef, [flush]),
            collect(Next, {[E | Left], Right}, Timeout);
        {Pid, false} ->
            erlang:demonitor(MRef, [flush]),
            collect(Next, {Left, [E | Right]}, Timeout);
        {'DOWN', MRef, process, Pid, _Reason} ->
            collect(Next, {Left, [E | Right]}, Timeout)
    after Timeout ->
              exit(partition_parallel_timeout)
    end.

normalise_name(Name) when is_binary(Name) ->
    Name;
normalise_name(Name) when is_list(Name) ->
    list_to_binary(Name).
