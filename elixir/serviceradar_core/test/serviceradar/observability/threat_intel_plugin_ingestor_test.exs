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

  test "does not truncate a valid OTX page at the legacy 5000 row boundary" do
    observed_at = ~U[2026-04-27 12:00:00Z]

    indicators =
      Enum.map(0..5_000, fn suffix ->
        %{"indicator" => "2001:db8::#{Integer.to_string(suffix, 16)}"}
      end)

    payload = %{
      "threat_intel" => %{
        "provider" => "alienvault_otx",
        "source" => "alienvault_otx",
        "indicators" => indicators
      }
    }

    normalized = ThreatIntelPluginIngestor.normalize_indicators(payload, %{}, observed_at)

    assert length(normalized) == 5_001
    assert List.last(normalized).indicator == "2001:db8::1388/128"
  end

  test "rejects partial Ash bulk results even when diagnostic errors are omitted" do
    result = %Ash.BulkResult{status: :partial_success, error_count: 1, errors: []}

    assert {:error, ^result} = ThreatIntelPluginIngestor.bulk_result_outcome(result)

    assert :ok =
             ThreatIntelPluginIngestor.bulk_result_outcome(%Ash.BulkResult{
               status: :success,
               error_count: 0
             })
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

  describe "cursor_params/2" do
    test "persists the effective limit with the next page for an in-progress walk" do
      cursor = %{
        "complete" => "false",
        "limit" => "500",
        "modified_since" => "2026-06-10T00:00:00Z",
        "next_page" => "46",
        "next" => "https://otx.alienvault.com/api/v1/indicators/export?limit=500&page=46"
      }

      assert %{
               "page" => 46,
               "limit" => 500,
               "modified_since" => "2026-06-10T00:00:00Z",
               "cursor_complete" => false,
               "cursor_next" =>
                 "https://otx.alienvault.com/api/v1/indicators/export?limit=500&page=46"
             } == ThreatIntelPluginIngestor.cursor_params(cursor)
    end

    test "does not replace the configured limit with an invalid cursor value" do
      cursor = %{
        "complete" => "false",
        "limit" => "not-a-limit",
        "next_page" => "46"
      }

      assert %{"page" => 46, "cursor_complete" => false} ==
               ThreatIntelPluginIngestor.cursor_params(cursor)
    end

    test "stamps an incremental modified_since cursor when a walk completes" do
      now = ~U[2026-07-06 19:00:00Z]

      assert %{
               "page" => 1,
               "cursor_complete" => true,
               "cursor_next" => nil,
               "modified_since" => "2026-07-04T19:00:00Z"
             } == ThreatIntelPluginIngestor.cursor_params(%{"complete" => "true"}, now)
    end

    test "round-trips the plugin-stamped last_pull_at when a walk completes" do
      now = ~U[2026-07-06 19:00:00Z]

      assert %{
               "page" => 1,
               "cursor_complete" => true,
               "cursor_next" => nil,
               "modified_since" => "2026-07-04T19:00:00Z",
               "last_pull_at" => "2026-07-06T18:59:00Z"
             } ==
               ThreatIntelPluginIngestor.cursor_params(
                 %{"complete" => "true", "last_pull_at" => "2026-07-06T18:59:00Z"},
                 now
               )
    end

    test "keeps the effective limit after an adaptive walk completes" do
      now = ~U[2026-07-06 19:00:00Z]

      assert %{
               "page" => 1,
               "limit" => 125,
               "cursor_complete" => true,
               "cursor_next" => nil,
               "modified_since" => "2026-07-04T19:00:00Z"
             } ==
               ThreatIntelPluginIngestor.cursor_params(
                 %{"complete" => "true", "limit" => "125"},
                 now
               )
    end

    test "does not persist last_pull_at while a walk is still in progress" do
      cursor = %{
        "complete" => "false",
        "next_page" => "24",
        "last_pull_at" => "2026-07-06T18:59:00Z"
      }

      refute Map.has_key?(ThreatIntelPluginIngestor.cursor_params(cursor), "last_pull_at")
    end

    test "returns no params when the cursor is empty or not a map" do
      assert ThreatIntelPluginIngestor.cursor_params(%{}) == %{}
      assert ThreatIntelPluginIngestor.cursor_params(nil) == %{}
    end
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
