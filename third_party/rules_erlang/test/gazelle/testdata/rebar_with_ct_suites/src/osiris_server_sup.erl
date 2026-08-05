%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_server_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1,
         stop_child/2,
         delete_child/2]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Procs = [],
    {ok, {{one_for_one, 1, 5}, Procs}}.

stop_child(Node, Name) ->
    try
        %% as replicas are temporary we don't have to explicitly
        %% delete them
        case supervisor:terminate_child({?MODULE, Node}, Name) of
            ok ->
                ok;
            {error, not_found} ->
                OthName = flip_name(Name),
                case supervisor:terminate_child({?MODULE, Node}, OthName) of
                    ok ->
                        ok;
                    {error, not_found} ->
                        ok;
                    Err ->
                        Err
                end;
            Err ->
                Err
        end
    catch
        _:{noproc, _} ->
            %% Whole supervisor or app is already down - i.e. stop_app
            ok
    end.

delete_child(Node, #{name := Name} = Config) ->
    try
        case supervisor:get_childspec({?MODULE, Node}, Name) of
            {ok, _} ->
                _ = stop_child(Node, Name),
                rpc:call(Node, osiris_log, delete_directory, [Config]);
            {error, not_found} ->
                OthName = flip_name(Name),
                case supervisor:get_childspec({?MODULE, Node}, OthName) of
                    {ok, _} ->
                        _ = stop_child(Node, OthName),
                        rpc:call(Node, osiris_log, delete_directory, [Config]);
                    {error, not_found} ->
                        ok
                end
        end
    catch
        _:{noproc, _} ->
            %% Whole supervisor or app is already down - i.e. stop_app
            ok
    end.

flip_name(N) when is_binary(N) ->
    binary_to_list(N);
flip_name(N) when is_list(N) ->
    list_to_binary(N).
