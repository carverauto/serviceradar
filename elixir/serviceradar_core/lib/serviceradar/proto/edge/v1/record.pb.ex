defmodule Serviceradar.Edge.V1.EdgeRecordPayloadFamily do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeRecordPayloadFamily",
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

  field :EDGE_RECORD_PAYLOAD_FAMILY_UNSPECIFIED, 0
  field :EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1, 1
  field :EDGE_RECORD_PAYLOAD_FAMILY_RUN_EVENT_V1, 2
  field :EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_PAGE_V1, 3
  field :EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_TERMINAL_V1, 4
  field :EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1, 5
end

defmodule Serviceradar.Edge.V1.EdgeRecordCompression do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeRecordCompression",
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

  field :EDGE_RECORD_COMPRESSION_UNSPECIFIED, 0
  field :EDGE_RECORD_COMPRESSION_NONE, 1
  field :EDGE_RECORD_COMPRESSION_ZSTD, 2
end

defmodule Serviceradar.Edge.V1.EdgeRecordEncoding do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeRecordEncoding",
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

  field :EDGE_RECORD_ENCODING_UNSPECIFIED, 0
  field :EDGE_RECORD_ENCODING_PROTOBUF, 1
end

defmodule Serviceradar.Edge.V1.EdgeRecordTrafficClass do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeRecordTrafficClass",
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

  field :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED, 0
  field :EDGE_RECORD_TRAFFIC_CLASS_BULK, 1
  field :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE, 2
end

defmodule Serviceradar.Edge.V1.EdgeRecordRouteProfile do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeRecordRouteProfile",
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

  field :EDGE_RECORD_ROUTE_PROFILE_UNSPECIFIED, 0
  field :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1, 1
  field :EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1, 2
  field :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1, 3
end

defmodule Serviceradar.Edge.V1.EdgeOriginKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeOriginKind",
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

  field :EDGE_ORIGIN_KIND_UNSPECIFIED, 0
  field :EDGE_ORIGIN_KIND_AGENT, 1
  field :EDGE_ORIGIN_KIND_CLUSTER_SERVICE, 2
end

defmodule Serviceradar.Edge.V1.EdgeSourceAuthorizationKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeSourceAuthorizationKind",
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

  field :EDGE_SOURCE_AUTHORIZATION_KIND_UNSPECIFIED, 0
  field :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP, 1
  field :EDGE_SOURCE_AUTHORIZATION_KIND_SWEEP_PROFILE, 2
  field :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_CHECK, 3
  field :EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC, 4
  field :EDGE_SOURCE_AUTHORIZATION_KIND_ON_DEMAND, 5
  field :EDGE_SOURCE_AUTHORIZATION_KIND_INTEGRATION_RUN, 6
  field :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL, 7
end

defmodule Serviceradar.Edge.V1.EdgeCapabilityPurpose do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeCapabilityPurpose",
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

  field :EDGE_CAPABILITY_PURPOSE_UNSPECIFIED, 0
  field :EDGE_CAPABILITY_PURPOSE_PRODUCTION, 1
  field :EDGE_CAPABILITY_PURPOSE_SOURCE, 2
  field :EDGE_CAPABILITY_PURPOSE_DELIVERY, 3
  field :EDGE_CAPABILITY_PURPOSE_COLLECTION, 4
  field :EDGE_CAPABILITY_PURPOSE_ASSIGNMENT_EXECUTION, 5
end

defmodule Serviceradar.Edge.V1.EdgeRecordDispositionKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeRecordDispositionKind",
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

  field :EDGE_RECORD_DISPOSITION_KIND_UNSPECIFIED, 0
  field :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUTHORITATIVE, 1
  field :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_AUDIT_ONLY, 2
  field :EDGE_RECORD_DISPOSITION_KIND_ACCEPTED_QUARANTINE, 3
  field :EDGE_RECORD_DISPOSITION_KIND_REJECTED_PERMANENT, 4
  field :EDGE_RECORD_DISPOSITION_KIND_REJECTED_RETRYABLE, 5
end

defmodule Serviceradar.Edge.V1.EdgeUnattributableReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeUnattributableReason",
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

  field :EDGE_UNATTRIBUTABLE_REASON_UNSPECIFIED, 0
  field :EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING, 2
  field :EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT, 3
  field :EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL, 4
  field :EDGE_UNATTRIBUTABLE_REASON_BINDING_VERSION_UNSUPPORTED, 6
  field :EDGE_UNATTRIBUTABLE_REASON_DISCRIMINATOR_UNREPRESENTABLE, 7
