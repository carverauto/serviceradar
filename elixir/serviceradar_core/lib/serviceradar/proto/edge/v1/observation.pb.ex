defmodule Serviceradar.Edge.V1.EdgeResultPayloadKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeResultPayloadKind",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :EDGE_RESULT_PAYLOAD_KIND_UNSPECIFIED, 0
  field :EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1, 1
  field :EDGE_RESULT_PAYLOAD_KIND_SWEEP_EXECUTION_EVENT_V1, 2
  field :EDGE_RESULT_PAYLOAD_KIND_MTR_TRACE_BATCH_V1, 3
  field :EDGE_RESULT_PAYLOAD_KIND_LEGACY_SWEEP_JSON_V0, 4
  field :EDGE_RESULT_PAYLOAD_KIND_LEGACY_MTR_JSON_V0, 5
  field :EDGE_RESULT_PAYLOAD_KIND_SPOOL_LOSS_TOMBSTONE_V1, 6
end

defmodule Serviceradar.Edge.V1.EdgeResultCompression do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeResultCompression",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :EDGE_RESULT_COMPRESSION_NONE, 0
  field :EDGE_RESULT_COMPRESSION_ZSTD, 1
end

defmodule Serviceradar.Edge.V1.EdgeResultAuthorizationKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeResultAuthorizationKind",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :EDGE_RESULT_AUTHORIZATION_KIND_UNSPECIFIED, 0
  field :EDGE_RESULT_AUTHORIZATION_KIND_SWEEP_ASSIGNMENT, 1
  field :EDGE_RESULT_AUTHORIZATION_KIND_SCHEDULED_CHECK, 2
  field :EDGE_RESULT_AUTHORIZATION_KIND_COMMAND, 3
  field :EDGE_RESULT_AUTHORIZATION_KIND_SPOOL_RECOVERY, 4
end

defmodule Serviceradar.Edge.V1.EdgeResultTrafficClass do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeResultTrafficClass",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :EDGE_RESULT_TRAFFIC_CLASS_UNSPECIFIED, 0
  field :EDGE_RESULT_TRAFFIC_CLASS_BULK, 1
  field :EDGE_RESULT_TRAFFIC_CLASS_INTERACTIVE, 2
end

defmodule Serviceradar.Edge.V1.EdgeResultDispositionKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeResultDispositionKind",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :EDGE_RESULT_DISPOSITION_KIND_UNSPECIFIED, 0
  field :EDGE_RESULT_DISPOSITION_KIND_ACCEPTED, 1
  field :EDGE_RESULT_DISPOSITION_KIND_REJECTED, 2
end

defmodule Serviceradar.Edge.V1.EdgeResultLaneKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.EdgeResultLaneKind",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :EDGE_RESULT_LANE_KIND_UNSPECIFIED, 0
  field :EDGE_RESULT_LANE_KIND_SWEEP_BULK, 1
  field :EDGE_RESULT_LANE_KIND_SWEEP_INTERACTIVE, 2
  field :EDGE_RESULT_LANE_KIND_MTR_BULK, 3
  field :EDGE_RESULT_LANE_KIND_MTR_INTERACTIVE, 4
  field :EDGE_RESULT_LANE_KIND_RECOVERY_CONTROL, 5
end

defmodule Serviceradar.Edge.V1.SweepMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.SweepMode",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SWEEP_MODE_UNSPECIFIED, 0
  field :SWEEP_MODE_ICMP, 1
  field :SWEEP_MODE_TCP_SYN, 2
  field :SWEEP_MODE_TCP_CONNECT, 3
  field :SWEEP_MODE_MTR, 4
end

defmodule Serviceradar.Edge.V1.SweepModeBit do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.SweepModeBit",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SWEEP_MODE_BIT_UNSPECIFIED, 0
  field :SWEEP_MODE_BIT_ICMP, 1
  field :SWEEP_MODE_BIT_TCP_SYN, 2
  field :SWEEP_MODE_BIT_TCP_CONNECT, 4
  field :SWEEP_MODE_BIT_MTR, 8
end

defmodule Serviceradar.Edge.V1.TransportProtocol do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.TransportProtocol",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :TRANSPORT_PROTOCOL_UNSPECIFIED, 0
  field :TRANSPORT_PROTOCOL_ICMP, 1
  field :TRANSPORT_PROTOCOL_TCP, 2
  field :TRANSPORT_PROTOCOL_UDP, 3
end

