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

  test "each searchable scalar row exposes a 'find similar devices' SRQL deep-link" do
    device_row = %{"metadata" => %{"proxmox_node" => "pve-01"}}

    html = render_component(&AllMetadataComponents.all_metadata_section/1, device_row: device_row)

    # The find-similar affordance is present on the row.
    assert html =~ "data-metadata-find"
    assert html =~ "Find similar"

    # It navigates to the Devices page with an SRQL query filtering on the exact
    # `metadata.<key>:"<value>"` predicate the Rust engine already supports.
    expected_q = URI.encode(~s|in:devices metadata.proxmox_node:"pve-01"|)
    assert html =~ "/devices?q=" <> expected_q
  end

  test "the deep-link quotes and escapes values so injection attempts stay inside the token" do
    device_row = %{"metadata" => %{"site_tag" => ~s(New York" OR 1=1)}}

    html = render_component(&AllMetadataComponents.all_metadata_section/1, device_row: device_row)

    # Backslash/quote escaping mirrors the devices breakdown deep-links; the
    # embedded double-quote is escaped (\") rather than closing the SRQL token.
    # The engine binds the value as a parameter, so this can never break out of
    # the JSONB predicate — the link merely carries it safely.
    expected_q = URI.encode(~s|in:devices metadata.site_tag:"New York\\" OR 1=1"|)
    assert html =~ "/devices?q=" <> expected_q
  end

  test "no find-link is rendered for nested, blank, or non-whitelisted-key values" do
    device_row = %{
      "metadata" => %{
        # nested map/list values cannot form a scalar metadata predicate
        "nested_map" => %{"a" => 1},
        "armis_tags" => ["printer", "iot"],
        # blank/whitespace-only scalars are not searchable
        "blank_val" => "   ",
        # keys outside the engine's [A-Za-z0-9_-] whitelist are rejected
        "weird.key" => "value"
      }
    }

    html = render_component(&AllMetadataComponents.all_metadata_section/1, device_row: device_row)

    refute html =~ "data-metadata-find"
    refute html =~ "Find similar"
  end
end
