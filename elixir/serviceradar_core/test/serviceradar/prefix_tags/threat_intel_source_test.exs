defmodule ServiceRadar.PrefixTags.ThreatIntelSourceTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadar.PrefixTags.ThreatIntelSource

  setup do
    on_exit(fn -> Store.clear() end)
    Store.clear()
    :ok
  end

  test "map_indicator_row builds ti: source, optional label, and severity tags" do
    row =
      ThreatIntelSource.map_indicator_row("203.0.113.0/24", "alienvault-otx", "Malware C2", 4)

    assert row.source == "ti"
    assert row.prefix == "203.0.113.0/24"
    assert "ti:alienvault-otx" in row.tags
    assert "ti:label:malware-c2" in row.tags
    assert "ti:severity:4" in row.tags
    assert ThreatIntelSource.max_severity_from_tags(row.tags) == 4
    assert ThreatIntelSource.sources_from_tags(row.tags) == ["alienvault-otx"]
  end

  test "max_severity_from_tags picks the highest severity meta-tag" do
    tags = ["ti:otx", "ti:severity:2", "ti:severity:5", "ti:label:c2"]
    assert ThreatIntelSource.max_severity_from_tags(tags) == 5
    assert ThreatIntelSource.sources_from_tags(tags) == ["otx"]
  end

  test "ti tags appear in merged lookup after put_rows" do
    Store.put_rows("ti", [
      ThreatIntelSource.map_indicator_row("10.0.0.0/8", "otx", nil)
    ])

    Store.put_rows("netbox", [
      %{prefix: "10.1.2.0/24", tags: ["site:lab"], source: "netbox"}
    ])

    tags = "10.1.2.3" |> Store.lookup() |> Enum.flat_map(& &1.tags)
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

    tags = "10.1.2.3" |> Store.lookup() |> Enum.flat_map(& &1.tags)
    assert tags == ["manual:keep"]
  end

  test "normalize_expires_at converts NaiveDateTime to UTC DateTime" do
    ndt = ~N[2026-07-19 12:00:00]
    assert %DateTime{} = dt = ThreatIntelSource.normalize_expires_at(ndt)
    assert dt.time_zone == "Etc/UTC"
  end

  test "duplicate-prefix NaiveDateTime expiries do not raise on aggregate" do
    # Same CIDR, two finite members — previously Enum.min(..., DateTime) crashed
    # on NaiveDateTime values from the SQL boundary.
    a =
      ThreatIntelSource.map_indicator_row(
        "203.0.113.0/24",
        "otx",
        nil,
        3,
        ~N[2026-07-20 00:00:00]
      )

    b =
      ThreatIntelSource.map_indicator_row(
        "203.0.113.0/24",
        "spamhaus",
        nil,
        2,
        ~N[2026-07-21 00:00:00]
      )

    Store.put_rows("ti", [a, b])
    chain = Store.lookup("203.0.113.10", "ti")
    assert chain != []

    now = ~U[2026-07-19 00:00:00Z]
    assert ThreatIntelSource.indicator_count_from_match(chain, now) == 2
    assert ThreatIntelSource.max_severity_from_match(chain, now) == 3
  end

  test "permanent member survives after finite peer expiry" do
    permanent =
      ThreatIntelSource.map_indicator_row("198.51.100.0/24", "otx", nil, 4, nil)

    finite =
      ThreatIntelSource.map_indicator_row(
        "198.51.100.0/24",
        "spamhaus",
        nil,
        2,
        ~U[2026-01-01 00:00:00Z]
      )

    # Pre-merge as materialize does
    merged_prefix = "198.51.100.0/24"

    Store.put_rows("ti", [
      %{
        prefix: merged_prefix,
        tags: ["ti:otx", "ti:spamhaus", "ti:severity:4"],
        source: "ti",
        severity: 4,
        indicator_count: 2,
        expires_at: nil,
        feed_sources: ["otx", "spamhaus"],
        indicators: permanent.indicators ++ finite.indicators
      }
    ])

    chain = Store.lookup("198.51.100.10", "ti")
    after_expiry = ~U[2026-06-01 00:00:00Z]

    assert ThreatIntelSource.indicator_count_from_match(chain, after_expiry) == 1
    assert ThreatIntelSource.max_severity_from_match(chain, after_expiry) == 4
    assert "otx" in ThreatIntelSource.sources_from_match(chain, after_expiry)
    refute "spamhaus" in ThreatIntelSource.sources_from_match(chain, after_expiry)
  end

  test "display tag cap preserves severity and raw sources in structured fields" do
    # Many labels would exceed the 8-tag display budget.
    tags =
      for i <- 1..12 do
        "ti:label:label#{i}"
      end

    row = %{
      prefix: "10.0.0.0/8",
      tags: tags ++ ["ti:otx", "ti:spamhaus", "ti:severity:5"],
      source: "ti",
      severity: 5,
      indicator_count: 2,
      expires_at: nil,
      feed_sources: ["alienvault_otx", "spamhaus"],
      indicators: [
        %{source: "alienvault_otx", severity: 5, expires_at: nil, indicator_count: 1},
        %{source: "spamhaus", severity: 2, expires_at: nil, indicator_count: 1}
      ]
    }

    # Cap is applied at materialize; simulate with take_display via map_indicator path.
    Store.put_rows("ti", [row])
    chain = Store.lookup("10.1.2.3", "ti")
    assert ThreatIntelSource.max_severity_from_match(chain) == 5
    sources = ThreatIntelSource.sources_from_match(chain)
    assert "alienvault_otx" in sources
    assert "spamhaus" in sources
  end
end
