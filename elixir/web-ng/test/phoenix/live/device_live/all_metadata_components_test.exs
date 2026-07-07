defmodule ServiceRadarWebNGWeb.DeviceLive.AllMetadataComponentsTest do
  # Pure function-component rendering — no database required.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.AllMetadataComponents

  @moduletag :db_free

  test "renders a collapsed card exposing the complete metadata map" do
    device_row = %{
      "device_id" => "router-1",
      "metadata" => %{
        "armis_device_id" => "88421",
        "armis_risk_level" => "High",
        "armis_tags" => ["printer", "iot"],
        "netbox_device_id" => "42",
        "proxmox_node" => "pve-01",
        "sweep_available" => true,
        "agent_id" => "agent-abc",
        "integration_type" => "armis",
        "custom_attribute" => %{"nested" => %{"deep" => "value"}}
      }
    }

    html = render_component(&AllMetadataComponents.all_metadata_section/1, device_row: device_row)

    # Collapsible <details>, collapsed by default (no `open` attribute rendered).
    assert html =~ ~s(<details)
    assert html =~ ~s(id="device-all-metadata")
    refute html =~ ~r/<details[^>]*\sopen/

    # Header advertises the full key count.
    assert html =~ "All Metadata"
    assert html =~ "9 keys"

    # Client-side conveniences are present and wired to the hook.
    assert html =~ ~s(phx-hook="AllMetadataCard")
    assert html =~ "data-metadata-filter-input"
    assert html =~ "data-metadata-copy"
    assert html =~ "data-metadata-json="

    # Every raw key is surfaced (nothing hidden), including all armis_* keys.
    for raw_key <- [
          "armis_device_id",
          "armis_risk_level",
          "armis_tags",
          "netbox_device_id",
          "proxmox_node",
          "sweep_available",
          "agent_id",
          "integration_type",
          "custom_attribute"
        ] do
      assert html =~ raw_key, "expected raw key #{raw_key} to render"
    end

    # Keys are humanized with the prefix stripped (raw key still shown
    # alongside); known acronyms upper-case (device_id -> "Device ID").
    assert html =~ "Device ID"
    assert html =~ "Risk Level"

    # Prefix grouping produces readable source subsections.
    assert html =~ "Armis"
    assert html =~ "NetBox"
    assert html =~ "Proxmox"

    # Nested map/list values pretty-print as JSON inside a scrollable <pre>.
    assert html =~ "<pre"
    assert html =~ "&quot;deep&quot;: &quot;value&quot;"
    assert html =~ "[\n  &quot;printer&quot;,\n  &quot;iot&quot;\n]"

    # Scalar values render inline.
    assert html =~ "true"
    assert html =~ "pve-01"
  end

  test "renders a tidy empty state when metadata is nil or empty" do
    for row <- [%{"metadata" => %{}}, %{"metadata" => nil}, %{"device_id" => "x"}] do
      html = render_component(&AllMetadataComponents.all_metadata_section/1, device_row: row)

      assert html =~ "All Metadata"
      assert html =~ "0 keys"
      assert html =~ "No additional metadata."
      refute html =~ ~s(phx-hook="AllMetadataCard")
    end
  end
end
