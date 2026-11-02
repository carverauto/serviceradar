defmodule Serviceradar.Edge.V1.PluginResultStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.PluginResultStatus",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  # SERVICERADAR EDGE ENUM PARITY (task 1.5) -- injected by scripts/patch_edge_enum_negatives.exs.
  # Go RETAINS an unknown/negative int32 enum as its integer and rejects it in the explicit
  # semantic validator; the generated `key/1`/`value/1` catchalls are guarded `tag >= 0` and
  # would RAISE, making Elixir reject a message Go accepts (last-one-wins: `-1` followed by a
  # valid value has the VALID effective value). Declared in the module BODY on purpose: the
  # Protobuf DSL appends its clauses at `@before_compile`, so these win for negatives while
  # every other tag falls through to the generated clauses unchanged.
  def key(tag) when is_integer(tag) and tag < 0, do: tag
  def value(tag) when is_integer(tag) and tag < 0, do: tag

  field :PLUGIN_RESULT_STATUS_UNSPECIFIED, 0
  field :PLUGIN_RESULT_STATUS_OK, 1
  field :PLUGIN_RESULT_STATUS_WARNING, 2
  field :PLUGIN_RESULT_STATUS_CRITICAL, 3
  field :PLUGIN_RESULT_STATUS_UNKNOWN, 4
end

defmodule Serviceradar.Edge.V1.PluginResultProvenanceV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginResultProvenanceV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :assignment_id, 1, type: :string, json_name: "assignmentId"
  field :plugin_id, 2, type: :string, json_name: "pluginId"
  field :plugin_package_id, 3, type: :string, json_name: "pluginPackageId"
  field :plugin_version, 4, type: :string, json_name: "pluginVersion"
  field :content_hash, 5, type: :string, json_name: "contentHash"
end

defmodule Serviceradar.Edge.V1.PluginDisplayInstructionV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginDisplayInstructionV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :widget, 1, type: :string
  field :label, 2, type: :string
  field :value, 3, type: :string
  field :tone, 4, type: :string
  field :layout, 5, type: :string
  field :data_json, 6, type: :bytes, json_name: "dataJson"
end

defmodule Serviceradar.Edge.V1.PluginEventEnvelopeV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginEventEnvelopeV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :time_unix_nano, 2, type: :int64, json_name: "timeUnixNano"
  field :class_uid, 3, type: :uint32, json_name: "classUid"
  field :category_uid, 4, type: :uint32, json_name: "categoryUid"
  field :type_uid, 5, type: :uint32, json_name: "typeUid"
  field :activity_id, 6, type: :uint32, json_name: "activityId"
  field :activity_name, 7, type: :string, json_name: "activityName"
  field :severity_id, 8, type: :uint32, json_name: "severityId"
  field :severity, 9, type: :string
  field :message, 10, type: :string
  field :payload_json, 11, type: :bytes, json_name: "payloadJson"
end

defmodule Serviceradar.Edge.V1.PluginDeviceLocationV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginDeviceLocationV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :site_code, 1, type: :string, json_name: "siteCode"
  field :site_name, 2, type: :string, json_name: "siteName"
  field :latitude, 3, type: :double
  field :longitude, 4, type: :double
  field :has_latitude, 5, type: :bool, json_name: "hasLatitude"
  field :has_longitude, 6, type: :bool, json_name: "hasLongitude"
end

defmodule Serviceradar.Edge.V1.PluginDiscoveredDeviceV1.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginDiscoveredDeviceV1.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.PluginDiscoveredDeviceV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginDiscoveredDeviceV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :device_id, 1, type: :string, json_name: "deviceId"
  field :hostname, 2, type: :string
  field :ip, 3, type: :string
  field :mac, 4, type: :string
  field :serial, 5, type: :string
  field :vendor_name, 6, type: :string, json_name: "vendorName"
  field :model, 7, type: :string
  field :type, 8, type: :string
  field :role, 9, type: :string
  field :status, 10, type: :string
  field :has_is_available, 11, type: :bool, json_name: "hasIsAvailable"
  field :is_available, 12, type: :bool, json_name: "isAvailable"
  field :location, 13, type: Serviceradar.Edge.V1.PluginDeviceLocationV1

  field :labels, 14,
    repeated: true,
    type: Serviceradar.Edge.V1.PluginDiscoveredDeviceV1.LabelsEntry,
    map: true

  field :metadata_json, 15, type: :bytes, json_name: "metadataJson"
end

defmodule Serviceradar.Edge.V1.PluginDeviceDiscoveryItemV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginDeviceDiscoveryItemV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :collection_id, 2, type: :string, json_name: "collectionId"
  field :source, 3, type: :string
  field :observed_at, 4, type: :string, json_name: "observedAt"
  field :reference_hash, 5, type: :string, json_name: "referenceHash"
  field :devices, 6, repeated: true, type: Serviceradar.Edge.V1.PluginDiscoveredDeviceV1
  field :metadata_json, 7, type: :bytes, json_name: "metadataJson"
end

defmodule Serviceradar.Edge.V1.PluginAdvisoryFeedBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginAdvisoryFeedBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema_version, 1, type: :string, json_name: "schemaVersion"
  field :producer_id, 2, type: :string, json_name: "producerId"
  field :source_json, 3, type: :bytes, json_name: "sourceJson"
  field :snapshot_json, 4, type: :bytes, json_name: "snapshotJson"
  field :advisories_json, 5, repeated: true, type: :bytes, json_name: "advisoriesJson"
  field :metadata_json, 6, type: :bytes, json_name: "metadataJson"
