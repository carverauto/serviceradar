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
            RequestMap = otel_otlp_logs:to_proto(Batch, Resource, HandlerConfig),
            Body = opentelemetry_exporter_logs_service_pb:encode_msg(RequestMap, export_logs_service_request),
            otel_exporter_otlp:export_http(Address, Headers, Body, Compression, SSLOptions, HttpcProfile)
    end;
export(Logs, Resource, #state{protocol=grpc,
                              grpc_metadata=Metadata,
                              channel=Channel}) ->
    {Batch, HandlerConfig} = normalize_logs_arg(Logs),
    RequestMap = otel_otlp_logs:to_proto(Batch, Resource, HandlerConfig),
    GrpcCtx = ctx:new(),
    otel_exporter_otlp:export_grpc(GrpcCtx, opentelemetry_logs_service, Metadata, RequestMap, Channel);
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

%% @doc Shutdown the exporter.
shutdown(#state{channel_pid=undefined}) ->
    ok;
shutdown(#state{channel_pid=Pid}) ->
    _ = grpcbox_channel:stop(Pid),
    ok.

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
