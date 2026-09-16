defmodule ServiceRadarWebNGWeb.DashboardLive.EventWindowStarRocksTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNGWeb.DashboardLive.EventWindow
  alias ServiceRadarWebNGWeb.DashboardLive.Window
  alias ServiceRadarWebNGWeb.Stats

  @moduletag :db_free

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end)

    %{prev: prev}
  end

  test "event window queries StarRocks hourly events when events are cut over", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:events])
    )

    window = Window.resolve("last_90d", "events", ~U[1999-06-16 00:00:00Z])

    starrocks_query = fn sql ->
      assert sql =~ "serviceradar.events_hourly"
      refute sql =~ "platform.ocsf_events"
      refute sql =~ "time_bucket"
      send(self(), {:window_sql, sql})
      {:ok, %{rows: [["1999-03-18 00:00:00", 6, 11], ["1999-06-16 00:00:00", 2, 7]]}}
    end

    assert {:ok, slice} = EventWindow.load(window, starrocks_query: starrocks_query)
    assert slice.event_summary.total == 18
    assert slice.event_summary.fatal == 11
    assert slice.event_summary.low == 7
    assert_received {:window_sql, _sql}
  end

  test "logs rollup status uses StarRocks raw bounds when logs are cut over", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:logs])
    )

    query = fn sql ->
      assert sql =~ "serviceradar.logs"
      refute sql =~ "platform.logs"
      refute sql =~ "logs_severity_stats_5m"
      send(self(), {:logs_sql, sql})
      {:ok, %{rows: [["1999-06-15 12:00:00", "1999-06-14 12:00:00"]]}}
    end

    status = Stats.logs_rollup_status(query: query)
    assert status.healthy?
    assert status.rollup_present?
    assert status.raw_latest_timestamp == ~U[1999-06-15 12:00:00Z]
    assert status.raw_window_start_timestamp == ~U[1999-06-14 12:00:00Z]
    assert_received {:logs_sql, _sql}
  end
end
