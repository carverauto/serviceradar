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

    RuntimeMetrics.record(:status, :state, %{
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

  test "connected mount renders the live core lanes and no unlisted lane" do
    start_supervised!({RuntimeMetrics, interval_ms: 60_000, publish_opts: [request: fn _, _, _ -> :ok end]})

    RuntimeMetrics.record(:status, :state, %{
      pending_count: 3,
      pending_bytes: 6_144,
      in_flight_count: 1,
      in_flight_bytes: 2_048
    })

    RuntimeMetrics.record(:status, :admitted, %{count: 5})
    RuntimeMetrics.record(:sync, :incomplete_run, %{count: 1})
    # Published, never listed.
    RuntimeMetrics.record(:retained_plugin_result, :state, %{pending_count: 9})
    RuntimeMetrics.record(:other_results, :admitted, %{count: 2})

    stats = ClusterLive.ingestion_stats_for_mount(true)
    assert stats.available == true
    assert ClusterLive.ingestion_card_value(stats) == "3 queued / 1 active"
    assert ClusterLive.ingestion_card_variant(stats) == "warning"

    html =
      render_component(&ClusterLive.ingestion_lanes_panel/1,
        ingestion_stats: stats
      )

    assert html =~ "Core Admission Lanes"
    assert html =~ "cluster-ingestion-lanes-table"
    assert html =~ "cluster-ingestion-lane-status"
    assert html =~ "8.0 KiB / 32.0 MiB"
    assert html =~ "cluster-ingestion-lane-sync"
    assert html =~ "/dashboard/result-ingestion-lanes"

    for unlisted <- ~w(retained_plugin_result other_results service_state) do
      refute html =~ "cluster-ingestion-lane-#{unlisted}"
    end
  end

  test "the ingestion card follows current queue depth and does not latch lifetime totals" do
    idle_after_failures = %{
      available: true,
      totals: %{
        pending_count: 0,
        in_flight_count: 0,
        not_accepted_total: 1,
        incomplete_run_total: 1,
        crash_total: 1,
        rejected_total: 4,
        timeout_total: 2
      }
    }

    assert ClusterLive.ingestion_card_variant(idle_after_failures) == "success"
    assert ClusterLive.ingestion_card_value(idle_after_failures) == "0 queued / 0 active"

    backlog = put_in(idle_after_failures.totals.pending_count, 3)
    assert ClusterLive.ingestion_card_variant(backlog) == "warning"
    assert ClusterLive.ingestion_card_value(backlog) == "3 queued / 0 active"
  end

  test "merged lane rows compare cluster occupancy with summed capacity" do
    lane = fn pending, max_items, pending_bytes, max_bytes ->
      %{
        lane: :sync,
        pending_count: pending,
        pending_bytes: pending_bytes,
        in_flight_count: 1,
        in_flight_bytes: 1_024,
        max_items: max_items,
        max_bytes: max_bytes,
        admitted_total: 1,
        rejected_total: 0,
        accepted_total: 1,
        not_accepted_total: 0,
        timeout_total: 0,
        crash_total: 0,
        incomplete_run_total: 0,
        queue_wait_ms: 5,
        execution_ms: 50,
        acknowledgement_ms: 80
      }
    end

    one = lane.(20, 32, 1_024, 65_536)

    assert [^one] =
             ClusterLive.merge_ingestion_lane_snapshots([%{node: "core-a", lanes: [one]}])

    snapshots =
      for node <- ["core-a", "core-b", "core-c"] do
        %{node: node, lanes: [lane.(20, 32, 1_024, 65_536)]}
      end

    [merged] = ClusterLive.merge_ingestion_lane_snapshots(snapshots)
    assert merged.pending_count == 60
    assert merged.in_flight_count == 3
    assert merged.in_flight_bytes == 3_072
    assert merged.max_items == 96
    assert merged.pending_bytes == 3_072
    assert merged.max_bytes == 196_608
    assert merged.admitted_total == 3
    assert merged.queue_wait_ms == 5
    assert merged.execution_ms == 50
    assert merged.acknowledgement_ms == 80

    html =
      render_component(&ClusterLive.ingestion_lanes_panel/1,
        ingestion_stats: %{
          available: true,
          nodes: ["core-a", "core-b", "core-c"],
          lanes: [merged],
          totals: %{pending_count: 60, in_flight_count: 3}
        }
      )

    assert html =~ "cluster-ingestion-lane-sync"
    assert html =~ "60 / 96"
    assert html =~ "6.0 KiB / 192.0 KiB"
    refute html =~ "60 / 32"
  end
end
