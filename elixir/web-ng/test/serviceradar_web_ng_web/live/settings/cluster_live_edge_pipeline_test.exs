defmodule ServiceRadarWebNGWeb.Settings.ClusterLiveEdgePipelineTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.PipelineStats
  alias ServiceRadarWebNGWeb.Settings.ClusterLive.EdgePipeline

  @moduletag :db_free

  @sweep "serviceradar.sweep.observation/1"
  @metrics "serviceradar.metrics.batch/1"

  setup do
    if Process.whereis(PipelineStats), do: stop_supervised!(PipelineStats)
    :ok
  end

  test "the panel renders one row per output contract from the nodes' PipelineStats" do
    start_supervised!(PipelineStats)

    PipelineStats.record(:gateway_admitted, {"serviceradar.sweep.observation", 1}, 4)
    PipelineStats.record(:projected, {"serviceradar.sweep.observation", 1}, 3)
    PipelineStats.record(:failed, {"serviceradar.sweep.observation", 1})
    PipelineStats.record(:dead_lettered, {"serviceradar.sweep.observation", 1})
    PipelineStats.record(:gateway_refused, nil, 2)

    PipelineStats.record_consumer(
      %{
        subject_class: "edge_record_dlq",
        stream: "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK",
        durable: "serviceradar-event-writer-edge-record-dlq"
      },
      %{num_pending: 0, num_ack_pending: 0, num_redelivered: 0},
      %{state: %{messages: 5}}
    )

    stats = EdgePipeline.stats_for_mount(true)
    assert stats.available

    # Every catalogued contract has a row, so a family that is not flowing reads as zero.
    labels = Enum.map(stats.contracts, & &1.contract)
    catalog = Enum.map(ContractCatalog.entries(), fn %{ref: {id, version}} -> "#{id}/#{version}" end)
    assert Enum.take(labels, length(catalog)) == catalog

    for family <- [
          @sweep,
          "serviceradar.netprobe.flow_attribution/1",
          "serviceradar.mapper.devices.batch/1",
          "serviceradar.mapper.interfaces.batch/1",
          "serviceradar.mapper.topology.batch/1"
        ] do
      assert family in labels
    end

    assert "unattributed" in labels

    html = render_component(&EdgePipeline.panel/1, stats: stats)

    assert html =~ "Edge Pipeline"
    assert html =~ ~s(id="cluster-edge-contract-serviceradar-sweep-observation-1")
    assert html =~ ~s(id="cluster-edge-contract-serviceradar-metrics-batch-1")
    assert html =~ ~s(id="cluster-edge-contract-unattributed")
    assert html =~ "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK"

    sweep = Enum.find(stats.contracts, &(&1.contract == @sweep))

    assert %{gateway_admitted: 4, projected: 3, failed: 1, dead_lettered: 1, gateway_refused: 0} =
             sweep

    assert EdgePipeline.format_age(sweep.last_projected_at_ms, stats.now_ms) =~ "s ago"
    assert %{gateway_admitted: 0, projected: 0} = Enum.find(stats.contracts, &(&1.contract == @metrics))
    assert [%{stream_messages: 5}] = stats.consumers
  end

  test "node snapshots are summed per contract and each durable keeps its latest sample" do
    node = fn name, counts, last_projected, sampled_at, pending ->
      %{
        node: name,
        contracts: [
          @sweep
          |> PipelineStats.empty_counts()
          |> Map.merge(counts)
          |> Map.put(:last_projected_at_ms, last_projected)
        ],
        consumers: [
          %{
            subject_class: "edge_record",
            stream: "TELEMETRY_EDGE_RECORD_V1_BULK",
            durable: "serviceradar-event-writer-edge-record",
            pending: pending,
            ack_pending: 0,
            redelivered: 0,
            stream_messages: 10,
            sampled_at_ms: sampled_at
          }
        ]
      }
    end

    stats =
      EdgePipeline.merge(
        [
          node.("gateway-a", %{gateway_admitted: 5, gateway_withheld: 1}, nil, 1_000, 7),
          node.("core-a", %{projected: 4, projector_refused: 1}, 50_000, 2_000, 2),
          node.("core-b", %{projected: 1}, 40_000, 1_500, 9)
        ],
        110_000
      )

    assert stats.nodes == ["gateway-a", "core-a", "core-b"]

    assert %{
             gateway_admitted: 5,
             gateway_withheld: 1,
             projected: 5,
             projector_refused: 1,
             last_projected_at_ms: 50_000
           } = Enum.find(stats.contracts, &(&1.contract == @sweep))

    assert [%{pending: 2, sampled_at_ms: 2_000}] = stats.consumers
    assert EdgePipeline.format_age(50_000, stats.now_ms) == "1m ago"
    assert EdgePipeline.format_age(nil, stats.now_ms) == "never"
  end

  test "a node whose stream poll failed does not hide another node's dead-letter depth" do
    sample = fn name, pending, messages, sampled_at ->
      %{
        node: name,
        contracts: [],
        consumers: [
          %{
            subject_class: "edge_record_dlq",
            stream: "TELEMETRY_EDGE_RECORD_DLQ_V1_BULK",
            durable: "serviceradar-event-writer-edge-record-dlq",
            pending: pending,
            ack_pending: 0,
            redelivered: 0,
            stream_messages: messages,
            sampled_at_ms: sampled_at
          }
        ]
      }
    end

    stats = EdgePipeline.merge([sample.("core-a", 1, 12, 1_000), sample.("core-b", 2, nil, 2_000)], 3_000)
    assert [%{pending: 2, stream_messages: 12, sampled_at_ms: 2_000}] = stats.consumers

    unknown = EdgePipeline.merge([sample.("core-b", 2, nil, 2_000)], 3_000)
    assert [%{stream_messages: nil}] = unknown.consumers

    html = render_component(&EdgePipeline.panel/1, stats: unknown)
    assert html =~ "unknown"
  end

  test "the disconnected mount and a cluster with no reporting node render the unavailable state" do
    start_supervised!(PipelineStats)
    PipelineStats.record(:projected, {"serviceradar.sweep.observation", 1})

    for stats <- [EdgePipeline.stats_for_mount(false), EdgePipeline.merge([], 0)] do
      refute stats.available
      html = render_component(&EdgePipeline.panel/1, stats: stats)
      assert html =~ "cluster-edge-pipeline-unavailable"
      refute html =~ "cluster-edge-pipeline-contracts"
    end
  end
end