end

defmodule Serviceradar.Edge.V1.EdgeSupportedContractV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeSupportedContractV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :contract_id, 1, type: :string, json_name: "contractId"
  field :contract_version, 2, type: :uint32, json_name: "contractVersion"
  field :contract_bundle_sha256, 3, type: :bytes, json_name: "contractBundleSha256"
end

defmodule Serviceradar.Edge.V1.EdgeRecordCapabilitiesV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeRecordCapabilitiesV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :protocol_versions, 1, repeated: true, type: :uint32, json_name: "protocolVersions"

  field :payload_families, 2,
    repeated: true,
    type: Serviceradar.Edge.V1.EdgeRecordPayloadFamily,
    json_name: "payloadFamilies",
    enum: true

  field :encodings, 3, repeated: true, type: Serviceradar.Edge.V1.EdgeRecordEncoding, enum: true

  field :compressions, 4,
    repeated: true,
    type: Serviceradar.Edge.V1.EdgeRecordCompression,
    enum: true

  field :spool_reader_versions, 5, repeated: true, type: :uint32, json_name: "spoolReaderVersions"
  field :max_record_bytes, 6, type: :uint64, json_name: "maxRecordBytes"
  field :max_delivery_envelope_bytes, 7, type: :uint64, json_name: "maxDeliveryEnvelopeBytes"
  field :max_frame_bytes, 8, type: :uint64, json_name: "maxFrameBytes"
  field :max_client_message_bytes, 9, type: :uint64, json_name: "maxClientMessageBytes"
  field :registry_epoch, 10, type: :uint64, json_name: "registryEpoch"
  field :registry_snapshot_sha256, 11, type: :bytes, json_name: "registrySnapshotSha256"

  field :output_contracts, 12,
    repeated: true,
    type: Serviceradar.Edge.V1.EdgeSupportedContractV1,
    json_name: "outputContracts"
end

defmodule Serviceradar.Edge.V1.EdgeProductionClaimsV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeProductionClaimsV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :contract_id, 1, type: :string, json_name: "contractId"
  field :contract_version, 2, type: :uint32, json_name: "contractVersion"
  field :contract_bundle_sha256, 3, type: :bytes, json_name: "contractBundleSha256"
  field :registry_epoch, 4, type: :uint64, json_name: "registryEpoch"
  field :network_scope_id, 5, type: :bytes, json_name: "networkScopeId"
  field :producer_assignment_id, 6, type: :bytes, json_name: "producerAssignmentId"

  field :traffic_class, 7,
    type: Serviceradar.Edge.V1.EdgeRecordTrafficClass,
    json_name: "trafficClass",
    enum: true

  field :route_profile, 8,
    type: Serviceradar.Edge.V1.EdgeRecordRouteProfile,
    json_name: "routeProfile",
    enum: true

  field :origin_kind, 9,
    type: Serviceradar.Edge.V1.EdgeOriginKind,
    json_name: "originKind",
    enum: true

  field :origin_principal_id, 10, type: :bytes, json_name: "originPrincipalId"
  field :producer_instance_id, 11, type: :bytes, json_name: "producerInstanceId"
  field :run_id, 12, type: :bytes, json_name: "runId"
  field :run_shard, 13, type: :uint32, json_name: "runShard"
  field :authority_epoch, 14, type: :uint64, json_name: "authorityEpoch"
  field :scope_id, 15, type: :bytes, json_name: "scopeId"
  field :scope_sha256, 16, type: :bytes, json_name: "scopeSha256"
  field :package_sha256, 17, type: :bytes, json_name: "packageSha256"
  field :registry_snapshot_sha256, 18, type: :bytes, json_name: "registrySnapshotSha256"
  field :effective_grant_sha256, 19, type: :bytes, json_name: "effectiveGrantSha256"
  field :max_projected_row_count, 20, type: :uint32, json_name: "maxProjectedRowCount"
  field :max_projected_write_bytes, 21, type: :uint64, json_name: "maxProjectedWriteBytes"
  field :cost_model_version, 22, type: :uint32, json_name: "costModelVersion"
  field :package_id, 23, type: :string, json_name: "packageId"
