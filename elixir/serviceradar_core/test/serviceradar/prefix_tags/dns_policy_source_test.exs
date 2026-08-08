defmodule ServiceRadar.PrefixTags.DnsPolicySourceTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.DnsPolicySource
  alias ServiceRadar.PrefixTags.Store

  setup do
    on_exit(fn -> Store.clear() end)
    Store.clear()
    :ok
  end

  test "map_client_row tags IPv4 clients as /32 with policy slug" do
    row = DnsPolicySource.map_client_row("192.168.2.10", "hagezi-pro")

    assert row.source == "dns-policy"
    assert row.prefix == "192.168.2.10/32"
    assert "dns-policy:hit" in row.tags
    assert "dns-policy:hagezi-pro" in row.tags
  end

  test "map_client_row tags IPv6 clients as /128" do
    row = DnsPolicySource.map_client_row("2001:db8::1", "blocklist")
    assert row.prefix == "2001:db8::1/128"
  end

  test "dns-policy tags merge into store lookup" do
    Store.put_rows("dns-policy", [
      DnsPolicySource.map_client_row("10.0.0.5", "hagezi-pro")
    ])

    tags = "10.0.0.5" |> Store.lookup() |> Enum.flat_map(& &1.tags)
    assert "dns-policy:hit" in tags
    assert "dns-policy:hagezi-pro" in tags
  end

  test "query parser returns latest durable RPZ event time" do
    snapshot_at = ~N[2026-07-18 08:00:00]

    parsed =
      DnsPolicySource.parse_query_result(%{
        rows: [
          ["192.0.2.10", "hagezi-pro", snapshot_at],
          ["192.0.2.10", "malware-block", snapshot_at]
        ]
      })

    assert parsed.snapshot_at == ~U[2026-07-18 08:00:00Z]
    assert [%{prefix: "192.0.2.10/32", source: "dns-policy", tags: tags}] = parsed.rows
    assert "dns-policy:hagezi-pro" in tags
    assert "dns-policy:malware-block" in tags
  end

  test "query parser accepts an empty lookback result without inventing freshness" do
    assert %{rows: [], snapshot_at: nil} =
             DnsPolicySource.parse_query_result(%{rows: [[nil, nil, nil]]})
  end
end
