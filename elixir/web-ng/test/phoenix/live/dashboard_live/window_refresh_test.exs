defmodule ServiceRadarWebNGWeb.DashboardLive.WindowRefreshTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DashboardLive.WindowRefresh

  @moduletag :db_free

  test "starting a reload leaves the panel's data and loaded state alone" do
    # Clearing here emptied the map, zeroed its tiles, swapped the events chart
    # for its empty state and flipped the KPI cards, for as long as the query
    # took -- which read as a page refresh on every window change.
    for kind <- ["netflow", "events"] do
      assert WindowRefresh.on_start(kind) == {%{}, []}
    end
  end

  test "a failed reload clears the panel, because the select already names the new window" do
    assert {%{traffic_links: [], traffic_links_json: "[]", flow_summary: %{}}, [netflow: true]} =
             WindowRefresh.on_failure("netflow")

    assert {%{security_trend: [], event_summary: %{}}, [security_events: true]} =
             WindowRefresh.on_failure("events")
  end

  test "a panel is busy only while its own reload is in flight" do
    requests = %{"netflow" => make_ref()}

    assert WindowRefresh.busy?(requests, "netflow")
    refute WindowRefresh.busy?(requests, "events")
    refute WindowRefresh.busy?(%{}, "netflow")
    refute WindowRefresh.busy?(nil, "netflow")
  end
end