end

defmodule Serviceradar.Edge.V1.EdgeSourceClaimsV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeSourceClaimsV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :kind, 1, type: Serviceradar.Edge.V1.EdgeSourceAuthorizationKind, enum: true
  field :context_id, 2, type: :bytes, json_name: "contextId"
  field :scope_id, 3, type: :bytes, json_name: "scopeId"
  field :scope_sha256, 4, type: :bytes, json_name: "scopeSha256"
  field :network_scope_id, 5, type: :bytes, json_name: "networkScopeId"

  field :collection_not_before_unix_nano, 6,
    type: :int64,
    json_name: "collectionNotBeforeUnixNano"

  field :collection_expires_unix_nano, 7, type: :int64, json_name: "collectionExpiresUnixNano"
  field :origin_principal_id, 8, type: :bytes, json_name: "originPrincipalId"
  field :producer_instance_id, 9, type: :bytes, json_name: "producerInstanceId"
  field :producer_assignment_id, 10, type: :bytes, json_name: "producerAssignmentId"
  field :run_id, 11, type: :bytes, json_name: "runId"
  field :run_shard, 12, type: :uint32, json_name: "runShard"
  field :authority_epoch, 13, type: :uint64, json_name: "authorityEpoch"

  field :traffic_class, 14,
    type: Serviceradar.Edge.V1.EdgeRecordTrafficClass,
    json_name: "trafficClass",
    enum: true

  field :route_profile, 15,
    type: Serviceradar.Edge.V1.EdgeRecordRouteProfile,
    json_name: "routeProfile",
    enum: true

  field :execution_plan_sha256, 16, type: :bytes, json_name: "executionPlanSha256"
  field :target_range_sha256, 17, type: :bytes, json_name: "targetRangeSha256"

  field :origin_kind, 18,
    type: Serviceradar.Edge.V1.EdgeOriginKind,
    json_name: "originKind",
    enum: true
end

defmodule Serviceradar.Edge.V1.EdgeDeliveryClaimsV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeDeliveryClaimsV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:transition, 0)

  field :event_id, 1, type: :bytes, json_name: "eventId"
  field :record_sha256, 2, type: :bytes, json_name: "recordSha256"
  field :spool_id, 3, type: :bytes, json_name: "spoolId"
  field :sequence, 4, type: :uint64
  field :renewal, 5, type: Serviceradar.Edge.V1.EdgeDeliveryRenewalV1, oneof: 0
  field :rollover, 6, type: Serviceradar.Edge.V1.EdgeDeliveryRolloverV1, oneof: 0
end

defmodule Serviceradar.Edge.V1.EdgeDeliveryRenewalV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeDeliveryRenewalV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :renewed_not_before_unix_nano, 1, type: :int64, json_name: "renewedNotBeforeUnixNano"
  field :renewed_expires_unix_nano, 2, type: :int64, json_name: "renewedExpiresUnixNano"
end

defmodule Serviceradar.Edge.V1.EdgeDeliveryRolloverV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeDeliveryRolloverV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :recovery_id, 1, type: :bytes, json_name: "recoveryId"
  field :prior_spool_id, 2, type: :bytes, json_name: "priorSpoolId"
  field :prior_sequence, 3, type: :uint64, json_name: "priorSequence"
end

defmodule Serviceradar.Edge.V1.EdgeCollectionClaimsV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeCollectionClaimsV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :purpose, 1, type: Serviceradar.Edge.V1.EdgeCapabilityPurpose, enum: true
  field :network_scope_id, 2, type: :bytes, json_name: "networkScopeId"
  field :authenticated_agent_id, 3, type: :bytes, json_name: "authenticatedAgentId"
  field :execution_plan_id, 4, type: :bytes, json_name: "executionPlanId"
  field :target_range_id, 5, type: :bytes, json_name: "targetRangeId"
  field :execution_shard, 6, type: :uint32, json_name: "executionShard"
  field :assignment_epoch, 7, type: :uint64, json_name: "assignmentEpoch"

  field :compiled_assignment_body_sha256, 8,
    type: :bytes,
    json_name: "compiledAssignmentBodySha256"

  field :traffic_class, 9,
    type: Serviceradar.Edge.V1.EdgeRecordTrafficClass,
    json_name: "trafficClass",
    enum: true

  field :producer_assignment_id, 10, type: :bytes, json_name: "producerAssignmentId"
  field :execution_id, 11, type: :bytes, json_name: "executionId"
