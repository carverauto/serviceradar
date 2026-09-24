defmodule Serviceradar.Edge.V1.SweepMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.SweepMode",
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

  # SERVICERADAR EDGE ENUM PARITY (task 1.5) -- injected by scripts/patch_edge_enum_negatives.exs.
  # Go RETAINS an unknown/negative int32 enum as its integer and rejects it in the explicit
  # semantic validator; the generated `key/1`/`value/1` catchalls are guarded `tag >= 0` and
  # would RAISE, making Elixir reject a message Go accepts (last-one-wins: `-1` followed by a
  # valid value has the VALID effective value). Declared in the module BODY on purpose: the
  # Protobuf DSL appends its clauses at `@before_compile`, so these win for negatives while
  # every other tag falls through to the generated clauses unchanged.
  def key(tag) when is_integer(tag) and tag < 0, do: tag
  def value(tag) when is_integer(tag) and tag < 0, do: tag

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

  # SERVICERADAR EDGE ENUM PARITY (task 1.5) -- injected by scripts/patch_edge_enum_negatives.exs.
  # Go RETAINS an unknown/negative int32 enum as its integer and rejects it in the explicit
  # semantic validator; the generated `key/1`/`value/1` catchalls are guarded `tag >= 0` and
  # would RAISE, making Elixir reject a message Go accepts (last-one-wins: `-1` followed by a
  # valid value has the VALID effective value). Declared in the module BODY on purpose: the
  # Protobuf DSL appends its clauses at `@before_compile`, so these win for negatives while
  # every other tag falls through to the generated clauses unchanged.
  def key(tag) when is_integer(tag) and tag < 0, do: tag
  def value(tag) when is_integer(tag) and tag < 0, do: tag

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

  # SERVICERADAR EDGE ENUM PARITY (task 1.5) -- injected by scripts/patch_edge_enum_negatives.exs.
  # Go RETAINS an unknown/negative int32 enum as its integer and rejects it in the explicit
  # semantic validator; the generated `key/1`/`value/1` catchalls are guarded `tag >= 0` and
  # would RAISE, making Elixir reject a message Go accepts (last-one-wins: `-1` followed by a
  # valid value has the VALID effective value). Declared in the module BODY on purpose: the
  # Protobuf DSL appends its clauses at `@before_compile`, so these win for negatives while
  # every other tag falls through to the generated clauses unchanged.
  def key(tag) when is_integer(tag) and tag < 0, do: tag
  def value(tag) when is_integer(tag) and tag < 0, do: tag

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

  # SERVICERADAR EDGE ENUM PARITY (task 1.5) -- injected by scripts/patch_edge_enum_negatives.exs.
  # Go RETAINS an unknown/negative int32 enum as its integer and rejects it in the explicit
  # semantic validator; the generated `key/1`/`value/1` catchalls are guarded `tag >= 0` and
  # would RAISE, making Elixir reject a message Go accepts (last-one-wins: `-1` followed by a
  # valid value has the VALID effective value). Declared in the module BODY on purpose: the
  # Protobuf DSL appends its clauses at `@before_compile`, so these win for negatives while
  # every other tag falls through to the generated clauses unchanged.
  def key(tag) when is_integer(tag) and tag < 0, do: tag
  def value(tag) when is_integer(tag) and tag < 0, do: tag

  field :MTR_OUTCOME_UNSPECIFIED, 0
  field :MTR_OUTCOME_REACHED, 1
  field :MTR_OUTCOME_TARGET_UNREACHABLE, 2
  field :MTR_OUTCOME_PROBE_FAILED, 3
  field :MTR_OUTCOME_TIMED_OUT, 4
  field :MTR_OUTCOME_NOT_ADMITTED, 5
  field :MTR_OUTCOME_QUARANTINED, 6
  field :MTR_OUTCOME_SCHEDULER_LOST, 7
end

defmodule Serviceradar.Edge.V1.MtrCompletionDisposition do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.MtrCompletionDisposition",
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

  field :MTR_COMPLETION_DISPOSITION_UNSPECIFIED, 0
  field :MTR_COMPLETION_DISPOSITION_TRACE_ALLOCATED, 1
  field :MTR_COMPLETION_DISPOSITION_NOT_ADMITTED, 2
  field :MTR_COMPLETION_DISPOSITION_PROBE_FAILED, 3
  field :MTR_COMPLETION_DISPOSITION_QUARANTINED, 4
  field :MTR_COMPLETION_DISPOSITION_SCHEDULER_LOST, 5
end

defmodule Serviceradar.Edge.V1.SweepResultFormat do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.SweepResultFormat",
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

  field :SWEEP_RESULT_FORMAT_UNSPECIFIED, 0
  field :SWEEP_RESULT_FORMAT_EDGE_RECORDS_V1, 1
end