end

defmodule Serviceradar.Edge.V1.PluginStagedArtifactV1.AttributesEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginStagedArtifactV1.AttributesEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.PluginStagedArtifactV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginStagedArtifactV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :object_key, 1, type: :string, json_name: "objectKey"
  field :content_type, 2, type: :string, json_name: "contentType"
  field :sha256, 3, type: :string
  field :size_bytes, 4, type: :int64, json_name: "sizeBytes"

  field :attributes, 5,
    repeated: true,
    type: Serviceradar.Edge.V1.PluginStagedArtifactV1.AttributesEntry,
    map: true
end

defmodule Serviceradar.Edge.V1.PluginActionResultV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginActionResultV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :status, 2, type: :string
  field :summary_json, 3, type: :bytes, json_name: "summaryJson"
  field :external_correlation_id, 4, type: :string, json_name: "externalCorrelationId"
  field :continuation_state_json, 5, type: :bytes, json_name: "continuationStateJson"
  field :poll_mode, 6, type: :string, json_name: "pollMode"
  field :next_poll_at, 7, type: :string, json_name: "nextPollAt"
  field :next_poll_delay_seconds, 8, type: :uint32, json_name: "nextPollDelaySeconds"
  field :poll_deadline_at, 9, type: :string, json_name: "pollDeadlineAt"
  field :max_duration_seconds, 10, type: :uint32, json_name: "maxDurationSeconds"
  field :targets_json, 11, type: :bytes, json_name: "targetsJson"
  field :error_class, 12, type: :string, json_name: "errorClass"
  field :error_message, 13, type: :string, json_name: "errorMessage"
  field :metadata_json, 14, type: :bytes, json_name: "metadataJson"
  field :run_overrides_json, 15, type: :bytes, json_name: "runOverridesJson"
end

defmodule Serviceradar.Edge.V1.PluginContractPayloadV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.PluginContractPayloadV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :schema_version, 2, type: :uint32, json_name: "schemaVersion"
  field :payload_json, 3, type: :bytes, json_name: "payloadJson"
end

defmodule Serviceradar.Edge.V1.WasmPluginResultItemV1.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.WasmPluginResultItemV1.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.WasmPluginResultItemV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.WasmPluginResultItemV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  alias Serviceradar.Edge.V1.PluginContractPayloadV1

  field :schema_version, 1, type: :uint32, json_name: "schemaVersion"
  field :status, 2, type: Serviceradar.Edge.V1.PluginResultStatus, enum: true
  field :summary, 3, type: :string
  field :details, 4, type: :string
  field :perfdata, 5, type: :string

  field :labels, 6,
    repeated: true,
    type: Serviceradar.Edge.V1.WasmPluginResultItemV1.LabelsEntry,
    map: true

  field :observed_at_unix_nano, 7, type: :int64, json_name: "observedAtUnixNano"
  field :alert_hint, 8, type: :bool, json_name: "alertHint"
  field :condition_id, 9, type: :string, json_name: "conditionId"
  field :check_instance_id, 10, type: :string, json_name: "checkInstanceId"
  field :monitored_service_id, 11, type: :string, json_name: "monitoredServiceId"
  field :device_uid, 12, type: :string, json_name: "deviceUid"
  field :service_name, 13, type: :string, json_name: "serviceName"
  field :service_type, 14, type: :string, json_name: "serviceType"

  field :run_overrides_acknowledged, 15,
    repeated: true,
    type: :string,
    json_name: "runOverridesAcknowledged"

  field :display, 16, repeated: true, type: Serviceradar.Edge.V1.PluginDisplayInstructionV1
  field :events, 17, repeated: true, type: Serviceradar.Edge.V1.PluginEventEnvelopeV1

  field :device_discovery, 18,
    repeated: true,
    type: Serviceradar.Edge.V1.PluginDeviceDiscoveryItemV1,
    json_name: "deviceDiscovery"

  field :advisory_feeds, 19,
    repeated: true,
    type: Serviceradar.Edge.V1.PluginAdvisoryFeedBatchV1,
    json_name: "advisoryFeeds"

  field :staged_artifact, 20,
    type: Serviceradar.Edge.V1.PluginStagedArtifactV1,
    json_name: "stagedArtifact"

  field :interface_config_checks, 21,
    type: PluginContractPayloadV1,
    json_name: "interfaceConfigChecks"

  field :hypervisor_enrichment, 22,
    type: PluginContractPayloadV1,
    json_name: "hypervisorEnrichment"

  field :proxmox_enrichment, 23,
    type: PluginContractPayloadV1,
    json_name: "proxmoxEnrichment"

  field :wifi_map_batch, 24,
    type: PluginContractPayloadV1,
    json_name: "wifiMapBatch"

  field :threat_intel_page, 25,
    type: PluginContractPayloadV1,
    json_name: "threatIntelPage"

  field :camera_descriptors, 26,
    repeated: true,
    type: PluginContractPayloadV1,
    json_name: "cameraDescriptors"

  field :action_result, 27,
    type: Serviceradar.Edge.V1.PluginActionResultV1,
    json_name: "actionResult"

  field :contract_payloads, 28,
    repeated: true,
    type: PluginContractPayloadV1,
    json_name: "contractPayloads"
end

defmodule Serviceradar.Edge.V1.WasmPluginResultBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.WasmPluginResultBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :provenance, 1, type: Serviceradar.Edge.V1.PluginResultProvenanceV1
  field :results, 2, repeated: true, type: Serviceradar.Edge.V1.WasmPluginResultItemV1
end
