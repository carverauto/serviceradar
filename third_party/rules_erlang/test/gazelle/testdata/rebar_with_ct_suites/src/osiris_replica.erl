%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(osiris_replica).

-behaviour(gen_server).

-include("osiris.hrl").

-define(INFO_(Name, Str, Args),
             ?INFO("~s [~s:~s/~b] " Str,
                  [Name, ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY | Args])).

-define(WARN_(Name, Str, Args),
             ?WARN("~s [~s:~s/~b] " Str,
                  [Name, ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY | Args])).

-define(ERROR_(Name, Str, Args),
             ?ERROR("~s [~s:~s/~b] " Str,
                  [Name, ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY | Args])).

-define(DEBUG_(Name, Str, Args),
             ?DEBUG("~s [~s:~s/~b] " Str,
                  [Name, ?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY | Args])).
%% osiris replica, starts TCP listener ("server side" of the link),
%% spawns remote reader, TCP listener replicates and
%% confirms latest offset back to primary

%% API functions
-export([start/2,
         start_link/1,
         stop/2,
         delete/2]).
%% Test
-export([get_port/1, combine_ips_hosts/4]).
%% gen_server callbacks
-export([init/1,
         handle_continue/2,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         format_status/1]).

%% holds static or rarely changing fields
-record(cfg,
        {name :: osiris:name(),
         leader_pid :: pid(),
         acceptor_pid :: pid(),
         replica_reader_pid :: pid(),
         directory :: file:filename_all(),
         port :: non_neg_integer(),
         transport :: osiris_log:transport(),
         socket :: undefined | gen_tcp:socket() | ssl:sslsocket(),
         gc_interval :: infinity | non_neg_integer(),
         reference :: term(),
         event_formatter :: undefined | mfa(),
         counter :: counters:counters_ref(),
         token :: undefined | binary()}).

-type parse_state() ::
    undefined |
    binary() |
    {non_neg_integer(), iolist(), non_neg_integer()}.

-record(?MODULE,
        {cfg :: #cfg{},
         parse_state :: parse_state(),
         log :: osiris_log:state(),
         committed_offset = -1 :: -1 | osiris:offset(),
         offset_listeners = [] ::
             [{pid(), osiris:offset(), mfa() | undefined}]
        }).

-opaque state() :: #?MODULE{}.

-export_type([state/0]).

-define(C_COMMITTED_OFFSET, ?C_NUM_LOG_FIELDS + 1).
-define(C_FORCED_GCS, ?C_NUM_LOG_FIELDS + 2).
-define(C_PACKETS, ?C_NUM_LOG_FIELDS + 3).
-define(C_READERS, ?C_NUM_LOG_FIELDS + 4).
-define(C_EPOCH, ?C_NUM_LOG_FIELDS + 5).
-define(ADD_COUNTER_FIELDS,
        [{committed_offset, ?C_COMMITTED_OFFSET, counter, "Last committed offset"},
         {forced_gcs, ?C_FORCED_GCS, counter, "Number of garbage collection runs"},
         {packets, ?C_PACKETS, counter, "Number of packets"},
         {readers, ?C_READERS, counter, "Number of readers"},
         {epoch, ?C_EPOCH, counter, "Current epoch"}]).

-define(DEFAULT_ONE_TIME_TOKEN_TIMEOUT, 30000).
-define(TOKEN_SIZE, 32).
-define(DEF_REC_BUF, 408300 * 5).

%%%===================================================================
%%% API functions
%%%===================================================================

start(Node, Config = #{name := Name}) when ?IS_STRING(Name) ->
    case supervisor:start_child({?SUP, Node},
                                #{id => Name,
                                  start => {?MODULE, start_link, [Config]},
                                  restart => temporary,
                                  shutdown => 5000,
                                  type => worker,
                                  modules => [?MODULE]}) of
        {ok, Pid} = Res ->
            %% make a dummy call to block until intialisation is complete
            _ = await(Pid),
            Res;
        {ok, _, Pid} = Res ->
            _ = await(Pid),
            Res;
        Err ->
            Err
    end.

