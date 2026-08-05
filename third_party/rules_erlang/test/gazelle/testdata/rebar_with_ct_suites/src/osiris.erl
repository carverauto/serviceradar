%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris).

-include("osiris.hrl").

-export([write/4,
         write_tracking/3,
         read_tracking/1,
         read_tracking/2,
         read_tracking/3,
         fetch_writer_seq/2,
         init_reader/3,
         init_reader/4,
         register_offset_listener/2,
         register_offset_listener/3,
         update_retention/2,
         start_cluster/1,
         stop_cluster/1,
         start_writer/1,
         start_replica/2,
         delete_cluster/1,
         configure_logger/1,
         get_stats/1]).


-type name() :: string() | binary().
-type config() ::
    #{name := name(),
      reference => term(),
      event_formatter => {module(), atom(), list()},
      retention => [osiris:retention_spec()],
      atom() => term()}.

-type mfarg() :: {module(), atom(), list()}.
-type offset() :: non_neg_integer().
-type tracking_id() :: osiris_tracking:tracking_id().
-type tracking_type() :: osiris_tracking:tracking_type().
-type epoch() :: non_neg_integer().
-type milliseconds() :: non_neg_integer().
-type timestamp() :: integer(). % milliseconds since epoch
-type tail_info() :: {NextOffset :: offset(),
                      Last :: empty | {epoch(), offset(), osiris:timestamp()}}.
-type compression_type() :: 0 | % no compression
                            1 | % gzip
                            2 | % snappy
                            3 | % lz4
                            4 | % zstd
                            5 | % reserved
                            6 | % reserved
                            7.  % user defined
-type offset_spec() ::
    first |
    last |
    next |
    {abs, offset()} |
    offset() |
    {timestamp, timestamp()}.
-type retention_spec() ::
    {max_bytes, non_neg_integer()} | {max_age, milliseconds()}.
-type writer_id() :: binary().
-type data() :: iodata() | {batch,
                            NumRecords :: non_neg_integer(),
                            compression_type(),
                            UncompressedDataSize :: non_neg_integer(),
                            iodata()}.
-type reader_options() :: #{transport => tcp | ssl,
                            chunk_selector => all | user_data
                           }.

-export_type([name/0,
              config/0,
              offset/0,
              epoch/0,
              tail_info/0,
              tracking_id/0,
              offset_spec/0,
              retention_spec/0,
              timestamp/0,
              writer_id/0,
              data/0]).

-spec start_cluster(config()) ->
    {ok, config()} |
    {error, term()} |
    {error, term(), config()}.