defmodule Serviceradar.Edge.V1.SweepModeOutcome do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.SweepModeOutcome",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SWEEP_MODE_OUTCOME_UNSPECIFIED, 0
  field :SWEEP_MODE_OUTCOME_SUCCESS, 1
  field :SWEEP_MODE_OUTCOME_FAILURE, 2
  field :SWEEP_MODE_OUTCOME_SKIPPED, 3
  field :SWEEP_MODE_OUTCOME_NOT_ADMITTED, 4
  field :SWEEP_MODE_OUTCOME_TIMED_OUT, 5
  field :SWEEP_MODE_OUTCOME_UNKNOWN, 6
end

defmodule Serviceradar.Edge.V1.MtrOutcome do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.MtrOutcome",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :MTR_OUTCOME_UNSPECIFIED, 0
  field :MTR_OUTCOME_REACHED, 1
  field :MTR_OUTCOME_TARGET_UNREACHABLE, 2
  field :MTR_OUTCOME_PROBE_FAILED, 3
  field :MTR_OUTCOME_TIMED_OUT, 4
  field :MTR_OUTCOME_NOT_ADMITTED, 5
  field :MTR_OUTCOME_QUARANTINED, 6
  field :MTR_OUTCOME_SCHEDULER_LOST, 7
end

defmodule Serviceradar.Edge.V1.SweepExecutionSource do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.SweepExecutionSource",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SWEEP_EXECUTION_SOURCE_UNSPECIFIED, 0
  field :SWEEP_EXECUTION_SOURCE_SCHEDULED_SWEEP, 1
  field :SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE, 2
  field :SWEEP_EXECUTION_SOURCE_AD_HOC, 3
  field :SWEEP_EXECUTION_SOURCE_ON_DEMAND, 4
  field :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK, 5
end

defmodule Serviceradar.Edge.V1.SweepExecutionEventKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.SweepExecutionEventKind",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :SWEEP_EXECUTION_EVENT_KIND_UNSPECIFIED, 0
  field :SWEEP_EXECUTION_EVENT_KIND_START, 1
  field :SWEEP_EXECUTION_EVENT_KIND_PROGRESS, 2
  field :SWEEP_EXECUTION_EVENT_KIND_COMPLETED, 3
  field :SWEEP_EXECUTION_EVENT_KIND_ABORTED, 4
end

defmodule Serviceradar.Edge.V1.EdgeResultFrame do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeResultFrame",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :spool_id, 1, type: :bytes, json_name: "spoolId"
  field :sequence, 2, type: :uint64
  field :event_id, 3, type: :bytes, json_name: "eventId"

  field :payload_kind, 4,
    type: Serviceradar.Edge.V1.EdgeResultPayloadKind,
    json_name: "payloadKind",
    enum: true

  field :schema_version, 5, type: :uint32, json_name: "schemaVersion"
  field :compression, 6, type: Serviceradar.Edge.V1.EdgeResultCompression, enum: true
  field :encoded_size, 7, type: :uint32, json_name: "encodedSize"
  field :uncompressed_size, 8, type: :uint32, json_name: "uncompressedSize"
  field :payload_sha256, 9, type: :bytes, json_name: "payloadSha256"
  field :execution_id, 10, type: :bytes, json_name: "executionId"
  field :execution_shard, 11, type: :uint32, json_name: "executionShard"
  field :assignment_epoch, 12, proto3_optional: true, type: :uint64, json_name: "assignmentEpoch"
  field :collection_capability, 13, type: :bytes, json_name: "collectionCapability"
  field :projected_row_count, 14, type: :uint32, json_name: "projectedRowCount"
  field :payload, 15, type: :bytes

  field :authorization_kind, 16,
    type: Serviceradar.Edge.V1.EdgeResultAuthorizationKind,
    json_name: "authorizationKind",
    enum: true

  field :authorization_context_id, 17, type: :bytes, json_name: "authorizationContextId"
  field :target_range_id, 18, type: :bytes, json_name: "targetRangeId"
  field :target_range_sha256, 19, type: :bytes, json_name: "targetRangeSha256"
  field :delivery_capability, 20, type: :bytes, json_name: "deliveryCapability"
  field :projected_write_bytes, 21, type: :uint64, json_name: "projectedWriteBytes"
  field :cost_model_version, 22, type: :uint32, json_name: "costModelVersion"
  field :network_scope_id, 23, type: :bytes, json_name: "networkScopeId"

  field :traffic_class, 24,
    type: Serviceradar.Edge.V1.EdgeResultTrafficClass,
    json_name: "trafficClass",
    enum: true
end

defmodule Serviceradar.Edge.V1.EdgeResultDisposition do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeResultDisposition",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :sequence, 1, type: :uint64
  field :event_id, 2, type: :bytes, json_name: "eventId"
  field :kind, 3, type: Serviceradar.Edge.V1.EdgeResultDispositionKind, enum: true
  field :rejection_code, 4, type: :string, json_name: "rejectionCode"
