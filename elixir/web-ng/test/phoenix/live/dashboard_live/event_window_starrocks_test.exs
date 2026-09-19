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

    # The rollup gate probes for staleness through this same seam. Here the
    # view has kept up with the table it aggregates, so the window reads it.
    starrocks_query =
      with_freshness_probes("1999-06-15 23:00:00", "1999-06-15 23:30:00", fn sql ->
        # events_hourly already groups by hour and severity, so a whole-day
        # bucket re-aggregates from it with SUM(total_count).
        assert sql =~ "serviceradar.events_hourly"
        assert sql =~ "SUM(total_count)"
        refute sql =~ "COUNT(*)"
        refute sql =~ "platform.ocsf_events"
        refute sql =~ "time_bucket"

        # Buckets must be epoch-aligned. FROM_UNIXTIME/UNIX_TIMESTAMP round-trip
        # through the Frontend's session time zone, so on a non-UTC FE every
        # bucket key lands off the UTC multiples build_slice/3 generates and the
        # trend renders all zeros while the summary total stays non-zero.
        assert sql =~ "time_slice(`bucket`, INTERVAL 86400 SECOND)"
        refute sql =~ "UNIX_TIMESTAMP"
        refute sql =~ "FROM_UNIXTIME"

        send(self(), {:window_sql, sql})
        {:ok, %{rows: [["1999-03-18 00:00:00", 6, 11], ["1999-06-16 00:00:00", 2, 7]]}}
      end)

    assert {:ok, slice} = EventWindow.load(window, starrocks_query: starrocks_query)

    # The window starts exactly on 1999-03-18 00:00:00, so an epoch-aligned
    # bucket key lands on the first trend point; a key offset by the FE's time
    # zone leaves the trend at zero while the summary total stays 18.
    assert hd(slice.security_trend).total == 11
    assert hd(slice.security_trend).critical == 11
    assert slice.event_summary.total == 18
    assert slice.event_summary.fatal == 11
    assert slice.event_summary.low == 7
    assert_received {:window_sql, _sql}
  end

  test "a stale hourly view sends the whole-day window to the raw warehouse table",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:events])
    )

    window = Window.resolve("last_90d", "events", ~U[1999-06-16 00:00:00Z])

    # The view is a day and a half behind the table it aggregates.
    starrocks_query =
      with_freshness_probes("1999-06-14 00:00:00", "1999-06-15 12:00:00", fn sql ->
        assert sql =~ "serviceradar.events"
        assert sql =~ "COUNT(*)"
        refute sql =~ "events_hourly"
        refute sql =~ "platform.ocsf_events"
        send(self(), {:stale_window_sql, sql})
        {:ok, %{rows: [["1999-03-18 00:00:00", 6, 11]]}}
      end)

    assert {:ok, slice} = EventWindow.load(window, starrocks_query: starrocks_query)
    assert slice.event_summary.total == 11
    assert_received {:stale_window_sql, _sql}
  end

  test "a sub-hour event bucket stays on the raw warehouse table", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:events])
    )

    window = Window.resolve("last_1h", "events", ~U[1999-06-16 00:00:00Z])
    assert Window.event_bucket_seconds(window) == 60

    # A sub-hour bucket cannot re-aggregate from an hourly view, so it never
    # consults one -- and must not pay for a freshness probe either.
    starrocks_query = fn sql ->
      refute sql =~ "MAX(`bucket`)"
      assert sql =~ "time_slice(`time`, INTERVAL 60 SECOND)"
      assert sql =~ "COUNT(*)"
      refute sql =~ "events_hourly"
      send(self(), {:raw_window_sql, sql})
      {:ok, %{rows: [["1999-06-15 23:59:00", 6, 4]]}}
    end

    assert {:ok, slice} = EventWindow.load(window, starrocks_query: starrocks_query)
    assert slice.event_summary.total == 4
    assert_received {:raw_window_sql, _sql}
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

  # Wraps a window-SQL handler so the two high-water-mark probes the rollup
  # gate issues are answered in-band, the way the production seam delivers
  # them; every other statement reaches the handler untouched.
  defp with_freshness_probes(mv_max, raw_max, handler) do
    fn
      "SELECT MAX(`bucket`) FROM serviceradar.events_hourly" ->
        {:ok, %{rows: [[mv_max]], num_rows: 1}}

      "SELECT MAX(`time`) FROM serviceradar.events" ->
        {:ok, %{rows: [[raw_max]], num_rows: 1}}

      sql ->
        handler.(sql)
    end
  end
end
