defmodule ServiceRadar.Observability.ThreatIntelPluginIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ThreatIntelPluginIngestor

  test "normalizes IP and CIDR indicators from plugin details JSON" do
    observed_at = ~U[2026-04-27 12:00:00Z]

    payload = %{
      "details" =>
        Jason.encode!(%{
          "threat_intel" => %{
            "provider" => "alienvault_otx",
            "collection_id" => "subscribed",
            "indicators" => [
              %{
                "indicator" => "192.0.2.10",
                "title" => "OTX pulse A",
                "confidence" => "80",
                "severity_id" => 3,
                "created" => "2026-04-26T11:00:00Z",
                "modified" => "2026-04-27T11:30:00Z"
              },
              %{
                "indicator" => "198.51.100.0/24",
                "pulse_name" => "OTX pulse B"
              },
              %{
                "indicator" => "example.invalid",
                "pulse_name" => "domain indicators are not persisted yet"
              }
            ]
          }
        })
    }

    status = %{plugin_id: "alienvault-otx-threat-intel"}

    assert [
             %{
               indicator: "192.0.2.10/32",
               indicator_type: "cidr",
               source: "alienvault_otx",
               label: "OTX pulse A",
               severity: 3,
               confidence: 80,
               first_seen_at: ~U[2026-04-26 11:00:00Z],
               last_seen_at: ~U[2026-04-27 11:30:00Z],
               expires_at: nil
             },
             %{
               indicator: "198.51.100.0/24",
               indicator_type: "cidr",
               source: "alienvault_otx",
               label: "OTX pulse B",
               first_seen_at: ^observed_at,
               last_seen_at: ^observed_at
             }
           ] = ThreatIntelPluginIngestor.normalize_indicators(payload, status, observed_at)
  end

  test "uses top-level threat intel payloads and deduplicates by source and indicator" do
    observed_at = ~U[2026-04-27 12:00:00Z]

    payload = %{
      "threat_intel" => %{
        "source" => "edge-otx",
        "indicators" => [
          %{"indicator" => "2001:db8::5", "source" => "pulse-one"},
          %{"indicator" => "2001:db8::5", "source" => "pulse-one"},
          %{"indicator" => "2001:db8::5", "source" => "pulse-two"}
        ]
      }
    }

    assert [
             %{indicator: "2001:db8::5/128", source: "pulse-one"},
             %{indicator: "2001:db8::5/128", source: "pulse-two"}
           ] = ThreatIntelPluginIngestor.normalize_indicators(payload, %{}, observed_at)
  end

  test "falls back to plugin id when provider source is absent" do
    observed_at = ~U[2026-04-27 12:00:00Z]

    payload = %{
      "threat_intel" => %{
        "indicators" => [
          %{"indicator" => "203.0.113.88"}
        ]
      }
    }

    assert [%{source: "alienvault-otx-threat-intel"}] =
             ThreatIntelPluginIngestor.normalize_indicators(
               payload,
               %{"plugin_id" => "alienvault-otx-threat-intel"},
               observed_at
             )
  end

  test "normalizes STIX indicator objects from plugin CTI pages" do
    observed_at = ~U[2026-04-27 12:00:00Z]

    payload = %{
      "threat_intel" => %{
        "source" => "taxii-feed",
        "objects" => [
          %{
            "type" => "indicator",
            "name" => "C2 subnet",
            "confidence" => 65,
            "pattern" => "[ipv4-addr:value ISSUBSET '203.0.113.0/24']"
          }
        ]
      }
    }

    assert [
             %{
               indicator: "203.0.113.0/24",
               indicator_type: "cidr",
               source: "taxii-feed",
               label: "C2 subnet",
               confidence: 65,
               first_seen_at: ^observed_at,
               last_seen_at: ^observed_at
             }
           ] = ThreatIntelPluginIngestor.normalize_indicators(payload, %{}, observed_at)
  end
end
