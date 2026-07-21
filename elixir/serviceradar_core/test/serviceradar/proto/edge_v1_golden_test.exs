defmodule ServiceRadar.Proto.EdgeV1GoldenTest do
  @moduledoc """
  Cross-language decode fixtures: decodes the canonical edge/v1 messages produced
  by the Go golden test (`proto/edge/v1/golden_test.go`) with the generated
  Elixir modules and asserts field parity. Proves the edge/v1 wire contract is
  byte- and semantics-compatible across Go and Elixir for the sweep batch, MTR
  trace, and ACK/session contracts. Regenerate the fixtures with
  `SR_UPDATE_GOLDEN=1 go test ./proto/edge/v1/`.
  """
  use ExUnit.Case, async: true

  alias Serviceradar.Edge.V1.EdgeResultAck
  alias Serviceradar.Edge.V1.MtrTraceEventV1
  alias Serviceradar.Edge.V1.SweepObservationBatchV1

  @testdata Path.expand("../../../../../proto/edge/v1/testdata", __DIR__)

  defp golden(name) do
    path = Path.join(@testdata, name)
    assert File.exists?(path), "missing golden #{name}; run: SR_UPDATE_GOLDEN=1 go test ./proto/edge/v1/"
    File.read!(path)
  end

  test "decodes the Go sweep observation batch with field parity" do
    batch = SweepObservationBatchV1.decode(golden("sweep_observation_batch_golden.bin"))

    assert byte_size(batch.execution_id) == 16
    assert batch.source == :SWEEP_EXECUTION_SOURCE_SWEEP_PROFILE

    [icmp_check, tcp_check] = batch.tested_checks
    assert icmp_check.mode == :SWEEP_MODE_ICMP
    assert tcp_check.mode == :SWEEP_MODE_TCP_CONNECT
    assert tcp_check.port == 443

    [host_a, host_b] = batch.hosts
    assert byte_size(host_a.address) == 4
    assert byte_size(host_b.address) == 16
    assert host_a.observed_at_delta_nano == 1500

    # Presence: measured value present, unsampled absent (nil).
    assert host_a.icmp.round_trip_micro == 1200
    assert host_b.mtr.final_rtt_micro == 2500
    assert host_b.mtr.packet_loss_pct == nil

    # Power-of-two mode bits (ICMP=1, TCP_CONNECT=4, MTR=8) are unambiguous.
    assert host_a.result_mode_bits == 5
    assert host_b.result_mode_bits == 8

    [open_port] = host_a.open_ports
    assert open_port.tested_check_index == 1
    assert open_port.service == "https"
  end

  test "decodes the Go MTR trace event including scheduled-check source and jitter" do
    trace = MtrTraceEventV1.decode(golden("mtr_trace_event_golden.bin"))

    assert trace.source == :SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK
    assert byte_size(trace.check_id) == 16
    assert trace.target_reached == true

    [hop0, hop1] = trace.hops
    assert hop0.jitter_worst_micro == 90
    assert hop0.jitter_interarrival_micro == 12
    # Presence: unsampled jitter absent on hop 1.
    assert hop1.jitter_worst_micro == nil
  end

  test "decodes the Go edge result ack with session binding and dispositions" do
    ack = EdgeResultAck.decode(golden("edge_result_ack_golden.bin"))

    assert byte_size(ack.session_nonce) == 16
    assert ack.resolved_through_sequence == 42
    assert length(ack.dispositions) == 2

    [_accepted, rejected] = ack.dispositions
    assert rejected.kind == :EDGE_RESULT_DISPOSITION_KIND_REJECTED
    assert rejected.rejection_code == "schema_version_unsupported"
  end
end