start_cluster(Config00 = #{name := Name}) ->
    ?DEBUG("osiris: starting new cluster ~s", [Name]),
    true = osiris_util:validate_base64uri(Name),
    %% ensure reference is set
    Config0 = maps:merge(#{reference => Name}, Config00),
    case osiris_writer:start(Config0) of
        {ok, Pid} ->
            Config = Config0#{leader_pid => Pid},
            case start_replicas(Config) of
                {ok, ReplicaPids} ->
                    {ok, Config#{replica_pids => ReplicaPids}}
            end;
        Error ->
            Error
    end.

stop_cluster(Config) ->
    ok = osiris_writer:stop(Config),
    [ok = osiris_replica:stop(N, Config)
     || N <- maps:get(replica_nodes, Config)],
    ok.

-spec delete_cluster(config()) -> ok.
delete_cluster(Config) ->
    [ok = osiris_replica:delete(R, Config)
     || R <- maps:get(replica_nodes, Config)],
    ok = osiris_writer:delete(Config).

start_writer(Config) ->
    osiris_writer:start(Config).

start_replica(Replica, Config) ->
    osiris_replica:start(Replica, Config).

-spec write(Pid :: pid(),
            WriterId :: binary() | undefined,
            CorrOrSeq :: non_neg_integer() | term(),
            Data :: data()) ->
    ok.
write(Pid, WriterId, Corr, Data) ->
    osiris_writer:write(Pid, self(), WriterId, Corr, Data).

-spec write_tracking(pid(), binary(), {tracking_type(), offset() | timestamp()} | offset()) -> ok.
write_tracking(Pid, TrackingId, {_TrkType, _TrkData} = Tracking) ->
    osiris_writer:write_tracking(Pid, TrackingId, Tracking);
%% for backwards compatiblity
write_tracking(Pid, TrackingId, Offset) when is_integer(Offset) ->
    osiris_writer:write_tracking(Pid, TrackingId, {offset, Offset}).

-spec read_tracking(pid()) -> map().
read_tracking(Pid) ->
    osiris_writer:read_tracking(Pid).

%% for backwards compatiblity
-spec read_tracking(pid(), binary()) -> {offset, offset()} | undefined.
read_tracking(Pid, TrackingId) ->
    osiris_writer:read_tracking(Pid, offset, TrackingId).

-spec read_tracking(pid(), tracking_type(), binary()) ->
    {tracking_type(), offset() | timestamp()} | undefined.
read_tracking(Pid, TrackingType, TrackingId) ->
    osiris_writer:read_tracking(Pid, TrackingType, TrackingId).

-spec fetch_writer_seq(pid(), binary()) ->
                          non_neg_integer() | undefined.
fetch_writer_seq(Pid, WriterId)
    when is_pid(Pid) andalso is_binary(WriterId) ->
    osiris_writer:query_writers(Pid,
                                fun(W) ->
                                        case maps:get(WriterId, W, undefined) of
                                            undefined -> undefined;
                                            {_, Seq} -> Seq
                                        end
                                end).

%% @doc Initialise a new offset reader
%% @param Pid the pid of a writer or replica process
%% @param OffsetSpec specifies where in the log to attach the reader
%% `first': Attach at first available offset.
%% `last': Attach at the last available chunk offset or the next available offset
%% if the log is empty.
%% `next': Attach to the next chunk offset to be written.
%% `{abs, offset()}': Attach at the provided offset. If this offset does not exist
%% in the log it will error with `{error, {offset_out_of_range, Range}}'
%% `offset()': Like `{abs, offset()}' but instead of erroring it will fall back
%% to `first' (if lower than first offset in log) or `nextl if higher than
%% last offset in log.
%% @returns `{ok, state()} | {error, Error}' when error can be
%% `{offset_out_of_range, empty | {From :: offset(), To :: offset()}}'
%% @end
-spec init_reader(pid(), offset_spec(), osiris_log:counter_spec()) ->
                     {ok, osiris_log:state()} |
                     {error,
                      {offset_out_of_range, empty | {offset(), offset()}}} |
                     {error, {invalid_last_offset_epoch, offset(), offset()}}.
init_reader(Pid, OffsetSpec, CounterSpec) ->
    init_reader(Pid, OffsetSpec, CounterSpec, #{transport => tcp,
                                                chunk_selector => user_data}).

-spec init_reader(pid(), offset_spec(), osiris_log:counter_spec(), reader_options()) ->
                     {ok, osiris_log:state()} |
                     {error,
                      {offset_out_of_range, empty | {offset(), offset()}}} |
                     {error, {invalid_last_offset_epoch, offset(), offset()}}.
init_reader(Pid, OffsetSpec, {_, _} = CounterSpec, Options)
    when is_pid(Pid) andalso node(Pid) =:= node() ->
    ?DEBUG("osiris: initialising reader. Spec: ~w", [OffsetSpec]),
    {ok, Ctx0} = gen:call(Pid, '$gen_call', get_reader_context),
    Ctx = Ctx0#{counter_spec => CounterSpec,
                options => Options},
    osiris_log:init_offset_reader(OffsetSpec, Ctx).

-spec register_offset_listener(pid(), offset()) -> ok.
register_offset_listener(Pid, Offset) ->
    register_offset_listener(Pid, Offset, undefined).

%% @doc
%% Registers a one-off offset listener that will send an `{osiris_offset, offset()}'
%% message when the osiris cluster committed offset moves beyond the provided offset
%% @end
-spec register_offset_listener(pid(), offset(),
                               mfarg() | undefined) ->
                                  ok.
register_offset_listener(Pid, Offset, EvtFormatter) ->
    Msg = {'$gen_cast',
           {register_offset_listener, self(), EvtFormatter, Offset}},
    try
        erlang:send(Pid, Msg)
    catch
        error:_ ->
            ok
    end,
    ok.

-spec update_retention(pid(), [osiris:retention_spec()]) ->
    ok | {error, term()}.
update_retention(Pid, Retention)
    when is_pid(Pid) andalso is_list(Retention) ->
    Msg = {update_retention, Retention},
    try
        case gen:call(Pid, '$gen_call', Msg) of
            {ok, ok} ->
                ok
        end
    catch
        _:Reason ->
            {error, Reason}
    end.

start_replicas(Config) ->
    start_replicas(Config, maps:get(replica_nodes, Config), []).

start_replicas(_Config, [], ReplicaPids) ->
    {ok, ReplicaPids};
start_replicas(Config, [Node | Nodes], ReplicaPids) ->
    try
        case osiris_replica:start(Node, Config) of
            {ok, Pid} ->
                start_replicas(Config, Nodes, [Pid | ReplicaPids]);
            {ok, Pid, _} ->
                start_replicas(Config, Nodes, [Pid | ReplicaPids]);
            {error, {already_started, Pid}} ->
                start_replicas(Config, Nodes, [Pid | ReplicaPids]);
            {error, Reason} ->
                Name = maps:get(name, Config, undefined),
                error_logger:info_msg("osiris:start_replicas for ~s failed to start replica "
                                      "on ~w, reason: ~w",
                                      [Name, Node, Reason]),
                %% coordinator might try to start this replica in the future
                start_replicas(Config, Nodes, ReplicaPids)
        end
    catch
        _:_ ->
            %% coordinator might try to start this replica in the future
            start_replicas(Config, Nodes, ReplicaPids)
    end.

-spec configure_logger(module()) -> ok.
configure_logger(Module) ->
    persistent_term:put('$osiris_logger', Module).

-spec get_stats(pid()) -> #{committed_chunk_id => integer(),
                            first_chunk_id => integer()}.
get_stats(Pid)
  when node(Pid) =:= node() ->
    {ok, #{shared := Shared}} = gen:call(Pid, '$gen_call', get_reader_context),
    #{committed_chunk_id => osiris_log_shared:committed_chunk_id(Shared),
      first_chunk_id => osiris_log_shared:first_chunk_id(Shared),
      last_chunk_id => osiris_log_shared:last_chunk_id(Shared)};
get_stats(Pid) when is_pid(Pid) ->
    erpc:call(node(Pid), ?MODULE, ?FUNCTION_NAME, [Pid]).