end

defmodule Serviceradar.Edge.V1.EdgeAssignmentExecutionClaimsV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeAssignmentExecutionClaimsV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :purpose, 1, type: Serviceradar.Edge.V1.EdgeCapabilityPurpose, enum: true
  field :network_scope_id, 2, type: :bytes, json_name: "networkScopeId"
  field :authenticated_agent_id, 3, type: :bytes, json_name: "authenticatedAgentId"
  field :producer_assignment_id, 4, type: :bytes, json_name: "producerAssignmentId"
  field :execution_id, 5, type: :bytes, json_name: "executionId"
  field :run_id, 6, type: :bytes, json_name: "runId"
  field :run_shard, 7, type: :uint32, json_name: "runShard"
  field :authority_epoch, 8, type: :uint64, json_name: "authorityEpoch"
  field :production_scope_id, 9, type: :bytes, json_name: "productionScopeId"
  field :scope_sha256, 10, type: :bytes, json_name: "scopeSha256"
  field :contract_bundle_sha256, 11, type: :bytes, json_name: "contractBundleSha256"
  field :execution_plan_sha256, 12, type: :bytes, json_name: "executionPlanSha256"
  field :target_range_sha256, 13, type: :bytes, json_name: "targetRangeSha256"

  field :traffic_class, 14,
    type: Serviceradar.Edge.V1.EdgeRecordTrafficClass,
    json_name: "trafficClass",
    enum: true

  field :collection_not_before_unix_nano, 15,
    type: :int64,
    json_name: "collectionNotBeforeUnixNano"

  field :collection_expires_unix_nano, 16, type: :int64, json_name: "collectionExpiresUnixNano"

  field :source_identity, 17,
    type: Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1,
    json_name: "sourceIdentity"

  field :compiled_assignment_id, 18, type: :bytes, json_name: "compiledAssignmentId"
  field :compiled_assignment_sha256, 19, type: :bytes, json_name: "compiledAssignmentSha256"
end

defmodule Serviceradar.Edge.V1.EdgeSignedCapabilityV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeSignedCapabilityV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:claims, 0)

  field :capability_version, 1, type: :uint32, json_name: "capabilityVersion"
  field :issuer_id, 2, type: :bytes, json_name: "issuerId"
  field :issuer_key_id, 3, type: :bytes, json_name: "issuerKeyId"
  field :algorithm, 4, type: :string
  field :not_before_unix_nano, 5, type: :int64, json_name: "notBeforeUnixNano"
  field :expires_at_unix_nano, 6, type: :int64, json_name: "expiresAtUnixNano"
  field :production, 7, type: Serviceradar.Edge.V1.EdgeProductionClaimsV1, oneof: 0
  field :source, 8, type: Serviceradar.Edge.V1.EdgeSourceClaimsV1, oneof: 0
  field :delivery, 9, type: Serviceradar.Edge.V1.EdgeDeliveryClaimsV1, oneof: 0
  field :collection, 11, type: Serviceradar.Edge.V1.EdgeCollectionClaimsV1, oneof: 0

  field :assignment_execution, 12,
    type: Serviceradar.Edge.V1.EdgeAssignmentExecutionClaimsV1,
    json_name: "assignmentExecution",
    oneof: 0

  field :signature, 10, type: :bytes
end

defmodule Serviceradar.Edge.V1.EdgeSourceAuthorizationV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeSourceAuthorizationV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :kind, 1, type: Serviceradar.Edge.V1.EdgeSourceAuthorizationKind, enum: true
  field :capability, 2, type: Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  field :context_id, 3, type: :bytes, json_name: "contextId"
  field :scope_id, 4, type: :bytes, json_name: "scopeId"
  field :scope_sha256, 5, type: :bytes, json_name: "scopeSha256"
end

defmodule Serviceradar.Edge.V1.EdgeOutputContractRef do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeOutputContractRef",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :contract_id, 1, type: :string, json_name: "contractId"
  field :contract_version, 2, type: :uint32, json_name: "contractVersion"
  field :contract_bundle_sha256, 3, type: :bytes, json_name: "contractBundleSha256"
  field :registry_epoch, 4, type: :uint64, json_name: "registryEpoch"
  field :registry_snapshot_sha256, 5, type: :bytes, json_name: "registrySnapshotSha256"
  field :effective_grant_sha256, 6, type: :bytes, json_name: "effectiveGrantSha256"
