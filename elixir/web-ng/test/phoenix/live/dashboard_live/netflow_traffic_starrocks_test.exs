defmodule ServiceRadarWebNGWeb.DashboardLive.NetflowTrafficStarRocksTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DashboardLive.Data.NetflowTraffic
  alias ServiceRadarWebNGWeb.DashboardLive.Window

  @moduletag :db_free

  test "short netflow windows compile an authorized in:flows SRQL query" do
    window = Window.resolve("last_1h", "netflow")
    query = NetflowTraffic.srql_query(window)

    assert query =~ ~r/^in:flows /
    assert query =~ "src_endpoint_ip"
    assert query =~ "dst_endpoint_ip"
    assert query =~ "bytes_total"
    refute query =~ "ocsf_network_activity"
  end

  test "default last_15m map window also uses SRQL rather than a 6h CNPG gate" do
    window = Window.resolve("last_15m", "netflow")
    assert window.seconds < 21_600
    assert NetflowTraffic.srql_query(window) =~ "in:flows"
  end
end