stop(Node, #{name := Name}) ->
    ?SUP:stop_child(Node, Name).

delete(Node, Config = #{}) ->
    ?SUP:delete_child(Node, Config).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Conf) ->
    gen_server:start_link(?MODULE, Conf, []).

get_port(Server) ->
    gen_server:call(Server, get_port).

await(Server) ->
    gen_server:call(Server, await, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(Config) ->
    {ok, undefined, {continue, Config}}.

handle_continue(#{name := Name0,
                  epoch := Epoch,
                  leader_pid := LeaderPid,
                  reference := ExtRef} = Config, undefined)
  when ?IS_STRING(Name0) ->
    Name = osiris_util:normalise_name(Name0),
    process_flag(trap_exit, true),
    process_flag(message_queue_data, off_heap),
    Node = node(LeaderPid),

    case rpc:call(Node, osiris_writer, overview, [LeaderPid]) of
        {error, _} = Err ->
            {stop, Err, undefined};
        {badrpc, Reason} ->
            {stop, {badrpc, Reason}, undefined};
        {ok, {LeaderRange, LeaderEpochOffs}}  ->
            {ok, {Min, Max}} = application:get_env(port_range),
            Transport = application:get_env(osiris, replication_transport, tcp),
            Self = self(),
            CntName = {?MODULE, ExtRef},

            Dir = osiris_log:directory(Config),
            Log = osiris_log:init_acceptor(LeaderRange, LeaderEpochOffs,
                                           Config#{dir => Dir,
                                                   counter_spec =>
                                                   {CntName, ?ADD_COUNTER_FIELDS}}),
            CntRef = osiris_log:counters_ref(Log),
            {NextOffset, LastChunk} = TailInfo = osiris_log:tail_info(Log),

            case LastChunk of
                empty ->
                    ok;
                {_, LastChId, LastTs} ->
                    %% need to ack last chunk back to leader so that it can
                    %% re-discover the committed offset
                    osiris_writer:ack(LeaderPid, {LastChId, LastTs})
            end,
            ?INFO_(Name, "osiris replicas starting in epoch ~b, next offset ~b, tail info ~w",
                   [Epoch, NextOffset, TailInfo]),

            %% HostName: append the HostName to the Ip(s) list: in some cases
            %% like NAT or redirect the local ip addresses are not enough.
            %% ex: In docker with host network configuration the `inet:getaddrs`
            %% are only the IP(s) inside docker but the dns lookup happens
            %% outside the docker image (host machine).
            %% The host name is the last to leave the compatibility.
            %% See: rabbitmq/rabbitmq-server#3510
            {ok, HostName} = inet:gethostname(),

            %% Ips: are the first values used to connect the
            %% replicas
            {ok, Ips} = inet:getaddrs(HostName, inet),

            %% HostNameFromHost: The hostname value from RABBITMQ_NODENAME
            %% can be different from the machine hostname.
            %% In case of docker with bridge and extra_hosts the use case can be:
            %% RABBITMQ_NODENAME=rabbit@my-domain
            %% docker hostname = "114f4317c264"
            %% the HostNameFromHost will be "my-domain".
            %% btw 99% of the time the HostNameFromHost is equal to HostName.
            %% see: rabbitmq/osiris/issues/53 for more details
            HostNameFromHost = osiris_util:hostname_from_node(),

            IpsHosts = combine_ips_hosts(Transport, Ips, HostName,
                                         HostNameFromHost),

            Token = crypto:strong_rand_bytes(?TOKEN_SIZE),
            ?DEBUG_(Name, "replica resolved host endpoints: ~w",
                    [IpsHosts]),
            ?DEBUG_(Name, "replica using '~s' transport for replication",
                    [Transport]),
            {Port, LSock} = open_listener(Transport, {Min, Max}, 0),
            Acceptor = spawn_link(fun() -> accept(Name, Transport, LSock, Self) end),

            ReplicaReaderConf = #{hosts => IpsHosts,
                                  port => Port,
                                  transport => Transport,
                                  name => Name,
                                  replica_pid => self(),
                                  leader_pid => LeaderPid,
                                  start_offset => TailInfo,
                                  reference => ExtRef,
                                  connection_token => Token},
            RRPid = osiris_replica_reader:start(Node, ReplicaReaderConf),
            true = link(RRPid),
            GcInterval0 = application:get_env(osiris,
                                             replica_forced_gc_default_interval,
                                             4999),

            GcInterval1 = case is_integer(GcInterval0) of
                              true ->
                                  _ = erlang:send_after(GcInterval0, self(), force_gc),
                                  GcInterval0;
                              false ->
                                  infinity
                          end,
            counters:put(CntRef, ?C_COMMITTED_OFFSET, -1),
            counters:put(CntRef, ?C_EPOCH, Epoch),
            EvtFmt = maps:get(event_formatter, Config, undefined),
            {noreply,
             #?MODULE{cfg =
                      #cfg{name = Name,
                           leader_pid = LeaderPid,
                           acceptor_pid = Acceptor,
                           replica_reader_pid = RRPid,
                           directory = Dir,
                           port = Port,
                           gc_interval = GcInterval1,
                           reference = ExtRef,
                           event_formatter = EvtFmt,
                           counter = CntRef,
                           token = Token,
                           transport = Transport},
                      log = Log,
                      parse_state = undefined}}
    end.

