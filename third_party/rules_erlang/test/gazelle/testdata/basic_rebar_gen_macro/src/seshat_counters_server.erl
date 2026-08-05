%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%
-module(seshat_counters_server).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([create_table/1,
         delete_table/1,
         get_table/1,
         get_tables/0]).

-define(SERVER, ?MODULE).

-record(state, {
                tables = #{}
               }).

create_table(Group) ->
    gen_server:call(?MODULE, {create_table, Group}).

delete_table(Group) ->
    gen_server:call(?MODULE, {delete_table, Group}).

get_table(Group) ->
    %% TODO: check term exists and return error
    persistent_term:get({?MODULE, Group}).

get_tables() ->
    gen_server:call(?MODULE, get_tables).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call({create_table, Group}, _From, #state{tables = Tables} = State) ->
    case maps:is_key(Group, Tables) of
        true ->
            Ref = maps:get(Group, Tables),
            {reply, Ref, State};
        false ->
            Ref = ets:new(anonymous, [set, public]),
            persistent_term:put({?MODULE, Group}, Ref),
            {reply, Ref, State#state{tables = maps:put(Group, Ref, Tables)}}
    end;
handle_call({delete_table, Group}, _From, #state{tables = Tables} = State) ->
    %% TODO handle not_found
    try
        Ref = persistent_term:get({?MODULE, Group}),
        ets:delete(Ref),
        persistent_term:erase({?MODULE, Group})
    catch
        _:badarg ->
            %% Delete table must be idempotent, so if it's called twice or
            %% with a non-existing key it shouldn't fail.
            ok
    end,
    {reply, ok, State#state{tables = maps:remove(Group, Tables)}};
handle_call(get_tables, _From, State) ->
    {reply, State#state.tables, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
