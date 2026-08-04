%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(seshat_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags =
        #{strategy => one_for_all,
          intensity => 5,
          period => 5},
    SeshatCountersServer = #{id => seshat_counters_server,
                             start => {seshat_counters_server, start_link, []}},
    {ok, {SupFlags, [SeshatCountersServer]}}.
