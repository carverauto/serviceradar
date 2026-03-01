%%%------------------------------------------------------------------------
%% Copyright 2026, ServiceRadar Authors
%%
%% Minimal OTLP logs exporter to satisfy :opentelemetry_experimental's
%% `otel_log_handler` when using `opentelemetry_exporter`.
%%
%% Why this exists:
%% - `opentelemetry_exporter` calls `otel_exporter_logs_otlp:export/3`
%%   but the `opentelemetry_exporter` hex package we vendor does not ship
%%   that module, causing runtime `undef` warnings and dropped log exports.
%% - `opentelemetry_experimental` *does* ship `otel_otlp_logs` which can
%%   convert logger events into the OTLP LogsService request map.
%% - `opentelemetry_exporter` already ships the gRPC client module
%%   `opentelemetry_logs_service` + protobuf module
%%   `opentelemetry_exporter_logs_service_pb`.
%%------------------------------------------------------------------------
-module(otel_exporter_logs_otlp).

-export([init/1,
         export/3,
         shutdown/1,
         merge_with_environment/1]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_LOGS_PATH, "v1/logs").
-define(DEFAULT_RPC_TIMEOUT_MS, 10000).
-define(DEFAULT_RETRY_MAX_ATTEMPTS, 5).
-define(DEFAULT_RETRY_BASE_DELAY_MS, 200).
-define(DEFAULT_RETRY_MAX_DELAY_MS, 5000).
-define(RESTART_COOLDOWN_MS, 30000).

-record(state, {channel :: term(),
                httpc_profile :: atom() | undefined,
                protocol :: otel_exporter_otlp:protocol(),
                channel_pid :: pid() | undefined,
                headers :: otel_exporter_otlp:headers(),
                compression :: otel_exporter_otlp:compression() | undefined,
                grpc_metadata :: map() | undefined,
                endpoints :: [otel_exporter_otlp:endpoint_map()]}).

%% @doc Initialize the exporter based on the provided configuration.
init(Opts) ->
    Opts1 = merge_with_environment(Opts),
    case otel_exporter_otlp:init(Opts1) of
        {ok, #{channel := Channel,
               channel_pid := ChannelPid,
               endpoints := Endpoints,
               headers := Headers,
               compression := Compression,
               grpc_metadata := Metadata,
               protocol := grpc}} ->
            {ok, #state{channel=Channel,
                        channel_pid=ChannelPid,
                        endpoints=Endpoints,
                        headers=Headers,
                        compression=Compression,
                        grpc_metadata=Metadata,
                        protocol=grpc}};
        {ok, #{httpc_profile := HttpcProfile,
               endpoints := Endpoints,
               headers := Headers,
               compression := Compression,
               protocol := http_protobuf}} ->
            {ok, #state{httpc_profile=HttpcProfile,
                        endpoints=Endpoints,
                        headers=Headers,
                        compression=Compression,
                        protocol=http_protobuf}};
        {ok, #{httpc_profile := HttpcProfile,
               endpoints := Endpoints,
               headers := Headers,
               compression := Compression,
               protocol := http_json}} ->
            {ok, #state{httpc_profile=HttpcProfile,
                        endpoints=Endpoints,
                        headers=Headers,
                        compression=Compression,
                        protocol=http_json}}
    end.

%% @doc Export OTLP log data to the configured endpoints.
%%
%% `Logs` is passed through `opentelemetry_exporter:export(logs, Logs, ...)`
%% and originates from `otel_log_handler`, which calls
%% `otel_exporter:export_logs(opentelemetry_exporter, {Batch, HandlerConfig}, ...)`.
export(_Logs, _Resource, #state{protocol=http_json}) ->
    {error, unimplemented};
export(Logs, Resource, #state{protocol=http_protobuf,
                              httpc_profile=HttpcProfile,
                              headers=Headers,
                              compression=Compression,
                              endpoints=[#{scheme := Scheme,
                                           host := Host,
                                           path := Path,
                                           port := Port,
                                           ssl_options := SSLOptions} | _]}) ->
    case uri_string:normalize(#{scheme => Scheme,
                                host => Host,
                                port => Port,
                                path => Path}) of
        {error, Type, Error} ->
            ?LOG_INFO("error normalizing OTLP logs export URI: ~p ~p",
                      [Type, Error]),
            error;
        Address ->
            {Batch, HandlerConfig} = normalize_logs_arg(Logs),
            RequestMap0 = otel_otlp_logs:to_proto(Batch, Resource, HandlerConfig),
            RequestMap = normalize_request_map(RequestMap0),
            Body = opentelemetry_exporter_logs_service_pb:encode_msg(RequestMap, export_logs_service_request),
            otel_exporter_otlp:export_http(Address, Headers, Body, Compression, SSLOptions, HttpcProfile)
    end;