combine_ips_hosts(tcp, IPs, HostName, HostNameFromHost) when
      HostName =/= HostNameFromHost ->
    lists:append(IPs, [HostName, HostNameFromHost]);
combine_ips_hosts(tcp, IPs, HostName, _HostNameFromHost) ->
    lists:append(IPs, [HostName]);
combine_ips_hosts(ssl, IPs, HostName, HostNameFromHost) when
      HostName =/= HostNameFromHost ->
    lists:append([HostName, HostNameFromHost], IPs);
combine_ips_hosts(ssl, IPs, HostName, _HostNameFromHost) ->
    lists:append([HostName], IPs).

open_listener(_Transport, Range, 100) ->
    throw({stop, {no_available_ports_in_range, Range}});
open_listener(Transport, {Min, Max} = Range, Attempts) ->
    Offs = rand:uniform(Max - Min),
    Port = Min + Offs,
    Options = listener_opts(),
    case listen(Transport, Port, Options) of
        {ok, LSock} ->
            {Port, LSock};
        {error, eaddrinuse} ->
            open_listener(Transport, Range, Attempts + 1);
        E ->
            throw({stop, E})
    end.

accept(_Name, tcp, LSock, Process) ->
    {ok, Sock} = gen_tcp:accept(LSock),
    _ = gen_tcp:close(LSock),
    ok = gen_tcp:controlling_process(Sock, Process),
    Process ! {socket, Sock},
    ok;
accept(Name, ssl, LSock, Process) ->
    ?DEBUG_(Name, "Starting socket listener for replication over TLS", []),
    {ok, Sock0} = ssl:transport_accept(LSock),
    case ssl:handshake(Sock0,
                       application:get_env(osiris,
                                           replication_server_ssl_options,
                                           []))
    of
        {ok, Sock} ->
            _ = ssl:close(LSock),
            ok = ssl:controlling_process(Sock, Process),
            Process ! {socket, Sock},
            ok;
        {error, {tls_alert, {handshake_failure, _}}} ->
            ?DEBUG_(Name, "Handshake failure, restarting listener...",
                    []),
            _ = spawn_link(fun() -> accept(Name, ssl, LSock, Process) end),
            ok;
        {error, E} ->
            ?DEBUG_(Name, "Error during handshake ~w", [E]);
        H ->
            ?DEBUG_(Name, "Unexpected result from TLS handshake ~w", [H])
    end,
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(get_port, _From,
            #?MODULE{cfg = #cfg{port = Port}} = State) ->
    {reply, Port, State};
handle_call(get_reader_context, _From,
            #?MODULE{cfg =
                         #cfg{name = Name,
                              directory = Dir,
                              reference = Ref,
                              counter = CntRef},
                     committed_offset = COffs,
                     log = Log} =
                State) ->
    Shared = osiris_log:get_shared(Log),
    Reply =
        #{dir => Dir,
          name => Name,
          committed_offset => COffs,
          shared => Shared,
          reference => Ref,
          readers_counter_fun => fun(Inc) -> counters:add(CntRef, ?C_READERS, Inc) end},
    {reply, Reply, State};
