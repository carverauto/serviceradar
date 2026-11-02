defmodule Serviceradar.Edge.V1.AgentScheduledMtrTraceBatchV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.AgentScheduledMtrTraceBatchV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :traces, 1, repeated: true, type: Serviceradar.Edge.V1.AgentScheduledMtrTraceV1
end

defmodule Serviceradar.Edge.V1.AgentScheduledMtrTraceV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.AgentScheduledMtrTraceV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :trace, 1, type: Serviceradar.Edge.V1.MtrTraceEventV1
  field :check_id, 2, type: :string, json_name: "checkId"
  field :check_name, 3, type: :string, json_name: "checkName"
  field :device_id, 4, type: :string, json_name: "deviceId"
  field :sweep_group_id, 5, type: :bytes, json_name: "sweepGroupId"
  field :execution_id, 6, type: :bytes, json_name: "executionId"
  field :command_id, 7, type: :string, json_name: "commandId"

  field :execution_source, 8,
    type: Serviceradar.Edge.V1.SweepExecutionSource,
    json_name: "executionSource",
    enum: true

  field :probed_hops, 9, type: :uint32, json_name: "probedHops"
  field :last_responding_hop, 10, type: :uint32, json_name: "lastRespondingHop"
  field :tcp_port, 11, type: :uint32, json_name: "tcpPort"
  field :tcp_probe_mode, 12, type: :string, json_name: "tcpProbeMode"
  field :error_message, 13, type: :string, json_name: "errorMessage"

  field :tcp_handshake, 14,
    type: Serviceradar.Edge.V1.MtrTcpHandshakeDiagnosticsV1,
    json_name: "tcpHandshake"

  field :hop_diagnostics, 15,
    repeated: true,
    type: Serviceradar.Edge.V1.MtrHopReplyDiagnosticsV1,
    json_name: "hopDiagnostics"
end

defmodule Serviceradar.Edge.V1.MtrTcpHandshakeDiagnosticsV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrTcpHandshakeDiagnosticsV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :ttl, 1, type: :uint32
  field :attempts, 2, type: :uint32
  field :syn_sent, 3, type: :uint32, json_name: "synSent"
  field :synack_received, 4, type: :uint32, json_name: "synackReceived"
  field :rst_received, 5, type: :uint32, json_name: "rstReceived"
  field :unanswered, 6, type: :uint32
  field :syn_drop_pct, 7, type: :double, json_name: "synDropPct"
  field :syn_retransmits, 8, type: :uint32, json_name: "synRetransmits"
  field :answered_after_retx, 9, type: :uint32, json_name: "answeredAfterRetx"
  field :ack_mismatch, 10, type: :uint32, json_name: "ackMismatch"
  field :synack_duplicates, 11, type: :uint32, json_name: "synackDuplicates"
  field :rtt_min_us, 12, type: :int64, json_name: "rttMinUs"
  field :rtt_avg_us, 13, type: :int64, json_name: "rttAvgUs"
  field :rtt_max_us, 14, type: :int64, json_name: "rttMaxUs"
  field :server_response_us, 15, type: :int64, json_name: "serverResponseUs"
  field :has_server_response_us, 16, type: :bool, json_name: "hasServerResponseUs"
end

defmodule Serviceradar.Edge.V1.MtrHopReplyDiagnosticsV1 do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.edge.v1.MtrHopReplyDiagnosticsV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :hop_number, 1, type: :uint32, json_name: "hopNumber"
  field :has_unreachable_code, 2, type: :bool, json_name: "hasUnreachableCode"
  field :unreachable_code, 3, type: :uint32, json_name: "unreachableCode"
  field :reply_time_exceeded, 4, type: :uint32, json_name: "replyTimeExceeded"
  field :reply_unreachable, 5, type: :uint32, json_name: "replyUnreachable"
  field :reply_synack, 6, type: :uint32, json_name: "replySynack"
  field :reply_rst, 7, type: :uint32, json_name: "replyRst"
end
