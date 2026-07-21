defmodule ServiceRadarAgentGateway.EdgeRouteDigestTest do
  use ExUnit.Case, async: true

  alias Serviceradar.Edge.V1.EdgeResultFrame
  alias ServiceRadarAgentGateway.EdgeDigest
  alias ServiceRadarAgentGateway.EdgeRoute

  # Golden values produced by the Go reference cores go/pkg/edge/streamroute and
  # go/pkg/edge/gwpublish for the frame built below. If these drift, the Elixir
  # gateway and a Go consumer would disagree about subject/stream/msg-id.
  @golden_semantic_digest "6736b4da46dfe421ea839a490cd53b7f93234245875bd92834610470d638cb43"
  @golden_msg_id "17aba4bccc6d414bd710a975869b3005f1346b44633ef5a026bfc0ef65bcf625"
  @golden_partition 32
  @golden_subject "sr.edge.v1.sweep.bulk.p32.v1"
  @golden_stream "EDGE_SWEEP_BULK_V1"

  defp golden_frame do
    %EdgeResultFrame{
      spool_id: "spool-id-16bytes",
      sequence: 42,
      event_id: "event-id-16bytes",
      payload_kind: :EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1,
      schema_version: 1,
      payload_sha256: "0123456789abcdef0123456789abcdef",
      execution_id: "exec-id-16bytes!",
      execution_shard: 3,
      assignment_epoch: 5,
      authorization_kind: :EDGE_RESULT_AUTHORIZATION_KIND_SWEEP_ASSIGNMENT,
      authorization_context_id: "authctx-16bytes!",
      target_range_id: "range-id-16bytes",
      target_range_sha256: "aaaabbbbccccddddeeeeffff00001111",
      network_scope_id: "scope-id-16bytes",
      traffic_class: :EDGE_RESULT_TRAFFIC_CLASS_BULK,
      cost_model_version: 2,
      projected_row_count: 10,
      projected_write_bytes: 2048
    }
  end

  defp golden_identity, do: %{network_scope_id: "scope-id-16bytes", agent_id: "agent-id-16bytes"}

  test "semantic digest matches the Go reference core byte-for-byte" do
    assert Base.encode16(EdgeDigest.semantic_digest(golden_frame()), case: :lower) ==
             @golden_semantic_digest
  end

  test "msg id matches the Go reference core byte-for-byte" do
    assert EdgeDigest.msg_id(golden_identity(), golden_frame()) == @golden_msg_id
  end

  test "partition, subject, and stream match the Go reference core" do
    f = golden_frame()
    part = EdgeRoute.partition(f.network_scope_id)
    assert part == @golden_partition

    lane = EdgeRoute.lane_for(f.payload_kind, f.traffic_class)
    assert lane == :sweep_bulk
    assert EdgeRoute.data_subject(lane, part) == @golden_subject
    assert EdgeRoute.physical_stream(lane) == @golden_stream
  end

  test "semantic digest ignores placement/delivery coordinates" do
    a = golden_frame()
    b = %{a | spool_id: "other-spool-1616", sequence: 999, delivery_capability: "renewed", encoded_size: 123}
    assert EdgeDigest.semantic_digest(a) == EdgeDigest.semantic_digest(b)
  end

  test "lane routing across kind/class" do
    assert EdgeRoute.lane_for(
             :EDGE_RESULT_PAYLOAD_KIND_SWEEP_OBSERVATION_BATCH_V1,
             :EDGE_RESULT_TRAFFIC_CLASS_INTERACTIVE
           ) ==
             :sweep_interactive

    assert EdgeRoute.lane_for(:EDGE_RESULT_PAYLOAD_KIND_MTR_TRACE_BATCH_V1, :EDGE_RESULT_TRAFFIC_CLASS_BULK) ==
             :mtr_bulk

    assert EdgeRoute.lane_for(:EDGE_RESULT_PAYLOAD_KIND_SPOOL_LOSS_TOMBSTONE_V1, :EDGE_RESULT_TRAFFIC_CLASS_BULK) ==
             :recovery
  end

  test "subjects are unique across lanes and partitions and disjoint from DLQ" do
    for_result =
      for lane <- EdgeRoute.routable_lanes(), p <- 0..(EdgeRoute.num_partitions() - 1) do
        [EdgeRoute.data_subject(lane, p), EdgeRoute.dlq_subject(lane, p)]
      end

    subjects = List.flatten(for_result)

    assert length(subjects) == length(Enum.uniq(subjects))
    assert length(subjects) == length(EdgeRoute.routable_lanes()) * EdgeRoute.num_partitions() * 2
  end
end
