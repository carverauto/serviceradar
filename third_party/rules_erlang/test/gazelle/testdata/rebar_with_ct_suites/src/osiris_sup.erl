%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    osiris_counters:init(),
    SupFlags =
        #{strategy => one_for_all,
          intensity => 5,
          period => 5},
    %% todo put under own sup
    Retention =
        #{id => osiris_retention,
          type => worker,
          start => {osiris_retention, start_link, []}},
    ServerSup =
        #{id => osiris_server_sup,
          type => supervisor,
          start => {osiris_server_sup, start_link, []}},
    ReplicaReader =
        #{id => osiris_replica_reader_sup,
          type => supervisor,
          start => {osiris_replica_reader_sup, start_link, []}},
    {ok, {SupFlags, [Retention, ServerSup, ReplicaReader]}}.