end

defmodule Serviceradar.Edge.V1.EdgeProducerContext do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeProducerContext",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :origin_kind, 1,
    type: Serviceradar.Edge.V1.EdgeOriginKind,
    json_name: "originKind",
    enum: true

  field :origin_principal_id, 2, type: :bytes, json_name: "originPrincipalId"
  field :producer_instance_id, 3, type: :bytes, json_name: "producerInstanceId"
  field :producer_assignment_id, 4, type: :bytes, json_name: "producerAssignmentId"
  field :run_id, 5, type: :bytes, json_name: "runId"
  field :run_shard, 6, type: :uint32, json_name: "runShard"
  field :authority_epoch, 7, proto3_optional: true, type: :uint64, json_name: "authorityEpoch"
  field :scope_id, 8, type: :bytes, json_name: "scopeId"
  field :scope_sha256, 9, type: :bytes, json_name: "scopeSha256"
  field :package_id, 10, type: :string, json_name: "packageId"
  field :package_sha256, 11, type: :bytes, json_name: "packageSha256"
end

defmodule Serviceradar.Edge.V1.EdgeRecordV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeRecordV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :event_id, 1, type: :bytes, json_name: "eventId"

  field :payload_family, 2,
    type: Serviceradar.Edge.V1.EdgeRecordPayloadFamily,
    json_name: "payloadFamily",
    enum: true

  field :compression, 3, type: Serviceradar.Edge.V1.EdgeRecordCompression, enum: true
  field :encoded_size, 4, type: :uint32, json_name: "encodedSize"
  field :uncompressed_size, 5, type: :uint32, json_name: "uncompressedSize"
  field :payload_sha256, 6, type: :bytes, json_name: "payloadSha256"

  field :output_contract, 7,
    type: Serviceradar.Edge.V1.EdgeOutputContractRef,
    json_name: "outputContract"

  field :producer_context, 8,
    type: Serviceradar.Edge.V1.EdgeProducerContext,
    json_name: "producerContext"

  field :route_profile, 9,
    type: Serviceradar.Edge.V1.EdgeRecordRouteProfile,
    json_name: "routeProfile",
    enum: true

  field :traffic_class, 10,
    type: Serviceradar.Edge.V1.EdgeRecordTrafficClass,
    json_name: "trafficClass",
    enum: true

  field :network_scope_id, 11, type: :bytes, json_name: "networkScopeId"

  field :production_capability, 12,
    type: Serviceradar.Edge.V1.EdgeSignedCapabilityV1,
    json_name: "productionCapability"

  field :source_authorization, 13,
    proto3_optional: true,
    type: Serviceradar.Edge.V1.EdgeSourceAuthorizationV1,
    json_name: "sourceAuthorization"

  field :projected_row_count, 14, type: :uint32, json_name: "projectedRowCount"
  field :projected_write_bytes, 15, type: :uint64, json_name: "projectedWriteBytes"
  field :cost_model_version, 16, type: :uint32, json_name: "costModelVersion"
  field :semantic_envelope_sha256, 17, type: :bytes, json_name: "semanticEnvelopeSha256"
  field :payload, 18, type: :bytes
end

defmodule Serviceradar.Edge.V1.EdgeDeliveryFrameV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeDeliveryFrameV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :spool_id, 1, type: :bytes, json_name: "spoolId"
  field :sequence, 2, type: :uint64
  field :record_sha256, 3, type: :bytes, json_name: "recordSha256"

  field :delivery_capability, 4,
    proto3_optional: true,
    type: Serviceradar.Edge.V1.EdgeSignedCapabilityV1,
    json_name: "deliveryCapability"

  field :record_bytes, 5, type: :bytes, json_name: "recordBytes"
end

defmodule Serviceradar.Edge.V1.EdgeRecordDisposition do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeRecordDisposition",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :sequence, 1, type: :uint64
  field :event_id, 2, type: :bytes, json_name: "eventId"
  field :kind, 3, type: Serviceradar.Edge.V1.EdgeRecordDispositionKind, enum: true
  field :rejection_code, 4, type: :string, json_name: "rejectionCode"