defmodule Serviceradar.Edge.V1.SweepExecutionSource do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.SweepExecutionSource",
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

  # SERVICERADAR EDGE ENUM PARITY (task 1.5) -- injected by scripts/patch_edge_enum_negatives.exs.
  # Go RETAINS an unknown/negative int32 enum as its integer and rejects it in the explicit
  # semantic validator; the generated `key/1`/`value/1` catchalls are guarded `tag >= 0` and
  # would RAISE, making Elixir reject a message Go accepts (last-one-wins: `-1` followed by a
  # valid value has the VALID effective value). Declared in the module BODY on purpose: the
  # Protobuf DSL appends its clauses at `@before_compile`, so these win for negatives while
  # every other tag falls through to the generated clauses unchanged.
  def key(tag) when is_integer(tag) and tag < 0, do: tag
  def value(tag) when is_integer(tag) and tag < 0, do: tag

  field :SWEEP_EXECUTION_EVENT_KIND_UNSPECIFIED, 0
  field :SWEEP_EXECUTION_EVENT_KIND_START, 1
  field :SWEEP_EXECUTION_EVENT_KIND_PROGRESS, 2
  field :SWEEP_EXECUTION_EVENT_KIND_COMPLETED, 3
  field :SWEEP_EXECUTION_EVENT_KIND_ABORTED, 4
end

defmodule Serviceradar.Edge.V1.SweepAssignmentState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.edge.v1.SweepAssignmentState",
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

  field :SWEEP_ASSIGNMENT_STATE_UNSPECIFIED, 0
  field :SWEEP_ASSIGNMENT_STATE_OPEN, 1
  field :SWEEP_ASSIGNMENT_STATE_COMPLETED, 2
  field :SWEEP_ASSIGNMENT_STATE_ABORTED, 3
  field :SWEEP_ASSIGNMENT_STATE_LOST, 4
  field :SWEEP_ASSIGNMENT_STATE_EXPIRED, 5
  field :SWEEP_ASSIGNMENT_STATE_SUPERSEDED, 6
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

  field :first_seen_delta_nano, 4,
    proto3_optional: true,
    type: :sint64,
    json_name: "firstSeenDeltaNano"

  field :last_seen_delta_nano, 5,
    proto3_optional: true,
    type: :sint64,
    json_name: "lastSeenDeltaNano"

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
  field :sweep_host_address, 3, type: :bytes, json_name: "sweepHostAddress"
  field :device_hint, 4, type: :bytes, json_name: "deviceHint"
  field :observed_at_unix_nano, 5, type: :int64, json_name: "observedAtUnixNano"
  field :attempted, 6, type: :bool
  field :outcome, 7, type: Serviceradar.Edge.V1.MtrOutcome, enum: true
  field :error_code, 8, type: :string, json_name: "errorCode"
  field :target, 9, type: :string
  field :resolved_address, 10, type: :bytes, json_name: "resolvedAddress"
  field :protocol, 11, type: Serviceradar.Edge.V1.TransportProtocol, enum: true
  field :ip_version, 12, type: :uint32, json_name: "ipVersion"
  field :packet_size, 13, type: :uint32, json_name: "packetSize"
  field :target_reached, 14, type: :bool, json_name: "targetReached"
  field :total_hops, 15, type: :uint32, json_name: "totalHops"
  field :hops, 16, repeated: true, type: Serviceradar.Edge.V1.MtrTraceHopV1
end

defmodule Serviceradar.Edge.V1.MtrSweepContextV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrSweepContextV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :sweep_execution_id, 1, type: :bytes, json_name: "sweepExecutionId"
  field :execution_shard, 2, type: :uint32, json_name: "executionShard"
  field :assignment_epoch, 3, type: :uint64, json_name: "assignmentEpoch"
  field :target_range_id, 4, type: :bytes, json_name: "targetRangeId"
end

defmodule Serviceradar.Edge.V1.MtrScheduledCheckContextV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrScheduledCheckContextV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :check_id, 1, type: :bytes, json_name: "checkId"
end

defmodule Serviceradar.Edge.V1.MtrAdHocContextV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrAdHocContextV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :scan_run_id, 1, type: :bytes, json_name: "scanRunId"
end

defmodule Serviceradar.Edge.V1.MtrCommandContextV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrCommandContextV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :command_id, 1, type: :bytes, json_name: "commandId"
end