end

defmodule Serviceradar.Edge.V1.EdgeResultLaneOpen do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeResultLaneOpen",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :spool_id, 1, type: :bytes, json_name: "spoolId"

  field :lane_kind, 2,
    type: Serviceradar.Edge.V1.EdgeResultLaneKind,
    json_name: "laneKind",
    enum: true

  field :sequence_base, 3, type: :uint64, json_name: "sequenceBase"
  field :first_unresolved_sequence, 4, type: :uint64, json_name: "firstUnresolvedSequence"
  field :session_nonce, 5, type: :bytes, json_name: "sessionNonce"
  field :requested_byte_credits, 6, type: :uint64, json_name: "requestedByteCredits"
  field :requested_frame_credits, 7, type: :uint32, json_name: "requestedFrameCredits"
end

defmodule Serviceradar.Edge.V1.EdgeResultLaneOpenAck do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeResultLaneOpenAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :spool_id, 1, type: :bytes, json_name: "spoolId"
  field :session_nonce, 2, type: :bytes, json_name: "sessionNonce"
  field :granted_byte_credits, 3, type: :uint64, json_name: "grantedByteCredits"
  field :granted_frame_credits, 4, type: :uint32, json_name: "grantedFrameCredits"
end

defmodule Serviceradar.Edge.V1.EdgeResultAck do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.EdgeResultAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :spool_id, 1, type: :bytes, json_name: "spoolId"
  field :resolved_through_sequence, 2, type: :uint64, json_name: "resolvedThroughSequence"
  field :dispositions, 3, repeated: true, type: Serviceradar.Edge.V1.EdgeResultDisposition
  field :session_nonce, 4, type: :bytes, json_name: "sessionNonce"
end

defmodule Serviceradar.Edge.V1.SpoolLossTombstoneV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SpoolLossTombstoneV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :recovery_id, 1, type: :bytes, json_name: "recoveryId"
  field :prior_spool_id, 2, type: :bytes, json_name: "priorSpoolId"
  field :lost_from_sequence, 3, type: :uint64, json_name: "lostFromSequence"
  field :lost_through_sequence, 4, type: :uint64, json_name: "lostThroughSequence"
  field :new_spool_id, 5, type: :bytes, json_name: "newSpoolId"
  field :manifest_sha256, 6, type: :bytes, json_name: "manifestSha256"
  field :coarsened, 7, type: :bool
  field :detected_at_unix_nano, 8, type: :int64, json_name: "detectedAtUnixNano"
end

defmodule Serviceradar.Edge.V1.SweepTestV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepTestV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :mode, 1, type: Serviceradar.Edge.V1.SweepMode, enum: true
  field :protocol, 2, type: Serviceradar.Edge.V1.TransportProtocol, enum: true
  field :port, 3, type: :uint32
end

defmodule Serviceradar.Edge.V1.SweepObservationBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepObservationBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :execution_id, 1, type: :bytes, json_name: "executionId"
  field :sweep_group_id, 2, type: :bytes, json_name: "sweepGroupId"
  field :execution_shard, 3, type: :uint32, json_name: "executionShard"
  field :assignment_epoch, 4, type: :uint64, json_name: "assignmentEpoch"
  field :batch_sequence, 5, type: :uint64, json_name: "batchSequence"
  field :observed_at_unix_nano, 6, type: :int64, json_name: "observedAtUnixNano"
  field :execution_plan_id, 7, type: :bytes, json_name: "executionPlanId"
  field :execution_plan_sha256, 8, type: :bytes, json_name: "executionPlanSha256"
  field :target_range_id, 9, type: :bytes, json_name: "targetRangeId"
  field :target_range_sha256, 10, type: :bytes, json_name: "targetRangeSha256"

  field :tested_checks, 11,
    repeated: true,
    type: Serviceradar.Edge.V1.SweepTestV1,
    json_name: "testedChecks"

  field :configured_mode_bits, 12, type: :uint32, json_name: "configuredModeBits"
  field :availability_policy_id, 13, type: :bytes, json_name: "availabilityPolicyId"
  field :source, 14, type: Serviceradar.Edge.V1.SweepExecutionSource, enum: true
  field :source_run_id, 15, type: :bytes, json_name: "sourceRunId"
  field :hosts, 16, repeated: true, type: Serviceradar.Edge.V1.SweepHostObservationV1
end

