defmodule ServiceRadar.Observability.ThreatIntel.PageTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ThreatIntel.Page

  test "builds provider-neutral page metadata from CTI maps" do
    raw = %{
      "schema_version" => 1,
      "provider" => "alienvault_otx",
      "source" => "alienvault_otx",
      "collection_id" => "otx:pulses:subscribed",
      "cursor" => %{
        "next" => "https://otx.example/next",
        "modified_since" => "2026-04-27T00:00:00Z"
      },
      "counts" => %{"objects" => 1, "indicators" => 1},
      "indicators" => [%{"indicator" => "192.0.2.55"}]
    }

    assert %Page{
             schema_version: 1,
             provider: "alienvault_otx",
             source: "alienvault_otx",
             collection_id: "otx:pulses:subscribed",
             cursor: %{
               "next" => "https://otx.example/next",
               "modified_since" => "2026-04-27T00:00:00Z"
             },
             counts: %{"objects" => 1, "indicators" => 1},
             indicators: [%{"indicator" => "192.0.2.55"}],
             raw: ^raw
           } = Page.from_map(raw, %{})
  end

  test "falls back to plugin status identity when page source is absent" do
    page = Page.from_map(%{"indicators" => []}, %{"plugin_id" => "siem-edge-collector"})

    assert page.provider == "siem-edge-collector"
    assert page.source == "siem-edge-collector"
  end

  test "normalizes page indicators and STIX objects with max bounds" do
    observed_at = ~U[2026-04-27 12:00:00Z]

    page =
      Page.from_map(
        %{
          "source" => "taxii-feed",
          "collection_id" => "collection-a",
          "indicators" => [
            %{"indicator" => "192.0.2.1", "label" => "direct"},
            %{"indicator" => "192.0.2.1", "label" => "duplicate"},
            %{"indicator" => "example.invalid"}
          ],
          "objects" => [
            %{
              "type" => "indicator",
              "name" => "stix subnet",
              "pattern" => "[ipv4-addr:value ISSUBSET '198.51.100.0/24']"
            }
          ]
        },
        %{}
      )

    assert [
             %{indicator: "192.0.2.1/32", label: "direct", source: "taxii-feed"},
             %{indicator: "198.51.100.0/24", label: "stix subnet", source: "taxii-feed"}
           ] = Page.indicator_attrs(page, observed_at, max_indicators: 10)
  end
end
