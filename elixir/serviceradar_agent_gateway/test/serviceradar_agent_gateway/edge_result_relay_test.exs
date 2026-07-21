defmodule ServiceRadarAgentGateway.EdgeResultRelayTest do
  use ExUnit.Case, async: true

  alias Serviceradar.Edge.V1.EdgeResultFrame
  alias Serviceradar.Edge.V1.EdgeResultLaneOpen
  alias ServiceRadarAgentGateway.EdgePrefix
  alias ServiceRadarAgentGateway.EdgeResultRelay

  # Fake publisher: returns a canned result per subject class (data vs dlq),
  # driven by the test process dictionary, and records each publish.
  defmodule FakePublisher do
    @moduledoc false
    def publish(subject, payload, headers) do
      send(self(), {:published, subject, payload, headers})

      if String.contains?(subject, ".dlq.") do
        Process.get(:dlq_result, {:ok, %{stream: "DLQ", seq: 1}})
      else
        Process.get(:data_result, {:ok, %{stream: "S", seq: 1}})
      end
    end

    def retryable?(class), do: class in [:capacity, :timeout]
  end

  defp identity, do: %{network_scope_id: "scope-id-16bytes", agent_id: "agent-id-16bytes"}

  defp session, do: EdgeResultRelay.new(identity(), publisher: FakePublisher)

  defp opened_session do
    lo = %EdgeResultLaneOpen{
      spool_id: "spool-id-16bytes",
      session_nonce: "nonce-16-bytes!!",
      first_unresolved_sequence: 1
    }

    {:ok, _ack, s} = EdgeResultRelay.open(session(), lo)
    s
  end

  defp frame(seq) do
    %EdgeResultFrame{
      spool_id: "spool-id-16bytes",
      sequence: seq,
      event_id: "event-id-16byte#{rem(seq, 10)}",
      payload_kind: :EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1,
      payload: "inner-payload-bytes",
      network_scope_id: "scope-id-16bytes",
      traffic_class: :EDGE_RESULT_TRAFFIC_CLASS_BULK
    }
  end

  describe "EdgePrefix" do
    test "advances only across a contiguous durable run" do
      p = EdgePrefix.new(1)
      {:ok, p} = EdgePrefix.record(p, 1, :accepted)
      {:ok, p} = EdgePrefix.record(p, 3, :accepted)
      assert EdgePrefix.resolved_through(p) == 1
      {:ok, p} = EdgePrefix.record(p, 2, :rejected)
      assert EdgePrefix.resolved_through(p) == 3
    end

    test "rejects a non-durable status and a below-base sequence" do
      p = EdgePrefix.new(10)
      assert {:error, :not_durable} = EdgePrefix.record(p, 10, :pending)
      assert {:error, :below_base} = EdgePrefix.record(p, 9, :accepted)
    end
  end

  describe "open/2" do
    test "returns a lane-open ack bound to the spool and nonce with granted credits" do
      lo = %EdgeResultLaneOpen{spool_id: "spool-id-16bytes", session_nonce: "nonce-16-bytes!!"}
      assert {:ok, ack, s} = EdgeResultRelay.open(session(), lo)
      assert ack.spool_id == "spool-id-16bytes"
      assert ack.session_nonce == "nonce-16-bytes!!"
      assert ack.granted_frame_credits > 0
      assert s.established?
    end

    test "rejects a handshake missing spool id or nonce" do
      assert {:error, :missing_spool_id} =
               EdgeResultRelay.open(session(), %EdgeResultLaneOpen{session_nonce: "n"})

      assert {:error, :missing_nonce} =
               EdgeResultRelay.open(session(), %EdgeResultLaneOpen{spool_id: "spool-id-16bytes"})
    end
  end

  describe "frame/2" do
    test "a primary-stream PubAck resolves the frame and advances the prefix" do
      Process.put(:data_result, {:ok, %{stream: "EDGE_SWEEP_BULK_V1", seq: 100}})
      {:ok, ack, s} = EdgeResultRelay.frame(opened_session(), frame(1))

      assert ack.resolved_through_sequence == 1
      assert [%{sequence: 1, kind: :EDGE_RESULT_DISPOSITION_KIND_ACCEPTED}] = ack.dispositions
      assert EdgePrefix.resolved_through(s.prefix) == 1
      # Published the inner payload bytes verbatim to the data subject.
      assert_received {:published, "sr.edge.v1.sweep.bulk.p32.v1", "inner-payload-bytes", headers}
      assert {"Nats-Expected-Stream", "EDGE_SWEEP_BULK_V1"} in headers
    end

    test "a retryable failure withholds (no disposition, no advance)" do
      Process.put(:data_result, {:error, :capacity})
      {:ok, result, s} = EdgeResultRelay.frame(opened_session(), frame(1))
      assert result == :withhold
      assert EdgePrefix.resolved_through(s.prefix) == 0
    end

    test "a permanent failure dead-letters, then resolves rejected on DLQ PubAck" do
      Process.put(:data_result, {:error, :permanent})
      Process.put(:dlq_result, {:ok, %{stream: "EDGE_DLQ_SWEEP_BULK_V1", seq: 5}})
      {:ok, ack, s} = EdgeResultRelay.frame(opened_session(), frame(1))

      assert [%{sequence: 1, kind: :EDGE_RESULT_DISPOSITION_KIND_REJECTED, rejection_code: "permanent"}] =
               ack.dispositions

      assert EdgePrefix.resolved_through(s.prefix) == 1
      assert_received {:published, "sr.edge.v1.sweep.bulk.p32.v1", _, _}
      assert_received {:published, "sr.edge.v1.dlq.sweep.bulk.p32.v1", _, _}
    end

    test "a permanent failure whose DLQ is unavailable withholds" do
      Process.put(:data_result, {:error, :permanent})
      Process.put(:dlq_result, {:error, :capacity})
      {:ok, result, s} = EdgeResultRelay.frame(opened_session(), frame(1))
      assert result == :withhold
      assert EdgePrefix.resolved_through(s.prefix) == 0
    end

    test "rejects a frame bound to a different spool" do
      f = %{frame(1) | spool_id: "other-spool-1616"}
      assert {:error, :spool_mismatch} = EdgeResultRelay.frame(opened_session(), f)
    end

    test "rejects frames before the lane is established" do
      assert {:error, :not_established} = EdgeResultRelay.frame(session(), frame(1))
    end
  end
end
