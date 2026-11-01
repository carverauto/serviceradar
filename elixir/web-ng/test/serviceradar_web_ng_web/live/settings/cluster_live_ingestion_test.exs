defmodule ServiceRadarWebNGWeb.Settings.ClusterLiveIngestionTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadarWebNGWeb.Settings.ClusterLive.Index, as: ClusterLive

  @moduletag :db_free

  setup do
    if Process.whereis(RuntimeMetrics) do
      stop_supervised!(RuntimeMetrics)
    end

    :ok
  end

  test "disconnected mount returns unavailable ingestion stats without reading RuntimeMetrics" do
    start_supervised!({RuntimeMetrics, interval_ms: 60_000, publish_opts: [request: fn _, _, _ -> :ok end]})

    RuntimeMetrics.record(:retained_plugin_result, :state, %{
      pending_count: 4,
      pending_bytes: 8_192,
      in_flight_count: 2,
      in_flight_bytes: 4_096
    })

    stats = ClusterLive.ingestion_stats_for_mount(false)
    assert stats.available == false
    assert stats.lanes == []
    assert ClusterLive.ingestion_card_value(stats) == "Unavailable"
    assert ClusterLive.ingestion_card_variant(stats) == "warning"

    html =
      render_component(&ClusterLive.ingestion_lanes_panel/1,
        ingestion_stats: stats
      )

    assert html =~ "cluster-ingestion-lanes-unavailable"
    assert html =~ "No core ingestion coordinator is reachable to report runtime lane metrics."
    assert html =~ "/dashboard/result-ingestion-lanes"
    refute html =~ "cluster-ingestion-lanes-table"
  end

  test "connected mount returns unavailable state when RuntimeMetrics is not running" do
    stats = ClusterLive.ingestion_stats_for_mount(true)
    assert stats.available == false
    assert stats.lanes == []
    assert ClusterLive.ingestion_card_value(stats) == "Unavailable"

    html =
      render_component(&ClusterLive.ingestion_lanes_panel/1,
        ingestion_stats: stats
      )

    assert html =~ "cluster-ingestion-lanes-unavailable"
    refute html =~ "cluster-ingestion-lanes-table"
  end

  test "connected mount renders populated lane stats including retained_plugin_result queued work" do
    start_supervised!({RuntimeMetrics, interval_ms: 60_000, publish_opts: [request: fn _, _, _ -> :ok end]})

    RuntimeMetrics.record(:retained_plugin_result, :state, %{
      pending_count: 3,
      pending_bytes: 6_144,
      in_flight_count: 1,
      in_flight_bytes: 2_048
    })

    RuntimeMetrics.record(:retained_plugin_result, :admitted, %{count: 5})
    RuntimeMetrics.record(:retained_plugin_result, :rejected, %{count: 2, reason: :count_full})
    RuntimeMetrics.record(:retained_plugin_result, :completion, %{count: 1, outcome: :not_accepted})
    RuntimeMetrics.record(:sync, :incomplete_run, %{count: 1})

    stats = ClusterLive.ingestion_stats_for_mount(true)
    assert stats.available == true
    assert ClusterLive.ingestion_card_value(stats) == "3 queued / 1 active"
    assert ClusterLive.ingestion_card_variant(stats) == "error"

    html =
      render_component(&ClusterLive.ingestion_lanes_panel/1,
        ingestion_stats: stats
      )

    assert html =~ "cluster-ingestion-lanes-table"
    assert html =~ "cluster-ingestion-lane-retained_plugin_result"
    assert html =~ "3 / 32"
    assert html =~ "8.0 KiB / 64.0 MiB"
    assert html =~ "cluster-ingestion-lane-sync"
    assert html =~ "/dashboard/result-ingestion-lanes"
  end
end
