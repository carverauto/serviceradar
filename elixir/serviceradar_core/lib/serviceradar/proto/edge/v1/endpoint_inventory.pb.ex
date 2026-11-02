defmodule Serviceradar.Edge.V1.EndpointInventoryScanPayloadV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryScanPayloadV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema_version, 1, type: :string, json_name: "schemaVersion"
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :scan_id, 3, type: :string, json_name: "scanId"
  field :collector_version, 4, type: :string, json_name: "collectorVersion"
  field :state, 5, type: :string
  field :coverage_state, 6, type: :string, json_name: "coverageState"
  field :config_hash, 7, type: :string, json_name: "configHash"
  field :last_scan_at, 8, type: :string, json_name: "lastScanAt"
  field :last_successful_scan_at, 9, type: :string, json_name: "lastSuccessfulScanAt"
  field :os, 10, type: Serviceradar.Edge.V1.EndpointInventoryOSInfoV1
  field :enabled_plugins, 11, repeated: true, type: :string, json_name: "enabledPlugins"
  field :detected_plugins, 12, repeated: true, type: :string, json_name: "detectedPlugins"

  field :diagnostics, 13,
    repeated: true,
    type: Serviceradar.Edge.V1.EndpointInventorySourceSummaryV1

  field :package_count, 14, type: :int32, json_name: "packageCount"
  field :package_set_hash, 15, type: :string, json_name: "packageSetHash"
  field :artifact_hash, 16, type: :string, json_name: "artifactHash"
  field :hash_algorithm, 17, type: :string, json_name: "hashAlgorithm"
  field :upload_reason, 18, type: :string, json_name: "uploadReason"
  field :duration_ms, 19, type: :int64, json_name: "durationMs"
  field :truncated, 20, type: :bool

  field :standing_question_result_counts, 21,
    repeated: true,
    type: Serviceradar.Edge.V1.EndpointInventoryStandingQuestionResultCountV1,
    json_name: "standingQuestionResultCounts"

  field :sbom, 22, type: Serviceradar.Edge.V1.EndpointInventoryCycloneDXBOMV1

  field :package_delta, 23,
    type: Serviceradar.Edge.V1.EndpointInventoryPackageSetDeltaV1,
    json_name: "packageDelta"

  field :metadata_json, 24, type: :bytes, json_name: "metadataJson"
end

defmodule Serviceradar.Edge.V1.EndpointInventoryOSInfoV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryOSInfoV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :id, 2, type: :string
  field :version, 3, type: :string
  field :version_id, 4, type: :string, json_name: "versionId"
  field :pretty_name, 5, type: :string, json_name: "prettyName"
end

defmodule Serviceradar.Edge.V1.EndpointInventorySourceSummaryV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventorySourceSummaryV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :type, 2, type: :string
  field :state, 3, type: :string
  field :package_count, 4, type: :int32, json_name: "packageCount"
  field :finding_count, 5, type: :int32, json_name: "findingCount"
  field :reason, 6, type: :string
  field :error, 7, type: :string
  field :path, 8, type: :string
  field :detected, 9, type: :bool
  field :has_detected, 10, type: :bool, json_name: "hasDetected"
  field :duration_ms, 11, type: :int64, json_name: "durationMs"
  field :truncated, 12, type: :bool
end

defmodule Serviceradar.Edge.V1.EndpointInventoryPackageV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryPackageV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :version, 2, type: :string
  field :architecture, 3, type: :string
  field :manager, 4, type: :string
  field :ecosystem, 5, type: :string
  field :purl, 6, type: :string
  field :cpes, 7, repeated: true, type: :string
end

defmodule Serviceradar.Edge.V1.EndpointInventoryPackageChangeV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryPackageChangeV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :version, 2, type: :string
  field :architecture, 3, type: :string
  field :manager, 4, type: :string
  field :ecosystem, 5, type: :string
  field :purl, 6, type: :string
  field :cpes, 7, repeated: true, type: :string
  field :previous_version, 8, type: :string, json_name: "previousVersion"
end

defmodule Serviceradar.Edge.V1.EndpointInventoryPackageSetDeltaV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryPackageSetDeltaV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  alias Serviceradar.Edge.V1.EndpointInventoryPackageV1

  field :schema, 1, type: :string
  field :base_package_set_hash, 2, type: :string, json_name: "basePackageSetHash"
  field :target_package_set_hash, 3, type: :string, json_name: "targetPackageSetHash"
  field :hash_algorithm, 4, type: :string, json_name: "hashAlgorithm"
  field :added, 5, repeated: true, type: EndpointInventoryPackageV1
  field :removed, 6, repeated: true, type: EndpointInventoryPackageV1
  field :changed, 7, repeated: true, type: Serviceradar.Edge.V1.EndpointInventoryPackageChangeV1
