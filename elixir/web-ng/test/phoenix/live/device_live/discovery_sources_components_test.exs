defmodule ServiceRadarWebNGWeb.DeviceLive.DiscoverySourcesComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.DiscoverySourcesComponents

  @moduletag :db_free

  test "renders HPNA provenance without hiding other discovery sources" do
    html =
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{
          "discovery_sources" => ["armis", "hpna"],
          "metadata" => %{
            "armis_device_id" => "armis-42",
            "hpna_instance_id" => "example-automation-prod",
            "hpna_device_id" => "12091",
            "hpna_partition" => "IAD",
            "hpna_device_type" => "Switch",
            "hpna_management_status" => "Managed",
            "hpna_collection_id" => "20260713T180000Z-deadbeef",
            "hpna_last_observed_at" => "2026-07-13T18:00:00Z",
            "hpna_present" => true
          }
        },
        source_observations: [
          %{
            "source" => "hpna",
            "source_instance" => "example-automation-prod",
            "source_object_id" => "12091",
            "collection_id" => "20260713T180000Z-deadbeef",
            "present" => false,
            "last_observed_at" => "2026-07-13T18:00:00Z"
          }
        ]
      )

    assert html =~ "Armis"
    assert html =~ "HPNA"
    assert html =~ "example-automation-prod"
    assert html =~ "12091"
    assert html =~ "IAD"
    assert html =~ "Managed"
    assert html =~ "20260713T180000Z-deadbeef"
    assert html =~ "2026-07-13T18:00:00Z"
    refute html =~ "Present: Yes"
    assert html =~ "Absent"
  end

  test "renders atom-keyed source observations without creating atoms" do
    html =
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{
          discovery_sources: ["hpna"],
          metadata: %{
            hpna_instance_id: "example-automation-prod",
            hpna_device_id: "12091"
          }
        },
        source_observations: [
          %{
            source: "hpna",
            source_instance: "example-automation-prod",
            source_object_id: "12091",
            collection_id: "collection-1",
            present: true,
            last_observed_at: "2026-07-13T18:00:00Z"
          }
        ]
      )

    assert html =~ "HPNA"
    assert html =~ "example-automation-prod"
    assert html =~ "12091"
    assert html =~ "Current"
  end
end
