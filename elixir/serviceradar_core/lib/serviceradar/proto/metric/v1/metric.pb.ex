defmodule Serviceradar.Metric.V1.MetricKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.metric.v1.MetricKind",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :METRIC_KIND_UNSPECIFIED, 0
  field :METRIC_KIND_GAUGE, 1
  field :METRIC_KIND_SUM, 2
  field :METRIC_KIND_HISTOGRAM, 3
end

defmodule Serviceradar.Metric.V1.MetricTemporality do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.metric.v1.MetricTemporality",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :METRIC_TEMPORALITY_UNSPECIFIED, 0
  field :METRIC_TEMPORALITY_DELTA, 1
  field :METRIC_TEMPORALITY_CUMULATIVE, 2
end

defmodule Serviceradar.Metric.V1.MetricValueType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.metric.v1.MetricValueType",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :METRIC_VALUE_TYPE_UNSPECIFIED, 0
  field :METRIC_VALUE_TYPE_DOUBLE, 1
  field :METRIC_VALUE_TYPE_INT64, 2
  field :METRIC_VALUE_TYPE_UINT64, 3
  field :METRIC_VALUE_TYPE_BOOL, 4
  field :METRIC_VALUE_TYPE_STRING, 5
end

defmodule Serviceradar.Metric.V1.StringMapEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.metric.v1.StringMapEntry",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Metric.V1.MetricResource do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.metric.v1.MetricResource",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :gateway_id, 2, type: :string, json_name: "gatewayId"
  field :partition, 3, type: :string
  field :service_name, 4, type: :string, json_name: "serviceName"
  field :service_type, 5, type: :string, json_name: "serviceType"
  field :host_id, 6, type: :string, json_name: "hostId"
  field :host_ip, 7, type: :string, json_name: "hostIp"
  field :target_device_ip, 8, type: :string, json_name: "targetDeviceIp"
  field :device_id, 9, type: :string, json_name: "deviceId"
  field :kv_store_id, 10, type: :string, json_name: "kvStoreId"
  field :attributes, 20, repeated: true, type: Serviceradar.Metric.V1.StringMapEntry
end

defmodule Serviceradar.Metric.V1.IngestIdentity do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.metric.v1.IngestIdentity",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :source, 1, type: :string
  field :payload_kind, 2, type: :string, json_name: "payloadKind"
  field :producer_id, 3, type: :string, json_name: "producerId"
  field :producer_kind, 4, type: :string, json_name: "producerKind"
  field :attested_by, 5, type: :string, json_name: "attestedBy"
  field :attributes, 20, repeated: true, type: Serviceradar.Metric.V1.StringMapEntry
end

defmodule Serviceradar.Metric.V1.MetricPoint do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.metric.v1.MetricPoint",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  alias Serviceradar.Metric.V1.StringMapEntry

  field :value, 1, type: :double
  field :raw_value, 2, type: :string, json_name: "rawValue"

  field :raw_value_type, 3,
    type: Serviceradar.Metric.V1.MetricValueType,
    json_name: "rawValueType",
    enum: true

  field :observed_at_unix_nano, 4, type: :uint64, json_name: "observedAtUnixNano"
  field :start_time_unix_nano, 5, type: :uint64, json_name: "startTimeUnixNano"
  field :reset_anchor, 6, type: :string, json_name: "resetAnchor"
  field :if_index, 7, type: :int32, json_name: "ifIndex"
  field :interface_uid, 8, type: :string, json_name: "interfaceUid"
  field :series_identity_hint, 9, type: :string, json_name: "seriesIdentityHint"
  field :attributes, 20, repeated: true, type: StringMapEntry
  field :metadata, 21, repeated: true, type: StringMapEntry
end

defmodule Serviceradar.Metric.V1.Metric do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.metric.v1.Metric",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  alias Serviceradar.Metric.V1.StringMapEntry

  field :name, 1, type: :string
  field :metric_type, 2, type: :string, json_name: "metricType"
  field :kind, 3, type: Serviceradar.Metric.V1.MetricKind, enum: true
  field :temporality, 4, type: Serviceradar.Metric.V1.MetricTemporality, enum: true
  field :is_monotonic, 5, type: :bool, json_name: "isMonotonic"
  field :unit, 6, type: :string
  field :scale, 7, type: :double
  field :counter_width, 8, type: :uint32, json_name: "counterWidth"
  field :points, 20, repeated: true, type: Serviceradar.Metric.V1.MetricPoint
  field :tags, 30, repeated: true, type: StringMapEntry
  field :metadata, 31, repeated: true, type: StringMapEntry
  field :thresholds, 32, repeated: true, type: StringMapEntry
end

defmodule Serviceradar.Metric.V1.MetricBatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.metric.v1.MetricBatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema_version, 1, type: :string, json_name: "schemaVersion"
  field :resource, 2, type: Serviceradar.Metric.V1.MetricResource

  field :ingest_identity, 3,
    type: Serviceradar.Metric.V1.IngestIdentity,
    json_name: "ingestIdentity"

  field :ingress_id, 4, type: :string, json_name: "ingressId"
  field :ingress_timestamp_unix_nano, 5, type: :uint64, json_name: "ingressTimestampUnixNano"
  field :emitted_at_unix_nano, 6, type: :uint64, json_name: "emittedAtUnixNano"
  field :metrics, 20, repeated: true, type: Serviceradar.Metric.V1.Metric
end
