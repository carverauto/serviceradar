defmodule Serviceradar.Agent.Addon.V1.TelemetryPayloadKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.agent.addon.v1.TelemetryPayloadKind",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :TELEMETRY_PAYLOAD_KIND_UNSPECIFIED, 0
  field :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT, 1
  field :TELEMETRY_PAYLOAD_KIND_OTEL_LOG, 2
  field :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES, 3
  field :TELEMETRY_PAYLOAD_KIND_OTLP_LOGS, 4
  field :TELEMETRY_PAYLOAD_KIND_OTLP_METRICS, 5
  field :TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC, 6
  field :TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS, 7
  field :TELEMETRY_PAYLOAD_KIND_DISCOVERY_V1, 8
end

defmodule Serviceradar.Agent.Addon.V1.HealthResponse.Status do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.agent.addon.v1.HealthResponse.Status",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :STATUS_UNSPECIFIED, 0
  field :STATUS_HEALTHY, 1
  field :STATUS_DEGRADED, 2
  field :STATUS_UNHEALTHY, 3
end

defmodule Serviceradar.Agent.Addon.V1.InfoRequest do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.InfoRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Serviceradar.Agent.Addon.V1.InfoResponse do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.InfoResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :version, 2, type: :string
  field :capabilities, 3, repeated: true, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.ConfigureRequest do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.ConfigureRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :config_json, 1, type: :bytes, json_name: "configJson"
end

defmodule Serviceradar.Agent.Addon.V1.ConfigureResponse do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.ConfigureResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :config_hash, 1, type: :string, json_name: "configHash"
  field :accepted, 2, type: :bool
  field :error, 3, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.HealthRequest do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.HealthRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3
end

defmodule Serviceradar.Agent.Addon.V1.HealthResponse.DetailsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.HealthResponse.DetailsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.HealthResponse do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.HealthResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :status, 1, type: Serviceradar.Agent.Addon.V1.HealthResponse.Status, enum: true
  field :version, 2, type: :string
  field :degradation_reason, 3, type: :string, json_name: "degradationReason"

  field :details, 4,
    repeated: true,
    type: Serviceradar.Agent.Addon.V1.HealthResponse.DetailsEntry,
    map: true
end

defmodule Serviceradar.Agent.Addon.V1.StreamTelemetryRequest do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.StreamTelemetryRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :capability, 1, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.StreamArtifactsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.StreamArtifactsRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :capability, 1, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.RunCommandRequest.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.RunCommandRequest.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.RunCommandRequest do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.RunCommandRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :command_id, 1, type: :string, json_name: "commandId"
  field :command_type, 2, type: :string, json_name: "commandType"
  field :action_id, 3, type: :string, json_name: "actionId"
  field :schema, 4, type: :string
  field :payload_json, 5, type: :bytes, json_name: "payloadJson"
  field :deadline_unix, 6, type: :int64, json_name: "deadlineUnix"

  field :metadata, 7,
    repeated: true,
    type: Serviceradar.Agent.Addon.V1.RunCommandRequest.MetadataEntry,
    map: true
end

defmodule Serviceradar.Agent.Addon.V1.RunCommandResponse.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.RunCommandResponse.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.RunCommandResponse do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.RunCommandResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :message, 2, type: :string
  field :payload_json, 3, type: :bytes, json_name: "payloadJson"

  field :metadata, 4,
    repeated: true,
    type: Serviceradar.Agent.Addon.V1.RunCommandResponse.MetadataEntry,
    map: true
end

defmodule Serviceradar.Agent.Addon.V1.ArtifactMetadata.AttributesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.ArtifactMetadata.AttributesEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.ArtifactMetadata do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.ArtifactMetadata",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :object_key, 1, type: :string, json_name: "objectKey"
  field :content_type, 2, type: :string, json_name: "contentType"
  field :sha256, 3, type: :string
  field :size_bytes, 4, type: :int64, json_name: "sizeBytes"

  field :attributes, 5,
    repeated: true,
    type: Serviceradar.Agent.Addon.V1.ArtifactMetadata.AttributesEntry,
    map: true
end

defmodule Serviceradar.Agent.Addon.V1.ArtifactUploadChunk do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.ArtifactUploadChunk",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :metadata, 1, type: Serviceradar.Agent.Addon.V1.ArtifactMetadata
  field :data, 2, type: :bytes
  field :chunk_index, 3, type: :uint32, json_name: "chunkIndex"
  field :is_final, 4, type: :bool, json_name: "isFinal"
end