handle_call({update_retention, Retention}, _From,
            #?MODULE{log = Log0} = State) ->
    Log = osiris_log:update_retention(Retention, Log0),
    {reply, ok, State#?MODULE{log = Log}};
handle_call(await, _From, State) ->
    {reply, ok, State};
handle_call(Unknown, _From,
            #?MODULE{cfg = #cfg{name = Name}} = State) ->
    ?INFO_(Name, "unknown command ~W", [Unknown, 10]),
    {reply, {error, unknown_command}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({committed_offset, Offs},
            #?MODULE{cfg = #cfg{counter = Cnt},
                     log = Log,
                     committed_offset = Last} =
                State) ->
    case Offs > Last of
        true ->
            %% notify offset listeners
            counters:put(Cnt, ?C_COMMITTED_OFFSET, Offs),
            ok = osiris_log:set_committed_chunk_id(Log, Offs),
            {noreply,
             notify_offset_listeners(State#?MODULE{committed_offset = Offs})};
        false ->
            State
    end;
handle_cast({register_offset_listener, Pid, EvtFormatter, Offset},
            #?MODULE{offset_listeners = Listeners} = State0) ->
    State1 =
        State0#?MODULE{offset_listeners =
                           [{Pid, Offset, EvtFormatter} | Listeners]},
    State = notify_offset_listeners(State1),
    {noreply, State};
handle_cast(Msg, #?MODULE{cfg = #cfg{name = Name}} = State) ->
    ?DEBUG_(Name, "osiris_replica unhandled cast ~w", [Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(force_gc,
            #?MODULE{cfg = #cfg{gc_interval = Interval,
                                counter = Cnt}} =
                State) ->
    garbage_collect(),
    counters:add(Cnt, ?C_FORCED_GCS, 1),
    case is_integer(Interval) of
        true ->
            _ = erlang:send_after(Interval, self(), force_gc),
            ok;
        false ->
            ok
    end,
    {noreply, State};
handle_info({socket, Socket}, #?MODULE{cfg = #cfg{name = Name,
                                                  token = Token,
                                                  transport = Transport} = Cfg} = State) ->

    Timeout = application:get_env(osiris, one_time_token_timeout,
                                  ?DEFAULT_ONE_TIME_TOKEN_TIMEOUT),
    case recv(Transport, Socket, ?TOKEN_SIZE, Timeout) of
        {ok, Token} ->
            %% token validated, all good we can let the flood of data begin
            ok = setopts(Transport, Socket, [{active, 5}]),
            {noreply, State#?MODULE{cfg = Cfg#cfg{socket = Socket}}};
        {ok, Other} ->
            ?WARN_(Name, "invalid token received ~w", [Other]),
            {stop, invalid_token, State};
        {error, Reason} ->
            ?WARN_(Name, "error awaiting token ~w", [Reason])
    end;
handle_info({tcp, Socket, Bin}, State) ->
    handle_incoming_data(Socket, Bin, State);
handle_info({ssl, Socket, Bin}, State) ->
    handle_incoming_data(Socket, Bin, State);
handle_info({tcp_passive, Socket},
            #?MODULE{cfg = #cfg{socket = Socket}} = State) ->
    %% we always top up before processing each packet so no need to do anything
    %% here
    {noreply, State};
handle_info({ssl_passive, Socket},
            #?MODULE{cfg = #cfg{socket = Socket}} = State) ->
    %% we always top up before processing each packet so no need to do anything
    %% here
    {noreply, State};
handle_info({tcp_closed, Socket},
            #?MODULE{cfg = #cfg{name = Name, socket = Socket}} = State) ->
    ?DEBUG_(Name, "Socket closed. Exiting...", []),
    {stop, normal, State};
handle_info({ssl_closed, Socket},
            #?MODULE{cfg = #cfg{name = Name, socket = Socket}} = State) ->
    ?DEBUG_(Name, "TLS socket closed. Exiting...", []),
    {stop, normal, State};
handle_info({tcp_error, Socket, Error},
            #?MODULE{cfg = #cfg{name = Name, socket = Socket}} = State) ->
    ?DEBUG_(Name, "osiris_replica: ~s Socket error ~p. Exiting...",
           [Error]),
    {stop, {tcp_error, Error}, State};
handle_info({ssl_error, Socket, Error},
            #?MODULE{cfg = #cfg{name = Name, socket = Socket}} = State) ->
    ?DEBUG_(Name, "TLS socket error ~w. Exiting...",
           [Error]),
    {stop, {ssl_error, Error}, State};
handle_info({'DOWN', _Ref, process, Pid, Info},
            #?MODULE{cfg = #cfg{name = Name}} = State) ->
    ?DEBUG_(Name, "DOWN received for Pid ~w, Info: ~w",
           [Pid, Info]),
    {noreply, State};
handle_info({'EXIT', RRPid, shutdown = Info},
            #?MODULE{cfg = #cfg{name = Name,
                                replica_reader_pid = RRPid}} = State) ->
    %% any replica reader exit is troublesome and requires the replica to also
    %% terminate
    ?INFO_(Name, "replica reader ~w exited with ~w", [RRPid, Info]),
    %% the replica reader shut down normally, so we use the normal return code
    %% to avoid logging the whole stack trace
    {stop, normal, State};
handle_info({'EXIT', RRPid, Info},
            #?MODULE{cfg = #cfg{name = Name,
                                replica_reader_pid = RRPid}} = State) ->
    %% any replica reader exit is troublesome and requires the replica to also
    %% terminate
    ?ERROR_(Name, "replica reader ~w exited with ~w", [RRPid, Info]),
    {stop, replica_reader_exit, State};
handle_info({'EXIT', Ref, normal},
            #?MODULE{cfg = #cfg{name = Name}} = State) ->
    %% we assume any 'normal' EXIT is fine to ignore (port etc)
    ?DEBUG_(Name, "EXIT received for ~w with 'normal'", [Ref]),
    {noreply, State};
handle_info({'EXIT', Ref, Info},
            #?MODULE{cfg = #cfg{name = Name}} = State) ->
    ?WARN_(Name, "unexpected linked process or port ~w exited with ~w",
           [Ref, Info]),
    {stop, unexpected_exit, State}.

handle_incoming_data(Socket, Bin,
            #?MODULE{cfg =
                         #cfg{socket = Socket,
                              leader_pid = LeaderPid,
                              transport = Transport,
                              counter = Cnt},
                     parse_state = ParseState0,
                     log = Log0} =
                State0) ->
    counters:add(Cnt, ?C_PACKETS, 1),
    %% deliberately ignoring return value here as it would fail if the
    %% tcp connection has been closed and we still want to try to process
    %% any messages still in the mailbox
    _ = setopts(Transport, Socket, [{active, 1}]),
    %% validate chunk
    {ParseState, OffsetChunks} = parse_chunk(Bin, ParseState0, []),
    {OffsetTimestamp, Log} =
        lists:foldl(fun({OffsetTs, B}, {_OffsTs, Acc0}) ->
                       Acc = osiris_log:accept_chunk(B, Acc0),
                       {OffsetTs, Acc}
                    end,
                    {undefined, Log0}, OffsetChunks),
    State1 = State0#?MODULE{log = Log, parse_state = ParseState},
    case OffsetTimestamp of
        undefined ->
            {noreply, State1};
        _ ->
            State = notify_offset_listeners(State1),
            ok = osiris_writer:ack(LeaderPid, OffsetTimestamp),
            {noreply, State}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, undefined) ->
    %% if we crash in handle_continue we may end up here
    ok;
terminate(Reason, #?MODULE{cfg = #cfg{name = Name,
                                      socket = Sock}, log = Log}) ->
    ?DEBUG_(Name, "terminating with ~w ", [Reason]),
    ok = osiris_log:close(Log),
    ok = gen_tcp:close(Sock),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

format_status(#{state := #?MODULE{cfg = #cfg{name = Name,
                                             reference = ExtRef},
                                  log = Log,
                                  parse_state = ParseState,
                                  offset_listeners = OffsetListeners,
                                  committed_offset = CommittedOffset}} = Status) ->
    maps:update(state,
                #{name => Name,
                  external_reference => ExtRef,
                  has_parse_state => ParseState /= undefined,
                  log => osiris_log:format_status(Log),
                  num_offset_listeners => length(OffsetListeners),
                  committed_offset => CommittedOffset
                 },
                Status).

%%%===================================================================
%%% Internal functions
%%%===================================================================

parse_chunk(<<>>, ParseState, Acc) ->
    {ParseState, lists:reverse(Acc)};
parse_chunk(<<?MAGIC:4/unsigned,
              ?VERSION:4/unsigned,
              _ChType:8/unsigned,
              _NumEntries:16/unsigned,
              _NumRecords:32/unsigned,
              Timestamp:64/signed,
              _Epoch:64/unsigned,
              FirstOffset:64/unsigned,
              _Crc:32/integer,
              Size:32/unsigned,
              TSize:32/unsigned,
              _Reserved:32,
              _Data:Size/binary,
              _TData:TSize/binary,
              Rem/binary>> =
                All,
            undefined, Acc) ->
    TotalSize = Size + TSize + ?HEADER_SIZE_B,
    <<Chunk:TotalSize/binary, _/binary>> = All,
    parse_chunk(Rem, undefined, [{{FirstOffset, Timestamp}, Chunk} | Acc]);
parse_chunk(Bin, undefined, Acc)
    when byte_size(Bin) =< ?HEADER_SIZE_B ->
    {Bin, lists:reverse(Acc)};
parse_chunk(<<?MAGIC:4/unsigned,
              ?VERSION:4/unsigned,
              _ChType:8/unsigned,
              _NumEntries:16/unsigned,
              _NumRecords:32/unsigned,
              Timestamp:64/signed,
              _Epoch:64/unsigned,
              FirstOffset:64/unsigned,
              _Crc:32/integer,
              Size:32/unsigned,
              TSize:32/unsigned,
              _Reserved:32,
              Partial/binary>> =
                All,
            undefined, Acc) ->
    {{{FirstOffset, Timestamp}, [All], Size + TSize - byte_size(Partial)},
     lists:reverse(Acc)};
parse_chunk(Bin, PartialHeaderBin, Acc)
    when is_binary(PartialHeaderBin) ->
    %% slight inneficiency but partial headers should be relatively
    %% rare and fairly small - also ensures the header is always intact
    parse_chunk(<<PartialHeaderBin/binary, Bin/binary>>, undefined, Acc);
parse_chunk(Bin, {FirstOffsetTs, IOData, RemSize}, Acc)
    when byte_size(Bin) >= RemSize ->
    <<Final:RemSize/binary, Rem/binary>> = Bin,
    parse_chunk(Rem, undefined,
                [{FirstOffsetTs, lists:reverse([Final | IOData])} | Acc]);
parse_chunk(Bin, {FirstOffsetTs, IOData, RemSize}, Acc) ->
    %% there is not enough data to complete the partial chunk
    {{FirstOffsetTs, [Bin | IOData], RemSize - byte_size(Bin)},
     lists:reverse(Acc)}.

notify_offset_listeners(#?MODULE{cfg =
                                     #cfg{reference = Ref,
                                          event_formatter = EvtFmt},
                                 committed_offset = COffs,
                                 log = Log,
                                 offset_listeners = L0} =
                            State) ->
    case osiris_log:tail_info(Log) of
        {_NextOffs, {_, LastChId, _LastTs}} ->
            Max = min(COffs, LastChId),
            %% do not notify offset listeners if the committed offset isn't
            %% available locally yet
            {Notify, L} =
                lists:splitwith(fun({_Pid, O, _}) -> O =< Max end, L0),
            _ = [begin
                     Evt =
                         %% the per offset listener event formatter takes precedence of
                         %% the process scoped one
                         wrap_osiris_event(
                           select_formatter(Fmt, EvtFmt),
                           {osiris_offset, Ref, COffs}),
                     P ! Evt
                 end
                 || {P, _, Fmt} <- Notify],
            State#?MODULE{offset_listeners = L};
        _ ->
            State
    end.