export(Logs, Resource, #state{protocol=grpc,
                              grpc_metadata=Metadata,
                              channel=Channel,
                              endpoints=Endpoints,
                              compression=Compression}) ->
    {Batch, HandlerConfig} = normalize_logs_arg(Logs),
    RequestMap0 = otel_otlp_logs:to_proto(Batch, Resource, HandlerConfig),
    RequestMap = normalize_request_map(RequestMap0),
    export_grpc_with_retry(opentelemetry_logs_service, Metadata, RequestMap, Channel, Endpoints, Compression);
export(_Logs, _Resource, _State) ->
    {error, unimplemented}.

normalize_logs_arg({Batch, HandlerConfig}) when is_map(Batch), is_map(HandlerConfig) ->
    {Batch, HandlerConfig};
normalize_logs_arg({Batch, _HandlerConfig}) when is_map(Batch) ->
    %% Be tolerant if HandlerConfig isn't a map.
    {Batch, #{}};
normalize_logs_arg(Batch) when is_map(Batch) ->
    {Batch, #{}};
normalize_logs_arg(_Other) ->
    {#{}, #{}}.

%% `otel_otlp_common:to_any_value/1` encodes Erlang lists as arrays, which is
%% usually correct but breaks log bodies because formatted logger messages are
%% commonly charlists (e.g. "Hello" as [72,101,108,108,111]).
%%
%% Downstream processors (zen -> db-event-writer) expect `body` to be a string,
%% so convert charlist-like any_value arrays back into OTLP `string_value`.
normalize_request_map(#{resource_logs := ResourceLogs}=Req) when is_list(ResourceLogs) ->
    Req#{resource_logs := [normalize_resource_log(RL) || RL <- ResourceLogs]};
normalize_request_map(Req) ->
    Req.

normalize_resource_log(#{scope_logs := ScopeLogs}=RL) when is_list(ScopeLogs) ->
    RL#{scope_logs := [normalize_scope_logs(SL) || SL <- ScopeLogs]};
normalize_resource_log(RL) ->
    RL.

normalize_scope_logs(#{log_records := LogRecords}=SL) when is_list(LogRecords) ->
    SL#{log_records := [normalize_log_record(LR) || LR <- LogRecords]};
normalize_scope_logs(SL) ->
    SL.

normalize_log_record(#{body := AnyValue}=LR) when is_map(AnyValue) ->
    LR#{body := normalize_any_value(AnyValue)};
normalize_log_record(LR) ->
    LR.

normalize_any_value(#{value := {array_value, #{values := Values}}}=AnyValue) when is_list(Values) ->
    case charlist_from_any_values(Values) of
        {ok, Chars} ->
            %% Use unicode conversion so non-ASCII survives.
            Bin = unicode:characters_to_binary(Chars),
            #{value => {string_value, Bin}};
        error ->
            AnyValue
    end;
normalize_any_value(AnyValue) ->
    AnyValue.

charlist_from_any_values(Values) ->
    try
        Chars = [I || #{value := {int_value, I}} <- Values],
        case length(Chars) =:= length(Values) of
            true ->
                {ok, Chars};
            false ->
                error
        end
    catch
        _:_ ->
            error
    end.

%% @doc Shutdown the exporter.
shutdown(#state{channel=undefined}) ->
    ok;
shutdown(#state{channel=Channel}) ->
    maybe_stop_channel(Channel),
    ok.

%% Retry wrapper around grpcbox unary export.
%% We intentionally implement this here (instead of relying on upstream exporter)
%% because upstream currently surfaces transient errors (timeout/unavailable)
%% without backoff, which makes rollouts noisy and can drop data.
export_grpc_with_retry(GrpcServiceModule, Metadata, RequestMap, Channel, Endpoints, Compression) ->
    export_grpc_with_retry(GrpcServiceModule,
                           Metadata,
                           RequestMap,
                           Channel,
                           Endpoints,
                           Compression,
                           ?DEFAULT_RETRY_MAX_ATTEMPTS,
                           ?DEFAULT_RETRY_BASE_DELAY_MS,
                           ?DEFAULT_RETRY_MAX_DELAY_MS,
                           ?DEFAULT_RPC_TIMEOUT_MS).

export_grpc_with_retry(_GrpcServiceModule, _Metadata, _RequestMap, _Channel, _Endpoints, _Compression,
                       Attempts, _BaseDelay, _MaxDelay, _TimeoutMs)
  when Attempts =< 0 ->
    error;
export_grpc_with_retry(GrpcServiceModule, Metadata, RequestMap, Channel, Endpoints, Compression,
                       Attempts, BaseDelay, MaxDelay, TimeoutMs) ->
    GrpcCtx = ctx:with_deadline_after(TimeoutMs, millisecond),
    GrpcCtx1 = grpcbox_metadata:append_to_outgoing_ctx(GrpcCtx, Metadata),
    Res = GrpcServiceModule:export(GrpcCtx1, RequestMap, #{channel => Channel}),
    case Res of
        {ok, _Response, _ResponseMetadata} ->
            ok;
        {error, {Status, _Message}, _TrailerMetadata} ->
            maybe_retry_grpc({grpc_status, Status},
                             fun() ->
                                     export_grpc_with_retry(GrpcServiceModule,
                                                            Metadata,
                                                            RequestMap,
                                                            Channel,
                                                            Endpoints,
                                                            Compression,
                                                            Attempts - 1,
                                                            next_delay(BaseDelay, MaxDelay),
                                                            MaxDelay,
                                                            TimeoutMs)
                             end,
                             Attempts,
                             BaseDelay,
                             Channel,
                             Endpoints,
                             Compression);
        {http_error, {Status, _}, _} ->
            maybe_retry_grpc({http_error, Status},
                             fun() ->
                                     export_grpc_with_retry(GrpcServiceModule,
                                                            Metadata,
                                                            RequestMap,
                                                            Channel,
                                                            Endpoints,
                                                            Compression,
                                                            Attempts - 1,
                                                            next_delay(BaseDelay, MaxDelay),
                                                            MaxDelay,
                                                            TimeoutMs)
                             end,
                             Attempts,
                             BaseDelay,
                             Channel,
                             Endpoints,
                             Compression);
        {error, Reason} ->
            maybe_retry_grpc({export_error, Reason, Channel},
                             fun() ->
                                     export_grpc_with_retry(GrpcServiceModule,
                                                            Metadata,
                                                            RequestMap,
                                                            Channel,
                                                            Endpoints,
                                                            Compression,
                                                            Attempts - 1,
                                                            next_delay(BaseDelay, MaxDelay),
                                                            MaxDelay,
                                                            TimeoutMs)
                             end,
                             Attempts,
                             BaseDelay,
                             Channel,
                             Endpoints,
                             Compression);
        _ ->
            error
    end.

maybe_retry_grpc(Reason, RetryFun, Attempts, DelayMs, Channel, Endpoints, Compression) ->
    case retryable_reason(Reason) of
        true when Attempts > 1 ->
            _ = maybe_restart_channel(Reason, Channel, Endpoints, Compression),
            %% add a tiny deterministic jitter to avoid stampedes during rollouts
            Jitter = (erlang:phash2({self(), erlang:monotonic_time()}) rem 100),
            timer:sleep(DelayMs + Jitter),
            RetryFun();
        _ ->
            ?LOG_INFO("OTLP grpc export failed with error: ~p", [Reason]),
            error
    end.

retryable_reason(timeout) -> true;
retryable_reason({stream_down, _}) -> true;
retryable_reason({error, {stream_down, _}}) -> true;
retryable_reason({grpc_status, <<"UNAVAILABLE">>}) -> true;
retryable_reason({grpc_status, <<"DEADLINE_EXCEEDED">>}) -> true;
retryable_reason({grpc_status, <<"RESOURCE_EXHAUSTED">>}) -> true;
retryable_reason({http_error, _}) -> true;
retryable_reason(no_endpoints) -> true;
retryable_reason(undefined_channel) -> true;
retryable_reason({export_error, no_endpoints, _Channel}) -> true;
retryable_reason({export_error, undefined_channel, _Channel}) -> true;
retryable_reason({export_error, {error, no_endpoints}, _Channel}) -> true;
retryable_reason({export_error, {error, undefined_channel}, _Channel}) -> true;
retryable_reason(_) -> false.

next_delay(Cur, Max) when Cur >= Max -> Max;
next_delay(Cur, Max) ->
    Next = Cur * 2,
    case Next > Max of
        true -> Max;
        false -> Next
    end.

maybe_restart_channel({export_error, no_endpoints, _Channel}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({export_error, undefined_channel, _Channel}, Channel, Endpoints, Compression) ->
    ensure_channel_started(Channel, Endpoints, Compression);
maybe_restart_channel({export_error, {error, no_endpoints}, _Channel}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({export_error, {error, undefined_channel}, _Channel}, Channel, Endpoints, Compression) ->
    ensure_channel_started(Channel, Endpoints, Compression);
maybe_restart_channel({export_error, {stream_down, _}, _Channel}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({export_error, {error, {stream_down, _}}, _Channel}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel(no_endpoints, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel(undefined_channel, Channel, Endpoints, Compression) ->
    ensure_channel_started(Channel, Endpoints, Compression);
maybe_restart_channel({stream_down, _}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({error, {stream_down, _}}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({error, no_endpoints}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({error, undefined_channel}, Channel, Endpoints, Compression) ->
    ensure_channel_started(Channel, Endpoints, Compression);
maybe_restart_channel(_, _Channel, _Endpoints, _Compression) ->
    ok.

restart_channel(Channel, Endpoints, Compression) ->
    %% grpcbox doesn't automatically repopulate its subchannel pool if the
    %% underlying connections fail during startup. When that happens we get
    %% `no_endpoints` and log export silently stops. Best-effort restart.
    %% Rate-limit restarts to avoid a tight loop when the collector is down.
    Now = erlang:monotonic_time(millisecond),
    case allow_channel_restart(Channel, Now) of
        true ->
            do_restart_channel(Channel, Endpoints, Compression);
        false ->
            ok
    end.

do_restart_channel(Channel, Endpoints, Compression) ->
    EndpointTuples = grpcbox_endpoints(Endpoints),
    ChannelOpts = channel_opts(Compression),
    case EndpointTuples of
        [] ->
            ?LOG_WARNING("OTLP grpc channel restart skipped: no valid endpoints configured channel=~p",
                         [Channel]),
            ok
    ;
        _ ->
            ?LOG_INFO("OTLP grpc channel has no endpoints; restarting channel=~p endpoints=~p",
                      [Channel, length(EndpointTuples)]),
            maybe_stop_channel(Channel),
            timer:sleep(100),
            try grpcbox_channel:start_link(Channel, EndpointTuples, ChannelOpts) of
                {ok, _Pid} ->
                    ok;
                {error, {already_started, _Pid}} ->
                    ok;
                Error ->
                    ?LOG_WARNING("OTLP grpc channel restart failed: ~p", [Error]),
                    ok
            catch
                _:Reason ->
                    ?LOG_WARNING("OTLP grpc channel restart threw exception: ~p", [Reason]),
                    ok
            end
    end.

ensure_channel_started(Channel, Endpoints, Compression) ->
    Now = erlang:monotonic_time(millisecond),
    case allow_channel_ensure(Channel, Now) of
        true ->
            do_ensure_channel_started(Channel, Endpoints, Compression);
        false ->
            ok
    end.

do_ensure_channel_started(Channel, Endpoints, Compression) ->
    EndpointTuples = grpcbox_endpoints(Endpoints),
    ChannelOpts = channel_opts(Compression),
    case EndpointTuples of
        [] ->
            ?LOG_WARNING("OTLP grpc channel ensure skipped: no valid endpoints configured channel=~p",
                         [Channel]),
            ok;
        _ ->
            ?LOG_INFO("OTLP grpc channel undefined; starting channel=~p endpoints=~p",
                      [Channel, length(EndpointTuples)]),
            try grpcbox_channel:start_link(Channel, EndpointTuples, ChannelOpts) of
                {ok, _Pid} ->
                    ok;
                {error, {already_started, _Pid}} ->
                    ok;
                Error ->
                    ?LOG_WARNING("OTLP grpc channel ensure failed: ~p", [Error]),
                    ok
            catch
                _:Reason ->
                    ?LOG_WARNING("OTLP grpc channel ensure threw exception: ~p", [Reason]),
                    ok
            end
    end.

allow_channel_restart(Channel, Now) ->
    Key = {?MODULE, otlp_channel_restart_ts, Channel},
    Last = persistent_term_get(Key),
    case Last of
        undefined ->
            persistent_term:put(Key, Now),
            true;
        Ts when is_integer(Ts), (Now - Ts) >= ?RESTART_COOLDOWN_MS ->
            persistent_term:put(Key, Now),
            true;
        _ ->
            false
    end.

allow_channel_ensure(Channel, Now) ->
    Key = {?MODULE, otlp_channel_ensure_ts, Channel},
    Last = persistent_term_get(Key),
    case Last of
        undefined ->
            persistent_term:put(Key, Now),
            true;
        Ts when is_integer(Ts), (Now - Ts) >= ?RESTART_COOLDOWN_MS ->
            persistent_term:put(Key, Now),
            true;
        _ ->
            false
    end.

persistent_term_get(Key) ->
    try persistent_term:get(Key) of
        Value -> Value
    catch
        error:badarg -> undefined
    end.

channel_opts(undefined) -> #{};
channel_opts(gzip) -> #{encoding => gzip};
channel_opts(_) -> #{}.

grpcbox_endpoints(Endpoints) ->
    [{scheme(Scheme), Host, Port, maps:get(ssl_options, Endpoint, [])} ||
        #{scheme := Scheme, host := Host, port := Port} = Endpoint <- Endpoints].

scheme(<<"https">>) -> https;
scheme(<<"http">>) -> http;
scheme("https") -> https;
scheme("http") -> http;
scheme(_) -> http.

maybe_stop_channel(Channel) ->
    case gproc_ready() of
        true ->
            %% stop by channel name, not pid
            try grpcbox_channel:stop(Channel, shutdown)
            catch _:_ ->
                try grpcbox_channel:stop(Channel) catch _:_ -> ok end
            end;
        false ->
            ok
    end.

gproc_ready() ->
    try ets:info(gproc, size) of
        undefined -> false;
        _ -> true
    catch
        _:_ -> false
    end.

merge_with_environment(Opts) ->
    %% See `otel_exporter_traces_otlp:merge_with_environment/1` for rationale.
    application:load(opentelemetry_exporter),
    AppEnv = application:get_all_env(opentelemetry_exporter),
    otel_exporter_otlp:merge_with_environment(config_mapping(),
                                              AppEnv,
                                              Opts,
                                              otlp_logs_endpoint,
                                              otlp_logs_headers,
                                              otlp_logs_protocol,
                                              otlp_logs_compression,
                                              ?DEFAULT_LOGS_PATH).

config_mapping() ->
    [
     {"OTEL_EXPORTER_OTLP_ENDPOINT", otlp_endpoint, url},
     {"OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", otlp_logs_endpoint, url},

     {"OTEL_EXPORTER_OTLP_HEADERS", otlp_headers, key_value_list},
     {"OTEL_EXPORTER_OTLP_LOGS_HEADERS", otlp_logs_headers, key_value_list},

     {"OTEL_EXPORTER_OTLP_PROTOCOL", otlp_protocol, otlp_protocol},
     {"OTEL_EXPORTER_OTLP_LOGS_PROTOCOL", otlp_logs_protocol, otlp_protocol},

     {"OTEL_EXPORTER_OTLP_COMPRESSION", otlp_compression, existing_atom},
     {"OTEL_EXPORTER_OTLP_LOGS_COMPRESSION", otlp_logs_compression, existing_atom},

     {"OTEL_EXPORTER_SSL_OPTIONS", ssl_options, key_value_list}
    ].
