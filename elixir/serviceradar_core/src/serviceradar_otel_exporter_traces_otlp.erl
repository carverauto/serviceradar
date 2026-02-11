%%%------------------------------------------------------------------------
%% Copyright 2026, ServiceRadar Authors
%%
%% OTLP traces exporter with retries/backoff.
%%
%% Why:
%% - upstream OTLP exporter logs transient gRPC errors (timeout/unavailable)
%%   but does not apply exponential backoff retries.
%% - during rollouts or collector restarts we want to reduce dropped spans
%%   and avoid log spam.
%%%------------------------------------------------------------------------
-module(serviceradar_otel_exporter_traces_otlp).

-behaviour(otel_exporter_traces).

-export([init/1,
         export/3,
         shutdown/1]).

-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_RPC_TIMEOUT_MS, 10000).
-define(DEFAULT_RETRY_MAX_ATTEMPTS, 5).
-define(DEFAULT_RETRY_BASE_DELAY_MS, 200).
-define(DEFAULT_RETRY_MAX_DELAY_MS, 5000).

init(Opts) ->
    %% Reuse upstream env/app-env merge logic for endpoint/headers/protocol.
    Opts1 = otel_exporter_traces_otlp:merge_with_environment(Opts),
    {ok, OtlpState} = otel_exporter_otlp:init(Opts1),
    TimeoutMs = maps:get(rpc_timeout_ms, Opts, ?DEFAULT_RPC_TIMEOUT_MS),
    MaxAttempts = maps:get(retry_max_attempts, Opts, ?DEFAULT_RETRY_MAX_ATTEMPTS),
    BaseDelay = maps:get(retry_base_delay_ms, Opts, ?DEFAULT_RETRY_BASE_DELAY_MS),
    MaxDelay = maps:get(retry_max_delay_ms, Opts, ?DEFAULT_RETRY_MAX_DELAY_MS),
    {ok, #{otlp => OtlpState,
           timeout_ms => TimeoutMs,
           max_attempts => MaxAttempts,
           base_delay_ms => BaseDelay,
           max_delay_ms => MaxDelay}}.

export(SpansTid, Resource, State=#{otlp := #{protocol := grpc,
                                            channel := Channel,
                                            grpc_metadata := Metadata,
                                            endpoints := Endpoints,
                                            compression := Compression}}) ->
    case otel_otlp_traces:to_proto(SpansTid, Resource) of
        empty ->
            ok;
        RequestMap ->
            export_grpc_with_retry(opentelemetry_trace_service,
                                   Metadata,
                                   RequestMap,
                                   Channel,
                                   Endpoints,
                                   Compression,
                                   State)
    end;
