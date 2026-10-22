defmodule ServiceRadar.Observability.ThreatIntelInvestigationTest do
  use ExUnit.Case, async: true

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
end
