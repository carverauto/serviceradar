defmodule Serviceradar.Edge.V1.BumblebeeScanPayloadV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.BumblebeeScanPayloadV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :schema_version, 1, type: :string, json_name: "schemaVersion"
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :device_uid, 3, type: :string, json_name: "deviceUid"
  field :run_id, 4, type: :string, json_name: "runId"
  field :scanner_version, 5, type: :string, json_name: "scannerVersion"
  field :catalog_snapshot_ref, 6, type: :string, json_name: "catalogSnapshotRef"
  field :state, 7, type: :string
  field :coverage_state, 8, type: :string, json_name: "coverageState"
  field :attempted_root_count, 9, type: :int32, json_name: "attemptedRootCount"
  field :scanned_root_count, 10, type: :int32, json_name: "scannedRootCount"
  field :skipped_root_count, 11, type: :int32, json_name: "skippedRootCount"
  field :root_covered, 12, type: :bool, json_name: "rootCovered"
  field :attempted_roots, 13, repeated: true, type: :string, json_name: "attemptedRoots"
  field :scanned_roots, 14, repeated: true, type: :string, json_name: "scannedRoots"

  field :skipped_roots, 15,
    repeated: true,
    type: Serviceradar.Edge.V1.BumblebeeSkippedRootV1,
    json_name: "skippedRoots"

  field :last_scan_at, 16, type: :string, json_name: "lastScanAt"
  field :last_successful_scan_at, 17, type: :string, json_name: "lastSuccessfulScanAt"
  field :findings, 18, repeated: true, type: Serviceradar.Edge.V1.BumblebeeFindingV1
  field :metadata_json, 19, type: :bytes, json_name: "metadataJson"
end

defmodule Serviceradar.Edge.V1.BumblebeeSkippedRootV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.BumblebeeSkippedRootV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :path, 1, type: :string
  field :reason, 2, type: :string
end

defmodule Serviceradar.Edge.V1.BumblebeeFindingV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.BumblebeeFindingV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :finding_id, 2, type: :string, json_name: "findingId"
  field :catalog_id, 3, type: :string, json_name: "catalogId"
  field :severity, 4, type: :string
  field :risk_score, 5, type: :int32, json_name: "riskScore"
  field :has_risk_score, 6, type: :bool, json_name: "hasRiskScore"
  field :ecosystem, 7, type: :string
  field :package_name, 8, type: :string, json_name: "packageName"
  field :package_version, 9, type: :string, json_name: "packageVersion"
  field :evidence_json, 10, type: :bytes, json_name: "evidenceJson"
  field :confidence, 11, type: :string
  field :metadata_json, 12, type: :bytes, json_name: "metadataJson"
end
