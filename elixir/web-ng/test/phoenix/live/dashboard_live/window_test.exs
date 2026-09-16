defmodule ServiceRadarWebNGWeb.DashboardLive.WindowTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DashboardLive.EventWindow
  alias ServiceRadarWebNGWeb.DashboardLive.Window

  @moduletag :db_free

  test "independent defaults reject unknown windows and pin exact request bounds" do
    assert Window.normalize("unbounded", "netflow") == "last_15m"
    assert Window.normalize(nil, "events") == "last_24h"
    now = ~U[2032-04-02 12:34:00Z]
    window = Window.resolve("last_90d", "events", now)
    assert window.end == now
    assert DateTime.diff(window.end, window.start) == 90 * 86_400
    assert Window.event_bucket_seconds(window) == 86_400
    assert Window.query_time(window) =~ ",2032-04-02T12:34:00Z]"
  end

  test "ninety days has all daily buckets and matching full-window totals" do
    window = Window.resolve("last_90d", "events", ~U[2032-04-02 12:00:00Z])

    query = fn sql, params ->
      assert params == [window.start, window.end, 86_400]
      assert sql =~ "time < $2"
      assert sql =~ "rollup_start >= rollup_end"
      refute sql =~ "LIMIT 48"
      {:ok, %{rows: [[~U[2032-02-01 00:00:00Z], 6, 11], [~U[2032-04-02 00:00:00Z], 2, 7]]}}
    end

    assert {:ok, slice} = EventWindow.load(window, query: query)
    assert length(slice.security_trend) == 91
    assert hd(slice.security_trend).range_start == window.start
    assert List.last(slice.security_trend).bucket_end == window.end
    assert Enum.sum(Enum.map(slice.security_trend, & &1.total)) == 18
    assert slice.event_summary.total == 18
    assert slice.event_summary.fatal == 11
    assert slice.event_summary.low == 7
  end

  test "stale window successes and exits cannot replace newer selections" do
    current = make_ref()
    stale = make_ref()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        window_requests: %{"events" => current, "netflow" => current},
        events_window: "last_90d",
        netflow_window: "last_7d"
      }
    }

    for kind <- ["events", "netflow"], result <- [{:ok, %{events_window: "last_15m"}}, {:exit, :timeout}] do
      assert {:noreply, ^socket} =
               ServiceRadarWebNGWeb.DashboardLive.Index.handle_async({:dashboard_window, kind, stale}, result, socket)
    end
  end

  test "short windows use bounded raw counts and surface errors" do
    window = Window.resolve("last_15m", "events", ~U[2032-04-02 12:34:00Z])

    query = fn sql, [_start, _end, 60] ->
      refute sql =~ "ocsf_events_hourly_stats"
      assert sql =~ "time >= $1 AND time < $2"
      {:error, :query_failed}
    end

    assert {:error, :query_failed} = EventWindow.load(window, query: query)
  end
end