end

defmodule Serviceradar.Edge.V1.EndpointInventoryStandingQuestionResultCountV1.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryStandingQuestionResultCountV1.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.EndpointInventoryStandingQuestionResultCountV1.MetadataEntry do
  @moduledoc false

  use Protobuf,
    full_name:
      "serviceradar.edge.v1.EndpointInventoryStandingQuestionResultCountV1.MetadataEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Edge.V1.EndpointInventoryStandingQuestionResultCountV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryStandingQuestionResultCountV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema, 1, type: :string
  field :question_id, 2, type: :string, json_name: "questionId"
  field :question_version, 3, type: :string, json_name: "questionVersion"
  field :predicate_hash, 4, type: :string, json_name: "predicateHash"
  field :mode, 5, type: :string
  field :matched, 6, type: :bool
  field :count, 7, type: :int32
  field :package_set_hash, 8, type: :string, json_name: "packageSetHash"
  field :hash_algorithm, 9, type: :string, json_name: "hashAlgorithm"
  field :evaluated_at, 10, type: :string, json_name: "evaluatedAt"
  field :freshness, 11, type: Serviceradar.Edge.V1.EndpointInventoryFreshnessVerdictV1

  field :labels, 12,
    repeated: true,
    type: Serviceradar.Edge.V1.EndpointInventoryStandingQuestionResultCountV1.LabelsEntry,
    map: true

  field :metadata, 13,
    repeated: true,
    type: Serviceradar.Edge.V1.EndpointInventoryStandingQuestionResultCountV1.MetadataEntry,
    map: true
end

defmodule Serviceradar.Edge.V1.EndpointInventoryFreshnessVerdictV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryFreshnessVerdictV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :verdict, 1, type: :string
  field :age_seconds, 2, type: :int64, json_name: "ageSeconds"
  field :stale_threshold_seconds, 3, type: :int64, json_name: "staleThresholdSeconds"
  field :last_successful_scan_at, 4, type: :string, json_name: "lastSuccessfulScanAt"
end

defmodule Serviceradar.Edge.V1.EndpointInventoryCycloneDXBOMV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryCycloneDXBOMV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :bom_format, 1, type: :string, json_name: "bomFormat"
  field :spec_version, 2, type: :string, json_name: "specVersion"
  field :serial_number, 3, type: :string, json_name: "serialNumber"
  field :version, 4, type: :int32
  field :metadata, 5, type: Serviceradar.Edge.V1.EndpointInventoryCycloneDXMetadataV1

  field :components, 6,
    repeated: true,
    type: Serviceradar.Edge.V1.EndpointInventoryCycloneDXComponentV1

  field :properties, 7,
    repeated: true,
    type: Serviceradar.Edge.V1.EndpointInventoryCycloneDXPropertyV1
end

defmodule Serviceradar.Edge.V1.EndpointInventoryCycloneDXMetadataV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryCycloneDXMetadataV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :timestamp, 1, type: :string
  field :tools, 2, repeated: true, type: Serviceradar.Edge.V1.EndpointInventoryCycloneDXToolV1
  field :component, 3, type: Serviceradar.Edge.V1.EndpointInventoryCycloneDXComponentV1

  field :properties, 4,
    repeated: true,
    type: Serviceradar.Edge.V1.EndpointInventoryCycloneDXPropertyV1
end

defmodule Serviceradar.Edge.V1.EndpointInventoryCycloneDXToolV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryCycloneDXToolV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :vendor, 1, type: :string
  field :name, 2, type: :string
  field :version, 3, type: :string
end

defmodule Serviceradar.Edge.V1.EndpointInventoryCycloneDXComponentV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryCycloneDXComponentV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :type, 1, type: :string
  field :name, 2, type: :string
  field :version, 3, type: :string
  field :group, 4, type: :string
  field :purl, 5, type: :string
  field :cpe, 6, type: :string

  field :properties, 7,
    repeated: true,
    type: Serviceradar.Edge.V1.EndpointInventoryCycloneDXPropertyV1
end

defmodule Serviceradar.Edge.V1.EndpointInventoryCycloneDXPropertyV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EndpointInventoryCycloneDXPropertyV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, type: :string
end