defmodule Serviceradar.Agent.Addon.V1.TelemetrySource.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.TelemetrySource.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.TelemetrySource do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.TelemetrySource",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :source_type, 1, type: :string, json_name: "sourceType"
  field :source_instance, 2, type: :string, json_name: "sourceInstance"

  field :metadata, 3,
    repeated: true,
    type: Serviceradar.Agent.Addon.V1.TelemetrySource.MetadataEntry,
    map: true
end

defmodule Serviceradar.Agent.Addon.V1.TelemetryCounters do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.TelemetryCounters",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :received, 1, type: :uint64
  field :filtered, 2, type: :uint64
  field :emitted, 3, type: :uint64
  field :dropped, 4, type: :uint64
  field :queue_depth, 5, type: :uint64, json_name: "queueDepth"
end

defmodule Serviceradar.Agent.Addon.V1.TelemetryRecord.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.TelemetryRecord.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Agent.Addon.V1.TelemetryRecord do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.TelemetryRecord",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :event_id, 1, type: :string, json_name: "eventId"
  field :observed_time_unix_nano, 2, type: :int64, json_name: "observedTimeUnixNano"
  field :event_time_unix_nano, 3, type: :int64, json_name: "eventTimeUnixNano"

  field :payload_kind, 4,
    type: Serviceradar.Agent.Addon.V1.TelemetryPayloadKind,
    json_name: "payloadKind",
    enum: true

  field :payload, 5, type: :bytes

  field :metadata, 6,
    repeated: true,
    type: Serviceradar.Agent.Addon.V1.TelemetryRecord.MetadataEntry,
    map: true
end

defmodule Serviceradar.Agent.Addon.V1.TelemetryBatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.TelemetryBatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :source, 1, type: Serviceradar.Agent.Addon.V1.TelemetrySource
  field :records, 2, repeated: true, type: Serviceradar.Agent.Addon.V1.TelemetryRecord
  field :counters, 3, type: Serviceradar.Agent.Addon.V1.TelemetryCounters
end

defmodule Serviceradar.Agent.Addon.V1.OtlpRelayFrame do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.OtlpRelayFrame",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :relay_id, 1, type: :uint64, json_name: "relayId"
  field :batch, 2, type: Serviceradar.Agent.Addon.V1.TelemetryBatch
end

defmodule Serviceradar.Agent.Addon.V1.OtlpRelayAck do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.OtlpRelayAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :acked_relay_id, 1, type: :uint64, json_name: "ackedRelayId"
end

defmodule Serviceradar.Agent.Addon.V1.MetricFeedFrame do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.MetricFeedFrame",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :feed_id, 1, type: :uint64, json_name: "feedId"
  field :source, 2, type: Serviceradar.Agent.Addon.V1.TelemetrySource
  field :payload, 3, type: :bytes
end

defmodule Serviceradar.Agent.Addon.V1.MetricFeedAck do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.addon.v1.MetricFeedAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :acked_feed_id, 1, type: :uint64, json_name: "ackedFeedId"
end

defmodule Serviceradar.Agent.Addon.V1.AddonService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "serviceradar.agent.addon.v1.AddonService",
    protoc_gen_elixir_version: "0.16.0"

  rpc(:Info, Serviceradar.Agent.Addon.V1.InfoRequest, Serviceradar.Agent.Addon.V1.InfoResponse)

  rpc(
    :Configure,
    Serviceradar.Agent.Addon.V1.ConfigureRequest,
    Serviceradar.Agent.Addon.V1.ConfigureResponse
  )

  rpc(
    :Health,
    Serviceradar.Agent.Addon.V1.HealthRequest,
    Serviceradar.Agent.Addon.V1.HealthResponse
  )

  rpc(
    :StreamTelemetry,
    Serviceradar.Agent.Addon.V1.StreamTelemetryRequest,
    stream(Serviceradar.Agent.Addon.V1.TelemetryBatch)
  )

  rpc(
    :StreamArtifacts,
    Serviceradar.Agent.Addon.V1.StreamArtifactsRequest,
    stream(Serviceradar.Agent.Addon.V1.ArtifactUploadChunk)
  )

  rpc(
    :RelayOtlp,
    stream(Serviceradar.Agent.Addon.V1.OtlpRelayAck),
    stream(Serviceradar.Agent.Addon.V1.OtlpRelayFrame)
  )

  rpc(
    :StreamMetricFeed,
    stream(Serviceradar.Agent.Addon.V1.MetricFeedFrame),
    stream(Serviceradar.Agent.Addon.V1.MetricFeedAck)
  )

  rpc(
    :RunCommand,
    Serviceradar.Agent.Addon.V1.RunCommandRequest,
    Serviceradar.Agent.Addon.V1.RunCommandResponse
  )
end

defmodule Serviceradar.Agent.Addon.V1.AddonService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Serviceradar.Agent.Addon.V1.AddonService.Service
end
