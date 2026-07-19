defmodule ServiceRadar.PrefixTags.ThreatIntelSourceTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.PrefixTags.ThreatIntelSource

  setup do
    on_exit(fn -> Store.clear() end)
    Store.clear()
    :ok
  end

  test "map_indicator_row builds ti: source and optional label tags" do
    row = ThreatIntelSource.map_indicator_row("203.0.113.0/24", "alienvault-otx", "Malware C2")

    assert row.source == "ti"
    assert row.prefix == "203.0.113.0/24"
    assert "ti:alienvault-otx" in row.tags
    assert "ti:label:malware-c2" in row.tags
  end

  test "ti tags appear in merged lookup after put_rows" do
    Store.put_rows("ti", [
      ThreatIntelSource.map_indicator_row("10.0.0.0/8", "otx", nil)
    ])

    Store.put_rows("netbox", [
      %{prefix: "10.1.2.0/24", tags: ["site:lab"], source: "netbox"}
    ])

    tags = Store.lookup("10.1.2.3") |> Enum.flat_map(& &1.tags)
    assert "site:lab" in tags
    assert "ti:otx" in tags
  end

  test "clearing ti source drops tags without touching other sources" do
    Store.put_rows("ti", [
      ThreatIntelSource.map_indicator_row("10.0.0.0/8", "otx", nil)
    ])

    Store.put_rows("manual", [
      %{prefix: "10.0.0.0/8", tags: ["manual:keep"], source: "manual"}
    ])

    Store.clear("ti")

    tags = Store.lookup("10.1.2.3") |> Enum.flat_map(& &1.tags)
    assert tags == ["manual:keep"]
  end
end