export(_SpansTid, _Resource, _State=#{otlp := #{protocol := http_protobuf}}) ->
    %% We only deploy gRPC OTLP in ServiceRadar.
    {error, unimplemented};
export(_SpansTid, _Resource, _State) ->
    {error, unimplemented}.

shutdown(#{otlp := #{channel := undefined}}) ->
    ok;
shutdown(#{otlp := #{channel := Channel}}) ->
    %% stop by channel name, not pid
    try grpcbox_channel:stop(Channel, {shutdown, force_delete}) catch _:_ -> ok end,
    ok;
shutdown(_) ->
    ok.

export_grpc_with_retry(GrpcServiceModule, Metadata, RequestMap, Channel, Endpoints, Compression,
                       #{timeout_ms := TimeoutMs,
                         max_attempts := Attempts,
                         base_delay_ms := BaseDelay,
                         max_delay_ms := MaxDelay}) ->
    export_grpc_with_retry(GrpcServiceModule,
                           Metadata,
                           RequestMap,
                           Channel,
                           Endpoints,
                           Compression,
                           Attempts,
                           BaseDelay,
                           MaxDelay,
                           TimeoutMs).

export_grpc_with_retry(_GrpcServiceModule, _Metadata, _RequestMap, _Channel, _Endpoints, _Compression,
                       Attempts, _BaseDelay, _MaxDelay, _TimeoutMs)
  when Attempts =< 0 ->
    failed_retryable;
export_grpc_with_retry(GrpcServiceModule, Metadata, RequestMap, Channel, Endpoints, Compression,
                       Attempts, BaseDelay, MaxDelay, TimeoutMs) ->
    GrpcCtx = ctx:with_deadline_after(TimeoutMs, millisecond),
    GrpcCtx1 = grpcbox_metadata:append_to_outgoing_ctx(GrpcCtx, Metadata),
    Res = GrpcServiceModule:export(GrpcCtx1, RequestMap, #{channel => Channel}),
    case Res of
        {ok, _Response, _ResponseMetadata} ->
            ok;
        {error, {Status, _Message}, _TrailerMetadata} ->
            maybe_retry({grpc_status, Status}, GrpcServiceModule, Metadata, RequestMap, Channel, Endpoints, Compression, Attempts, BaseDelay, MaxDelay, TimeoutMs);
        {http_error, {Status, _}, _} ->
            maybe_retry({http_error, Status}, GrpcServiceModule, Metadata, RequestMap, Channel, Endpoints, Compression, Attempts, BaseDelay, MaxDelay, TimeoutMs);
        {error, Reason} ->
            maybe_retry(Reason, GrpcServiceModule, Metadata, RequestMap, Channel, Endpoints, Compression, Attempts, BaseDelay, MaxDelay, TimeoutMs);
        _ ->
            failed_retryable
    end.

maybe_retry(Reason, GrpcServiceModule, Metadata, RequestMap, Channel, Endpoints, Compression,
            Attempts, BaseDelay, MaxDelay, TimeoutMs) ->
    case retryable_reason(Reason) of
        true when Attempts > 1 ->
            _ = maybe_restart_channel(Reason, Channel, Endpoints, Compression),
            Jitter = (erlang:phash2({self(), erlang:monotonic_time()}) rem 100),
            timer:sleep(BaseDelay + Jitter),
            export_grpc_with_retry(GrpcServiceModule,
                                   Metadata,
                                   RequestMap,
                                   Channel,
                                   Endpoints,
                                   Compression,
                                   Attempts - 1,
                                   next_delay(BaseDelay, MaxDelay),
                                   MaxDelay,
                                   TimeoutMs);
        _ ->
            ?LOG_INFO("OTLP grpc export failed with error: ~p", [Reason]),
            failed_retryable
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
retryable_reason({error, no_endpoints}) -> true;
retryable_reason({error, undefined_channel}) -> true;
retryable_reason(_) -> false.

next_delay(Cur, Max) when Cur >= Max -> Max;
next_delay(Cur, Max) ->
    Next = Cur * 2,
    case Next > Max of
        true -> Max;
        false -> Next
    end.

maybe_restart_channel(no_endpoints, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel(undefined_channel, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({stream_down, _}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({error, {stream_down, _}}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({error, no_endpoints}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel({error, undefined_channel}, Channel, Endpoints, Compression) ->
    restart_channel(Channel, Endpoints, Compression);
maybe_restart_channel(_, _Channel, _Endpoints, _Compression) ->
    ok.

restart_channel(Channel, Endpoints, Compression) ->
    EndpointTuples = grpcbox_endpoints(Endpoints),
    ChannelOpts = channel_opts(Compression),
    ?LOG_INFO("OTLP grpc channel has no endpoints; restarting channel=~p endpoints=~p",
              [Channel, length(EndpointTuples)]),
    try grpcbox_channel:stop(Channel, shutdown) catch _:_ -> ok end,
    timer:sleep(100),
    case grpcbox_channel:start_link(Channel, EndpointTuples, ChannelOpts) of
        {ok, _Pid} ->
            ok;
        {error, {already_started, _Pid}} ->
            ok;
        Error ->
            ?LOG_WARNING("OTLP grpc channel restart failed: ~p", [Error]),
            ok
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