end

defmodule Serviceradar.Edge.V1.EdgeDeliveryAckV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeDeliveryAckV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :spool_id, 1, type: :bytes, json_name: "spoolId"
  field :resolved_through_sequence, 2, type: :uint64, json_name: "resolvedThroughSequence"
  field :dispositions, 3, repeated: true, type: Serviceradar.Edge.V1.EdgeRecordDisposition
  field :session_nonce, 4, type: :bytes, json_name: "sessionNonce"
end

defmodule Serviceradar.Edge.V1.EdgeRecordLaneOpen do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeRecordLaneOpen",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :route_profile, 1,
    type: Serviceradar.Edge.V1.EdgeRecordRouteProfile,
    json_name: "routeProfile",
    enum: true

  field :traffic_class, 2,
    type: Serviceradar.Edge.V1.EdgeRecordTrafficClass,
    json_name: "trafficClass",
    enum: true

  field :spool_id, 3, type: :bytes, json_name: "spoolId"
  field :sequence_base, 4, type: :uint64, json_name: "sequenceBase"
  field :first_unresolved_sequence, 5, type: :uint64, json_name: "firstUnresolvedSequence"
  field :session_nonce, 6, type: :bytes, json_name: "sessionNonce"
  field :requested_byte_credits, 7, type: :uint64, json_name: "requestedByteCredits"
  field :requested_frame_credits, 8, type: :uint32, json_name: "requestedFrameCredits"
end

defmodule Serviceradar.Edge.V1.EdgeRecordLaneOpenAck do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeRecordLaneOpenAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :spool_id, 1, type: :bytes, json_name: "spoolId"
  field :session_nonce, 2, type: :bytes, json_name: "sessionNonce"
  field :granted_byte_credits, 3, type: :uint64, json_name: "grantedByteCredits"
  field :granted_frame_credits, 4, type: :uint32, json_name: "grantedFrameCredits"

  field :route_profile, 5,
    type: Serviceradar.Edge.V1.EdgeRecordRouteProfile,
    json_name: "routeProfile",
    enum: true

  field :traffic_class, 6,
    type: Serviceradar.Edge.V1.EdgeRecordTrafficClass,
    json_name: "trafficClass",
    enum: true
end

defmodule Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeSourceSpanIdentityV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :kind, 1, type: Serviceradar.Edge.V1.EdgeSourceAuthorizationKind, enum: true
  field :context_id, 2, type: :bytes, json_name: "contextId"
  field :source_scope_id, 3, type: :bytes, json_name: "sourceScopeId"
  field :source_scope_sha256, 4, type: :bytes, json_name: "sourceScopeSha256"
end

defmodule Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeAttributedSpanIdentityV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :producer_assignment_id, 1, type: :bytes, json_name: "producerAssignmentId"
  field :run_id, 2, type: :bytes, json_name: "runId"
  field :run_shard, 3, type: :uint32, json_name: "runShard"
  field :authority_epoch, 4, type: :uint64, json_name: "authorityEpoch"
  field :production_scope_id, 5, type: :bytes, json_name: "productionScopeId"
  field :scope_sha256, 6, type: :bytes, json_name: "scopeSha256"
  field :contract_bundle_sha256, 7, type: :bytes, json_name: "contractBundleSha256"
  field :source, 8, type: Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1
end

defmodule Serviceradar.Edge.V1.EdgeAttributedActiveV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeAttributedActiveV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :identity, 1, type: Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  field :range_sha256, 2, type: :bytes, json_name: "rangeSha256"
end

defmodule Serviceradar.Edge.V1.EdgeAttributedPassiveV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeAttributedPassiveV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :identity, 1, type: Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
end

defmodule Serviceradar.Edge.V1.EdgeUnattributableV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeUnattributableV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :reason, 1, type: Serviceradar.Edge.V1.EdgeUnattributableReason, enum: true
end