defmodule Serviceradar.Edge.V1.MtrTraceBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrTraceBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:correlation, 0)

  field :network_scope_id, 1, type: :bytes, json_name: "networkScopeId"
  field :agent_id, 2, type: :bytes, json_name: "agentId"
  field :source, 3, type: Serviceradar.Edge.V1.SweepExecutionSource, enum: true
  field :batch_sequence, 4, type: :uint64, json_name: "batchSequence"
  field :traces, 5, repeated: true, type: Serviceradar.Edge.V1.MtrTraceEventV1
  field :sweep, 6, type: Serviceradar.Edge.V1.MtrSweepContextV1, oneof: 0

  field :scheduled_check, 7,
    type: Serviceradar.Edge.V1.MtrScheduledCheckContextV1,
    json_name: "scheduledCheck",
    oneof: 0

  field :ad_hoc, 8, type: Serviceradar.Edge.V1.MtrAdHocContextV1, json_name: "adHoc", oneof: 0
  field :command, 9, type: Serviceradar.Edge.V1.MtrCommandContextV1, oneof: 0
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

  field :durable_through_batch_sequence, 10,
    type: :uint64,
    json_name: "durableThroughBatchSequence"

  field :hosts_observed, 11, type: :uint64, json_name: "hostsObserved"
  field :hosts_available, 12, type: :uint64, json_name: "hostsAvailable"
  field :expected_mtr_summaries, 13, type: :uint64, json_name: "expectedMtrSummaries"
  field :emitted_mtr_summaries, 14, type: :uint64, json_name: "emittedMtrSummaries"
  field :expected_mtr_traces, 15, type: :uint64, json_name: "expectedMtrTraces"
  field :emitted_mtr_traces, 16, type: :uint64, json_name: "emittedMtrTraces"
  field :mtr_completion_digest_version, 17, type: :uint32, json_name: "mtrCompletionDigestVersion"
  field :mtr_completion_digest, 18, type: :bytes, json_name: "mtrCompletionDigest"
  field :plan_root_sha256, 19, type: :bytes, json_name: "planRootSha256"
  field :abort_reason, 21, type: :string, json_name: "abortReason"
end

defmodule Serviceradar.Edge.V1.SweepMtrExpectationV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepMtrExpectationV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :ordinal_count, 1, type: :uint64, json_name: "ordinalCount"
  field :ordinal_range_commitment, 2, type: :bytes, json_name: "ordinalRangeCommitment"

  field :plan_ordinal_offset, 3,
    proto3_optional: true,
    type: :uint64,
    json_name: "planOrdinalOffset"
end

defmodule Serviceradar.Edge.V1.SweepAssignmentRecordV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.SweepAssignmentRecordV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :producer_assignment_id, 1, type: :bytes, json_name: "producerAssignmentId"
  field :execution_id, 2, type: :bytes, json_name: "executionId"
  field :execution_plan_id, 3, type: :bytes, json_name: "executionPlanId"
  field :execution_plan_sha256, 4, type: :bytes, json_name: "executionPlanSha256"
  field :execution_shard, 5, type: :uint32, json_name: "executionShard"
  field :assignment_epoch, 6, type: :uint64, json_name: "assignmentEpoch"
  field :record_sequence, 7, type: :uint64, json_name: "recordSequence"
  field :authored_at_unix_nano, 8, type: :int64, json_name: "authoredAtUnixNano"
  field :target_range_id, 9, type: :bytes, json_name: "targetRangeId"
  field :target_range_sha256, 10, type: :bytes, json_name: "targetRangeSha256"
  field :lease_id, 11, type: :bytes, json_name: "leaseId"
  field :fence_token, 12, type: :uint64, json_name: "fenceToken"
  field :lease_expires_at_unix_nano, 13, type: :int64, json_name: "leaseExpiresAtUnixNano"
  field :state, 14, type: Serviceradar.Edge.V1.SweepAssignmentState, enum: true
  field :superseded_by_assignment_id, 15, type: :bytes, json_name: "supersededByAssignmentId"
  field :terminal_batch_sequence, 16, type: :uint64, json_name: "terminalBatchSequence"

  field :mtr_expectation, 17,
    type: Serviceradar.Edge.V1.SweepMtrExpectationV1,
    json_name: "mtrExpectation"

  field :check_set_sha256, 18, type: :bytes, json_name: "checkSetSha256"
  field :availability_policy_id, 19, type: :bytes, json_name: "availabilityPolicyId"
  field :network_scope_id, 20, type: :bytes, json_name: "networkScopeId"
  field :authenticated_agent_id, 21, type: :bytes, json_name: "authenticatedAgentId"
  field :production_scope_id, 22, type: :bytes, json_name: "productionScopeId"
  field :scope_sha256, 23, type: :bytes, json_name: "scopeSha256"
  field :contract_bundle_sha256, 24, type: :bytes, json_name: "contractBundleSha256"
  field :run_id, 25, type: :bytes, json_name: "runId"

  field :source_identity, 26,
    type: Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1,
    json_name: "sourceIdentity"

  field :compiled_assignment_id, 27, type: :bytes, json_name: "compiledAssignmentId"
  field :compiled_assignment_sha256, 28, type: :bytes, json_name: "compiledAssignmentSha256"
end

