defmodule ServiceRadarWebNGWeb.LogLive.NetflowSankeyTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.LogLive.NetflowSankey

  @moduletag :db_free

  defp label(443), do: "HTTPS:443"
  defp label(port), do: "PORT:#{port}"

  defp row(src, port, dst, bytes, prefix \\ 24) do
    %{
      "src_cidr_#{prefix}" => src,
      "dst_endpoint_port" => port,
      "dst_cidr_#{prefix}" => dst,
      "total_bytes" => bytes
    }
  end

  test "the warehouse groups by subnet and ranks over the whole window" do
    query = NetflowSankey.query("in:flows time:last_90d src_ip:192.0.2.10", 24)

    assert String.starts_with?(query, "in:flows time:last_90d src_ip:192.0.2.10 stats:")
    assert query =~ "by src_cidr:24, dst_endpoint_port, dst_cidr:24"
    assert query =~ "sort:total_bytes:desc"
    assert query =~ "limit:#{NetflowSankey.max_edges()}"
    # Grouping by address and collapsing afterwards ranked only the rows that
    # had been fetched, not the window.
    refute query =~ "src_endpoint_ip"

    assert NetflowSankey.query("in:flows time:last_1h", 16) =~ "by src_cidr:16, dst_endpoint_port, dst_cidr:16"
  end

  test "rows become labelled edges, heaviest first" do
    rows = [
      row("198.51.100.0", 443, "192.0.2.0", 500.0),
      row("192.0.2.0", 8443, "203.0.113.0", 9_000.0)
    ]

    assert [first, second] = NetflowSankey.edges(rows, 24, &label/1)

    assert first == %{src: "192.0.2.0/24", mid: "PORT:8443", port: 8443, dst: "203.0.113.0/24", bytes: 9_000}
    assert second == %{src: "198.51.100.0/24", mid: "HTTPS:443", port: 443, dst: "192.0.2.0/24", bytes: 500}
  end

  test "forty distinct subnets and forty distinct ports all reach the diagram" do
    # The defect: a cut to the top 8 ports and top 10 subnets, applied after a
    # cut to 200 address rows, meant this could never exceed a handful.
    rows = for n <- 1..60, do: row("192.0.#{n}.0", 1_000 + n, "198.51.#{n}.0", 10_000 - n)

    edges = NetflowSankey.edges(rows, 24, &label/1)

    assert length(edges) == 40
    assert edges |> Enum.map(& &1.src) |> Enum.uniq() |> length() == 40
    assert edges |> Enum.map(& &1.mid) |> Enum.uniq() |> length() == 40
    assert hd(edges).bytes == 9_999
  end

  test "rows that would draw nothing are dropped" do
    rows = [
      row(nil, 443, "192.0.2.0", 10),
      row("Unknown", 443, "192.0.2.0", 10),
      row("192.0.2.0", 443, "", 10),
      row("192.0.2.0", 443, "198.51.100.0", 0),
      row("192.0.2.0", 443, "198.51.100.0", "12.0")
    ]

    assert [%{bytes: 12, src: "192.0.2.0/24"}] = NetflowSankey.edges(rows, 24, &label/1)
    assert NetflowSankey.edges([], 24, &label/1) == []
  end

  test "a /16 view reads the /16 columns, and an already-qualified subnet is left alone" do
    rows = [row("10.0.0.0", 53, "192.168.0.0/16", 7, 16)]

    assert [%{src: "10.0.0.0/16", dst: "192.168.0.0/16"}] = NetflowSankey.edges(rows, 16, &label/1)
  end

  test "totals_by sums each column's nodes, heaviest first" do
    edges =
      NetflowSankey.edges(
        [
          row("192.0.2.0", 443, "198.51.100.0", 100),
          row("192.0.2.0", 53, "203.0.113.0", 30),
          row("198.51.100.0", 443, "203.0.113.0", 5)
        ],
        24,
        &label/1
      )

    assert NetflowSankey.totals_by(edges, :src) == [{"192.0.2.0/24", 130}, {"198.51.100.0/24", 5}]
    assert NetflowSankey.totals_by(edges, :mid) == [{"HTTPS:443", 105}, {"PORT:53", 30}]
    assert NetflowSankey.totals_by(edges, :dst) == [{"198.51.100.0/24", 100}, {"203.0.113.0/24", 35}]
  end
end
