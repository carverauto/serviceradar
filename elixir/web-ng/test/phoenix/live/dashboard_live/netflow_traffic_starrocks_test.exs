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

  test "the map asks for every conversation, not a byte-ranked handful" do
    query = NetflowTraffic.srql_query(Window.resolve("last_90d", "netflow"))

    # limit:120 kept only the heaviest conversations, which all end in the same
    # few cloud regions and stack into a handful of visible arcs.
    refute query =~ "limit:120"
    assert query =~ "limit:#{NetflowTraffic.conversation_limit()}"
    # A memory guard far above any window a deployment holds today, not a
    # product limit on what the map may show.
    assert NetflowTraffic.conversation_limit() >= 250_000
  end

  describe "collapse_arcs/2" do
    @home [-93.4, 44.9]
    @ashburn [-77.5, 39.0]
    @london [-0.1, 51.5]

    defp link(src, dst, from, to, bytes, opts \\ []) do
      %{
        id: "flow-x",
        src_endpoint_ip: src,
        dst_endpoint_ip: dst,
        geo_from: from,
        geo_to: to,
        geo_mapped: not is_nil(from) and not is_nil(to),
        target_geo_label: Keyword.get(opts, :label, dst),
        bytes: bytes,
        bytes_total: bytes,
        magnitude: bytes,
        packets: div(bytes, 100),
        packets_total: div(bytes, 100),
        flow_count: Keyword.get(opts, :flows, 1),
        color: [0, 0, 0, 0]
      }
    end

    test "conversations between the same two places become one arc carrying their sum" do
      links = [
        link("192.0.2.10", "198.51.100.1", @home, @ashburn, 5_000, flows: 3, label: "Ashburn, US"),
        link("192.0.2.11", "198.51.100.2", @home, @ashburn, 9_000, flows: 4, label: "Ashburn, US (heaviest)"),
        link("192.0.2.12", "198.51.100.3", @home, @ashburn, 1_000, flows: 1),
        link("192.0.2.10", "203.0.113.7", @home, @london, 400, flows: 2)
      ]

      assert [ashburn, london] = NetflowTraffic.collapse_arcs(links)

      assert ashburn.geo_to == @ashburn
      assert ashburn.bytes == 15_000
      assert ashburn.magnitude == 15_000
      assert ashburn.packets == 150
      assert ashburn.flow_count == 8
      assert ashburn.conversation_count == 3
      # The heaviest member names the arc.
      assert ashburn.target_geo_label == "Ashburn, US (heaviest)"

      assert london.geo_to == @london
      assert london.bytes == 400
      assert london.conversation_count == 1
    end

    test "no arc is dropped, however many conversations share the busiest one" do
      busy = for n <- 1..200, do: link("192.0.2.10", "198.51.100.#{n}", @home, @ashburn, 10_000 - n)
      places = for n <- 1..1_500, do: link("192.0.2.10", "203.0.113.7", @home, [n / 10, 51.5], 5)

      arcs = NetflowTraffic.collapse_arcs(busy ++ places)

      # Byte-ranked top 120 was 120 copies of the Ashburn line and nothing else.
      assert length(arcs) == 1_501
      assert Enum.find(arcs, &(&1.geo_to == @ashburn)).conversation_count == 200
      assert arcs |> Enum.map(& &1.bytes) |> Enum.sum() == Enum.sum(Enum.map(busy ++ places, & &1.bytes))
    end

    test "direction is part of the arc" do
      arcs =
        NetflowTraffic.collapse_arcs([
          link("192.0.2.10", "198.51.100.1", @home, @ashburn, 100),
          link("198.51.100.1", "192.0.2.10", @ashburn, @home, 70)
        ])

      assert length(arcs) == 2
    end

    test "links that cannot be placed are all kept and counted, heaviest first" do
      unmapped = for n <- 1..10, do: link("192.0.2.#{n}", "192.0.2.200", nil, nil, n * 10)
      mapped = link("192.0.2.10", "198.51.100.1", @home, @ashburn, 1)

      assert [%{geo_mapped: true} | rest] = NetflowTraffic.collapse_arcs(unmapped ++ [mapped])
      assert Enum.map(rest, & &1.bytes) == Enum.to_list(100..10//-10)
      assert Enum.all?(rest, &(&1.conversation_count == 1))
      assert NetflowTraffic.collapse_arcs([]) == []
    end
  end
end