defmodule Serviceradar.Edge.V1.CompiledSweepAssignmentV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.CompiledSweepAssignmentV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :compiled_assignment_id, 1, type: :bytes, json_name: "compiledAssignmentId"

  field :compiled_assignment_body_sha256, 2,
    type: :bytes,
    json_name: "compiledAssignmentBodySha256"

  field :compiled_assignment_sha256, 19, type: :bytes, json_name: "compiledAssignmentSha256"
  field :digest_version, 3, type: :uint32, json_name: "digestVersion"
  field :execution_plan_id, 4, type: :bytes, json_name: "executionPlanId"
  field :execution_plan_sha256, 5, type: :bytes, json_name: "executionPlanSha256"
  field :target_range_id, 6, type: :bytes, json_name: "targetRangeId"
  field :target_range_sha256, 7, type: :bytes, json_name: "targetRangeSha256"
  field :network_scope_id, 8, type: :bytes, json_name: "networkScopeId"
  field :authenticated_agent_id, 9, type: :bytes, json_name: "authenticatedAgentId"
  field :execution_shard, 10, type: :uint32, json_name: "executionShard"
  field :assignment_epoch, 11, type: :uint64, json_name: "assignmentEpoch"
  field :producer_assignment_id, 20, type: :bytes, json_name: "producerAssignmentId"
  field :execution_id, 21, type: :bytes, json_name: "executionId"
  field :config_generation, 12, type: :uint64, json_name: "configGeneration"

  field :result_format, 13,
    type: Serviceradar.Edge.V1.SweepResultFormat,
    json_name: "resultFormat",
    enum: true

  field :check_set_sha256, 14, type: :bytes, json_name: "checkSetSha256"

  field :traffic_class, 15,
    type: Serviceradar.Edge.V1.EdgeRecordTrafficClass,
    json_name: "trafficClass",
    enum: true

  field :not_before_unix_nano, 16, type: :int64, json_name: "notBeforeUnixNano"
  field :expires_at_unix_nano, 17, type: :int64, json_name: "expiresAtUnixNano"

  field :collection_capability, 18,
    type: Serviceradar.Edge.V1.EdgeSignedCapabilityV1,
    json_name: "collectionCapability"
end

defmodule Serviceradar.Edge.V1.TargetRangeV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.TargetRangeV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :range_id, 1, type: :bytes, json_name: "rangeId"
  field :range_sha256, 2, type: :bytes, json_name: "rangeSha256"
  field :cidr, 3, type: :string
  field :first_address, 4, type: :string, json_name: "firstAddress"
  field :last_address, 5, type: :string, json_name: "lastAddress"
  field :target_count, 6, type: :uint64, json_name: "targetCount"
  field :check_set_sha256, 7, type: :bytes, json_name: "checkSetSha256"
  field :availability_policy_id, 8, type: :bytes, json_name: "availabilityPolicyId"
  field :mtr_admission_budget, 9, type: :uint64, json_name: "mtrAdmissionBudget"
  field :mtr_ordinal_count, 10, proto3_optional: true, type: :uint64, json_name: "mtrOrdinalCount"
end

defmodule Serviceradar.Edge.V1.ScheduledPlanPageV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.ScheduledPlanPageV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :execution_plan_id, 1, type: :bytes, json_name: "executionPlanId"
  field :page_index, 2, type: :uint32, json_name: "pageIndex"
  field :page_count, 3, type: :uint32, json_name: "pageCount"
  field :prev_page_sha256, 4, type: :bytes, json_name: "prevPageSha256"
  field :page_sha256, 5, type: :bytes, json_name: "pageSha256"
  field :check_set_sha256, 6, type: :bytes, json_name: "checkSetSha256"
  field :digest_version, 7, type: :uint32, json_name: "digestVersion"
  field :ranges, 8, repeated: true, type: Serviceradar.Edge.V1.TargetRangeV1
end

defmodule Serviceradar.Edge.V1.ScheduledPlanHeaderV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.ScheduledPlanHeaderV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :execution_plan_id, 1, type: :bytes, json_name: "executionPlanId"
  field :execution_plan_sha256, 2, type: :bytes, json_name: "executionPlanSha256"
  field :page_count, 3, type: :uint32, json_name: "pageCount"
  field :total_target_count, 4, type: :uint64, json_name: "totalTargetCount"
  field :plan_root_sha256, 5, type: :bytes, json_name: "planRootSha256"
  field :digest_version, 6, type: :uint32, json_name: "digestVersion"
  field :check_set_sha256, 7, type: :bytes, json_name: "checkSetSha256"
  field :availability_policy_id, 8, type: :bytes, json_name: "availabilityPolicyId"
  field :network_scope_id, 10, type: :bytes, json_name: "networkScopeId"
  field :mtr_ordinal_range_commitment, 11, type: :bytes, json_name: "mtrOrdinalRangeCommitment"
end