%% INTERNAL

wrap_osiris_event(undefined, Evt) ->
    Evt;
wrap_osiris_event({M, F, A}, Evt) ->
    apply(M, F, [Evt | A]).

select_formatter(undefined, Fmt) ->
    Fmt;
select_formatter(Fmt, _) ->
    Fmt.

recv(tcp, Socket, Length, Timeout) ->
    gen_tcp:recv(Socket, Length, Timeout);
recv(ssl, Socket, Length, Timeout) ->
    ssl:recv(Socket, Length, Timeout).

setopts(tcp, Socket, Options) ->
    inet:setopts(Socket, Options);
setopts(ssl, Socket, Options) ->
    ssl:setopts(Socket, Options).

listener_opts() ->
    RcvBuf = application:get_env(osiris, replica_recbuf, ?DEF_REC_BUF),
    Buffer = application:get_env(osiris, replica_buffer, RcvBuf * 2),
    KeepAlive = application:get_env(osiris, replica_keepalive, false),
    [binary,
     {reuseaddr, true},
     {backlog, 0},
     {packet, raw},
     {active, false},
     {buffer, Buffer},
     {recbuf, RcvBuf},
     {keepalive, KeepAlive}
    ].

listen(tcp, Port, Options) ->
    gen_tcp:listen(Port, Options);
listen(ssl, Port, Options) ->
    ssl:listen(Port, Options).
