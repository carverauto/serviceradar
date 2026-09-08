defmodule ServiceRadarWebNGWeb.ObservabilityPathsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.ObservabilityPaths

  @moduletag :db_free

  test "path encodes tab in the route and query as intent params" do
    assert ObservabilityPaths.path("events") == "/observability/events"

    assert ObservabilityPaths.path("events", %{q: "in:events time:last_7d"}) ==
             "/observability/events?q=in%3Aevents+time%3Alast_7d"

    # Position / legacy noise never lands in the shareable URL.
    assert ObservabilityPaths.path("logs", %{
             q: "in:logs",
             tab: "logs",
             limit: 20,
             cursor: "abc",
             page: 2
           }) == "/observability/logs?q=in%3Alogs"
  end

  test "events_range_path emits the fixed Events query" do
    assert ObservabilityPaths.events_range_path(
             ~U[2026-08-27 10:00:00Z],
             ~U[2026-08-27 12:59:59.999999Z]
           ) ==
             "/observability/events?q=in%3Aevents+time%3A%5B2026-08-27T10%3A00%3A00Z%2C2026-08-27T12%3A59%3A59.999999Z%5D+sort%3Atime%3Adesc+limit%3A20"
  end

  test "tab_from_path reads path segments" do
    assert ObservabilityPaths.tab_from_path("/observability/events") == "events"
    assert ObservabilityPaths.tab_from_path("/observability/netflows?q=x") == "netflows"
    assert ObservabilityPaths.tab_from_path("/logs") == "logs"
    assert ObservabilityPaths.tab_from_path("/observability/health") == nil
  end

  test "legacy_tab_redirect rewrites bare tab query to path" do
    assert ObservabilityPaths.legacy_tab_redirect("/observability", %{"tab" => "events", "q" => "in:events"}) ==
             "/observability/events?q=in%3Aevents"

    assert ObservabilityPaths.legacy_tab_redirect("/observability/events", %{"tab" => "events", "q" => "x"}) ==
             "/observability/events?q=x"

    assert ObservabilityPaths.legacy_tab_redirect("/observability/events", %{"q" => "x"}) == nil
  end

  test "resolve_tab prefers live_action then path then query" do
    assert ObservabilityPaths.resolve_tab(:events, "/observability", %{}, "logs") == "events"
    assert ObservabilityPaths.resolve_tab(:index, "/observability/traces", %{}, "logs") == "traces"
    assert ObservabilityPaths.resolve_tab(:index, "/observability", %{"tab" => "alerts"}, "logs") == "alerts"
    assert ObservabilityPaths.resolve_tab(:index, "/observability", %{}, "logs") == "logs"
  end
end
