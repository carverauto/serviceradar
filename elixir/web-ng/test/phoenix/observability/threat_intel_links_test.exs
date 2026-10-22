defmodule ServiceRadarWebNGWeb.Observability.ThreatIntelLinksTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Observability.ThreatIntelLinks

  @moduletag :db_free

  describe "IOC-only flow filter" do
    test "toggles threat_matched:true on and back off without touching other tokens" do
      query = ~s(in:flows time:last_24h src_ip:"192.0.2.1" sort:time:desc)

      narrowed = ThreatIntelLinks.toggle_threat_matched(query)
      assert narrowed == query <> " threat_matched:true"
      assert ThreatIntelLinks.threat_matched?(narrowed)

      assert ThreatIntelLinks.toggle_threat_matched(narrowed) == query
      refute ThreatIntelLinks.threat_matched?(query)
    end

    test "replaces an explicit threat_matched:false instead of stacking a contradiction" do
      query = "in:attributed_flows time:last_1h threat_matched:false"

      refute ThreatIntelLinks.threat_matched?(query)

      assert ThreatIntelLinks.toggle_threat_matched(query) ==
               "in:attributed_flows time:last_1h threat_matched:true"
    end

    test "treats the field name case-insensitively, as the SRQL parser does" do
      negated = "in:attributed_flows time:last_24h THREAT_MATCHED:false"

      assert ThreatIntelLinks.toggle_threat_matched(negated) ==
               "in:attributed_flows time:last_24h threat_matched:true"

      narrowed = "in:attributed_flows time:last_24h Threat_Matched:true"
      assert ThreatIntelLinks.threat_matched?(narrowed)

      assert ThreatIntelLinks.toggle_threat_matched(narrowed) ==
               "in:attributed_flows time:last_24h"
    end
  end
end