defmodule Serviceradar.Edge.V1.SweepHostObservationV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepHostObservationV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :address, 1, type: :bytes
  field :hostname, 2, type: :string
  field :observed_at_delta_nano, 3, type: :sint64, json_name: "observedAtDeltaNano"
  field :first_seen_delta_nano, 4, type: :sint64, json_name: "firstSeenDeltaNano"
  field :last_seen_delta_nano, 5, type: :sint64, json_name: "lastSeenDeltaNano"
  field :result_mode_bits, 6, type: :uint32, json_name: "resultModeBits"
  field :mode_revision, 7, type: :uint32, json_name: "modeRevision"
  field :icmp, 8, proto3_optional: true, type: Serviceradar.Edge.V1.SweepIcmpSummaryV1
  field :tcp, 9, proto3_optional: true, type: Serviceradar.Edge.V1.SweepTcpSummaryV1

  field :open_ports, 10,
    repeated: true,
    type: Serviceradar.Edge.V1.SweepOpenPortV1,
    json_name: "openPorts"

  field :port_errors, 11,
    repeated: true,
    type: Serviceradar.Edge.V1.SweepPortErrorV1,
    json_name: "portErrors"

  field :mtr, 12, proto3_optional: true, type: Serviceradar.Edge.V1.SweepMtrSummaryV1
end

defmodule Serviceradar.Edge.V1.SweepIcmpSummaryV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepIcmpSummaryV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :outcome, 1, type: Serviceradar.Edge.V1.SweepModeOutcome, enum: true
  field :target_reached, 2, type: :bool, json_name: "targetReached"
  field :round_trip_micro, 3, proto3_optional: true, type: :uint64, json_name: "roundTripMicro"
  field :packet_loss_pct, 4, proto3_optional: true, type: :double, json_name: "packetLossPct"
  field :sent, 5, type: :uint32
  field :received, 6, type: :uint32
end

defmodule Serviceradar.Edge.V1.SweepTcpSummaryV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepTcpSummaryV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :outcome, 1, type: Serviceradar.Edge.V1.SweepModeOutcome, enum: true
  field :tested_count, 2, type: :uint32, json_name: "testedCount"
  field :open_count, 3, type: :uint32, json_name: "openCount"
end

defmodule Serviceradar.Edge.V1.SweepOpenPortV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepOpenPortV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :tested_check_index, 1, type: :uint32, json_name: "testedCheckIndex"

  field :response_time_nano, 2,
    proto3_optional: true,
    type: :uint64,
    json_name: "responseTimeNano"

  field :service, 3, type: :string
end

defmodule Serviceradar.Edge.V1.SweepPortErrorV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepPortErrorV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :tested_check_index, 1, type: :uint32, json_name: "testedCheckIndex"
  field :error_code, 2, type: :string, json_name: "errorCode"
end

defmodule Serviceradar.Edge.V1.SweepMtrSummaryV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepMtrSummaryV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :trace_id, 1, type: :bytes, json_name: "traceId"
  field :outcome, 2, type: Serviceradar.Edge.V1.MtrOutcome, enum: true
  field :target_reached, 3, type: :bool, json_name: "targetReached"
  field :final_rtt_micro, 4, proto3_optional: true, type: :uint64, json_name: "finalRttMicro"
  field :packet_loss_pct, 5, proto3_optional: true, type: :double, json_name: "packetLossPct"
  field :total_hops, 6, type: :uint32, json_name: "totalHops"
  field :error_code, 7, type: :string, json_name: "errorCode"
end

defmodule Serviceradar.Edge.V1.MtrMplsLabelV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrMplsLabelV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :label, 1, type: :uint32
  field :experimental, 2, type: :uint32
  field :bottom_of_stack, 3, type: :bool, json_name: "bottomOfStack"
  field :ttl, 4, type: :uint32
end

defmodule Serviceradar.Edge.V1.MtrTraceHopV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrTraceHopV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :hop_number, 1, type: :uint32, json_name: "hopNumber"
  field :address, 2, type: :bytes
  field :hostname, 3, type: :string
  field :ecmp_addresses, 4, repeated: true, type: :bytes, json_name: "ecmpAddresses"

  field :mpls_labels, 5,
    repeated: true,
    type: Serviceradar.Edge.V1.MtrMplsLabelV1,
    json_name: "mplsLabels"

  field :asn, 6, type: :uint32
  field :asn_org, 7, type: :string, json_name: "asnOrg"
  field :sent, 8, type: :uint32
  field :received, 9, type: :uint32
  field :loss_pct, 10, type: :double, json_name: "lossPct"
  field :last_micro, 11, proto3_optional: true, type: :uint64, json_name: "lastMicro"
  field :avg_micro, 12, proto3_optional: true, type: :uint64, json_name: "avgMicro"
  field :min_micro, 13, proto3_optional: true, type: :uint64, json_name: "minMicro"
  field :max_micro, 14, proto3_optional: true, type: :uint64, json_name: "maxMicro"
  field :stddev_micro, 15, proto3_optional: true, type: :uint64, json_name: "stddevMicro"
  field :jitter_micro, 16, proto3_optional: true, type: :uint64, json_name: "jitterMicro"

  field :jitter_worst_micro, 17,
    proto3_optional: true,
    type: :uint64,
    json_name: "jitterWorstMicro"

  field :jitter_interarrival_micro, 18,
    proto3_optional: true,
    type: :uint64,
    json_name: "jitterInterarrivalMicro"
