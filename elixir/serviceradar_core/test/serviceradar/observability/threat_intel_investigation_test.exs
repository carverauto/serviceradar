defmodule ServiceRadar.Observability.ThreatIntelInvestigationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ThreatIntelEvidence
  alias ServiceRadar.Observability.ThreatIntelInvestigation

  test "rejects non-IP input before querying" do
    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "not-an-ip")

    assert {:error, :invalid_ip} = ThreatIntelInvestigation.indicators_for_ip(:unused, "")

    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "10.0.0.0/8")

    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "1; DROP TABLE")

    assert {:error, :invalid_ip} = ThreatIntelInvestigation.indicators_for_ip(:unused, nil)
  end

  describe "flow_summary/3" do
    @summaries %{
      "192.0.2.10" => %{match_count: 2, max_severity: 3, sources: ["feed_a"]},
      "198.51.100.20" => %{match_count: 1, max_severity: 7, sources: ["feed_a", "feed_b"]}
    }

    test "folds both matched endpoints into one flow summary" do
      summary = ThreatIntelInvestigation.flow_summary(@summaries, "192.0.2.10", "198.51.100.20")

      assert summary.match_count == 3
      assert summary.max_severity == 7
      assert summary.sources == ["feed_a", "feed_b"]
      assert summary.source == @summaries["192.0.2.10"]
      assert summary.destination == @summaries["198.51.100.20"]
    end

    test "reports only the matched side and nil when neither side matches" do
      summary = ThreatIntelInvestigation.flow_summary(@summaries, "203.0.113.5", "198.51.100.20")

      assert summary.match_count == 1
      assert is_nil(summary.source)
      assert ThreatIntelInvestigation.flow_summary(@summaries, "203.0.113.5", nil) == nil
    end

    test "counts an endpoint once when it is both source and destination" do
      summary = ThreatIntelInvestigation.flow_summary(@summaries, "192.0.2.10", "192.0.2.10")

      assert summary.match_count == 2
      assert is_nil(summary.destination)
    end
  end

  test "endpoint lookup rejects an unbounded address list before querying" do
    ips = for n <- 0..500, do: "2001:db8::#{Integer.to_string(n, 16)}"

    assert {:error, {:too_many_endpoints, 501, 500}} =
             ThreatIntelInvestigation.endpoint_summaries(:unused, ips)

    assert {:ok, %{}} =
             ThreatIntelInvestigation.endpoint_summaries(:unused, [
               "",
               nil,
               "not-an-ip",
               "Unknown"
             ])
  end

  describe "keyset cursors" do
    alias ServiceRadar.Observability.ThreatIntelInvestigation.Keyset

    test "a page cursor decodes back to the last row's key" do
      at = ~U[2026-01-02 03:04:05.123456Z]

      rows = [
        %{at: ~U[2026-01-02 04:00:00Z], ip: "192.0.2.1"},
        %{at: at, ip: "192.0.2.2"},
        %{at: at, ip: "192.0.2.3"}
      ]

      assert %{rows: [_, _], next_cursor: cursor} = Keyset.page(rows, 2, &[&1.at, &1.ip])
      assert {:ok, [^at, "192.0.2.2"]} = Keyset.decode(cursor, [:datetime, :string])
      assert %{next_cursor: nil} = Keyset.page(rows, 3, &[&1.at, &1.ip])
    end

    test "a malformed or mismatched cursor is an explicit error" do
      cursor = Keyset.encode([5, "192.0.2.1"])

      assert {:ok, nil} = Keyset.decode("", [:integer, :string])
      assert {:error, :invalid_cursor} = Keyset.decode("%%%", [:integer, :string])
      assert {:error, :invalid_cursor} = Keyset.decode(cursor, [:datetime, :string])
      assert {:error, :invalid_cursor} = Keyset.decode(cursor, [:integer])

      assert {:error, :invalid_cursor} =
               Keyset.decode(Keyset.encode(["x", "not-a-uuid"]), [:string, :uuid])
    end
  end

  test "indicator filters accept only addresses PostgreSQL takes as cidr" do
    for accepted <- [
          "198.51.100.0/24",
          "198.51.100.10/32",
          "198.51.100.10",
          "2001:db8::/32",
          "0.0.0.0/0"
        ] do
      assert {:ok, ^accepted} = ThreatIntelEvidence.parse_address(accepted, :cidr)
    end

    for rejected <- [
          "198.51.100.10/24",
          "198.51.100.1/31",
          "2001:db8::1/64",
          "198.51.100.0/33",
          "not-an-ip"
        ] do
      assert {:error, :invalid_cidr} = ThreatIntelEvidence.parse_address(rejected, :cidr)
    end
  end
end
