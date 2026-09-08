-module(serviceradar_otel_grpcbox_channel).

-export([start/3]).

start(Channel, EndpointTuples, Compression) ->
    grpcbox_channel_sup:start_child(Channel, EndpointTuples, channel_opts(Compression)).

channel_opts(gzip) -> #{encoding => gzip, sync_start => true};
channel_opts(_) -> #{sync_start => true}.