end

defmodule Serviceradar.Edge.V1.MtrTraceEventV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrTraceEventV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :trace_id, 1, type: :bytes, json_name: "traceId"
  field :event_id, 2, type: :bytes, json_name: "eventId"
  field :source, 3, type: Serviceradar.Edge.V1.SweepExecutionSource, enum: true
  field :sweep_execution_id, 4, type: :bytes, json_name: "sweepExecutionId"
  field :sweep_host_address, 5, type: :bytes, json_name: "sweepHostAddress"
  field :check_id, 6, type: :bytes, json_name: "checkId"
  field :command_id, 7, type: :bytes, json_name: "commandId"
  field :device_hint, 8, type: :bytes, json_name: "deviceHint"
  field :scan_run_id, 9, type: :bytes, json_name: "scanRunId"
  field :observed_at_unix_nano, 10, type: :int64, json_name: "observedAtUnixNano"
  field :attempted, 11, type: :bool
  field :outcome, 12, type: Serviceradar.Edge.V1.MtrOutcome, enum: true
  field :error_code, 13, type: :string, json_name: "errorCode"
  field :target, 14, type: :string
  field :resolved_address, 15, type: :bytes, json_name: "resolvedAddress"
  field :protocol, 16, type: Serviceradar.Edge.V1.TransportProtocol, enum: true
  field :ip_version, 17, type: :uint32, json_name: "ipVersion"
  field :packet_size, 18, type: :uint32, json_name: "packetSize"
  field :target_reached, 19, type: :bool, json_name: "targetReached"
  field :total_hops, 20, type: :uint32, json_name: "totalHops"
  field :hops, 21, repeated: true, type: Serviceradar.Edge.V1.MtrTraceHopV1
end

defmodule Serviceradar.Edge.V1.MtrTraceBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrTraceBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :network_scope_id, 1, type: :bytes, json_name: "networkScopeId"
  field :agent_id, 2, type: :bytes, json_name: "agentId"
  field :source, 3, type: Serviceradar.Edge.V1.SweepExecutionSource, enum: true
  field :batch_sequence, 4, type: :uint64, json_name: "batchSequence"
  field :traces, 5, repeated: true, type: Serviceradar.Edge.V1.MtrTraceEventV1
end

defmodule Serviceradar.Edge.V1.SweepExecutionEventV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepExecutionEventV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :execution_id, 1, type: :bytes, json_name: "executionId"
  field :execution_shard, 2, type: :uint32, json_name: "executionShard"
  field :assignment_epoch, 3, type: :uint64, json_name: "assignmentEpoch"
  field :execution_plan_id, 4, type: :bytes, json_name: "executionPlanId"
  field :execution_plan_sha256, 5, type: :bytes, json_name: "executionPlanSha256"
  field :target_range_id, 6, type: :bytes, json_name: "targetRangeId"
  field :kind, 7, type: Serviceradar.Edge.V1.SweepExecutionEventKind, enum: true
  field :emitted_at_unix_nano, 8, type: :int64, json_name: "emittedAtUnixNano"
  field :terminal_batch_sequence, 9, type: :uint64, json_name: "terminalBatchSequence"

  field :durable_through_batch_sequence, 16,
    type: :uint64,
    json_name: "durableThroughBatchSequence"

  field :hosts_observed, 10, type: :uint64, json_name: "hostsObserved"
  field :hosts_available, 11, type: :uint64, json_name: "hostsAvailable"
  field :expected_mtr_traces, 12, type: :uint64, json_name: "expectedMtrTraces"
  field :emitted_mtr_traces, 13, type: :uint64, json_name: "emittedMtrTraces"
  field :mtr_completion_digest, 14, type: :bytes, json_name: "mtrCompletionDigest"
  field :abort_reason, 15, type: :string, json_name: "abortReason"
end