defmodule Serviceradar.Edge.V1.EdgeClassificationSpanV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeClassificationSpanV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:classification, 0)

  field :from_sequence, 1, type: :uint64, json_name: "fromSequence"
  field :through_sequence, 2, type: :uint64, json_name: "throughSequence"

  field :attributed_active, 3,
    type: Serviceradar.Edge.V1.EdgeAttributedActiveV1,
    json_name: "attributedActive",
    oneof: 0

  field :attributed_passive, 4,
    type: Serviceradar.Edge.V1.EdgeAttributedPassiveV1,
    json_name: "attributedPassive",
    oneof: 0

  field :unattributable, 5, type: Serviceradar.Edge.V1.EdgeUnattributableV1, oneof: 0
end

defmodule Serviceradar.Edge.V1.EdgeLossManifestPageV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeLossManifestPageV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :recovery_id, 1, type: :bytes, json_name: "recoveryId"
  field :page_index, 2, type: :uint32, json_name: "pageIndex"
  field :page_count, 3, type: :uint32, json_name: "pageCount"
  field :prev_page_sha256, 4, type: :bytes, json_name: "prevPageSha256"
  field :page_sha256, 5, type: :bytes, json_name: "pageSha256"
  field :terminal, 6, type: :bool
  field :digest_version, 8, type: :uint32, json_name: "digestVersion"

  field :classification_spans, 11,
    repeated: true,
    type: Serviceradar.Edge.V1.EdgeClassificationSpanV1,
    json_name: "classificationSpans"
end

defmodule Serviceradar.Edge.V1.SpoolLossTombstoneV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SpoolLossTombstoneV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :recovery_id, 1, type: :bytes, json_name: "recoveryId"
  field :prior_spool_id, 2, type: :bytes, json_name: "priorSpoolId"
  field :new_spool_id, 5, type: :bytes, json_name: "newSpoolId"
  field :manifest_root_sha256, 6, type: :bytes, json_name: "manifestRootSha256"
  field :manifest_page_count, 7, type: :uint32, json_name: "manifestPageCount"
  field :detected_at_unix_nano, 9, type: :int64, json_name: "detectedAtUnixNano"
  field :reason, 10, type: :string
  field :digest_version, 11, type: :uint32, json_name: "digestVersion"
end

defmodule Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeRecoveryControlPayloadV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:body, 0)

  field :tombstone, 1, type: Serviceradar.Edge.V1.SpoolLossTombstoneV1, oneof: 0

  field :manifest_page, 2,
    type: Serviceradar.Edge.V1.EdgeLossManifestPageV1,
    json_name: "manifestPage",
    oneof: 0

  field :resolved, 3, type: Serviceradar.Edge.V1.RecoveryResolvedV1, oneof: 0
end

defmodule Serviceradar.Edge.V1.RecoveryResolvedV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.RecoveryResolvedV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :recovery_id, 1, type: :bytes, json_name: "recoveryId"
  field :manifest_root_sha256, 2, type: :bytes, json_name: "manifestRootSha256"
  field :applied_through_sequence, 3, type: :uint64, json_name: "appliedThroughSequence"
  field :resolved_at_unix_nano, 4, type: :int64, json_name: "resolvedAtUnixNano"
end

defmodule Serviceradar.Edge.V1.EdgeRecordClientMessage do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeRecordClientMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:payload, 0)

  field :lane_open, 1,
    type: Serviceradar.Edge.V1.EdgeRecordLaneOpen,
    json_name: "laneOpen",
    oneof: 0

  field :delivery_frame, 2,
    type: Serviceradar.Edge.V1.EdgeDeliveryFrameV1,
    json_name: "deliveryFrame",
    oneof: 0
end

defmodule Serviceradar.Edge.V1.EdgeRecordServerMessage do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeRecordServerMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:payload, 0)

  field :lane_open_ack, 1,
    type: Serviceradar.Edge.V1.EdgeRecordLaneOpenAck,
    json_name: "laneOpenAck",
    oneof: 0

  field :ack, 2, type: Serviceradar.Edge.V1.EdgeDeliveryAckV1, oneof: 0
end

defmodule Serviceradar.Edge.V1.EdgeRecordIngestService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "serviceradar.edge.v1.EdgeRecordIngestService",
    protoc_gen_elixir_version: "0.16.0"

  rpc(
    :Stream,
    stream(Serviceradar.Edge.V1.EdgeRecordClientMessage),
    stream(Serviceradar.Edge.V1.EdgeRecordServerMessage)
  )
end

defmodule Serviceradar.Edge.V1.EdgeRecordIngestService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Serviceradar.Edge.V1.EdgeRecordIngestService.Service
end
