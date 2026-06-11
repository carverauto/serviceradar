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
