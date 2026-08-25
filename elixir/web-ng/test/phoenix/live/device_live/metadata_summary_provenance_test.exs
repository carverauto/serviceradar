defmodule ServiceRadarWebNGWeb.DeviceLive.MetadataSummaryProvenanceTest do
  # Pure function-component rendering — no database required.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.VisibilityComponents

  @moduletag :db_free

  defp render_summary(device_row) do
    render_component(&VisibilityComponents.metadata_summary_section/1, device_row: device_row)
  end

  test "a proxmox-only device shows no fabricated Armis/NetBox provenance" do
    # Mirrors the live demo device `proxmox:vm:k8s-cp2-cnpg1`: discovered via the
    # proxmox plugin + sweep, carrying only GENERIC device fields. It is not in
    # Armis or NetBox, so neither card must appear.
    html =
      render_summary(%{
        "discovery_sources" => ["proxmox", "sweep"],
        "metadata" => %{
          "integration_type" => "plugin_device_discovery",
          "integration_id" => "proxmox:vm:k8s-cp2-cnpg1",
          "device_role" => "proxmox_vm",
          "device_type" => "vm",
          "status" => "running",
          "model" => "vm",
          "vendor_name" => "Proxmox",
          "plugin_discovery_source" => "proxmox"
        }
      })

    # No integration card is fabricated from generic fields.
    refute html =~ "Armis"
    refute html =~ "NetBox"
    refute html =~ "/images/integrations/armis.svg"
    refute html =~ "/images/integrations/netbox.svg"
    refute html =~ "/images/integrations/proxmox.svg"
    refute html =~ "/images/integrations/ansible.svg"

    # And specifically none of the generic values are mislabeled as an
    # integration device id / role.
    refute html =~ "hero-shield-check"
    refute html =~ "hero-server-stack"

    # The generic descriptors are still surfaced — under a truthful neutral
    # "Device" group, not under Armis/NetBox.
    assert html =~ "Device"
    assert html =~ "proxmox_vm"
    assert html =~ "running"

    # The proxmox source id lives in the neutral Integration group, never Armis.
    assert html =~ "proxmox:vm:k8s-cp2-cnpg1"
  end

  test "a device with a real armis_device_id shows the Armis card" do
    html =
      render_summary(%{
        "discovery_sources" => ["armis", "sweep"],
        "metadata" => %{
          "integration_type" => "armis",
          "armis_device_id" => "18497",
          "armis_type" => "Multifunction Printer",
          "armis_risk_level" => "2",
          "device_type" => "Smart Thermostat"
        }
      })

    assert html =~ "Armis"
    assert html =~ "18497"
    assert html =~ "Multifunction Printer"
    assert html =~ "/images/integrations/armis.svg"
    assert html =~ "/images/integrations/armis-dark.svg"
    refute html =~ "hero-shield-check"
    refute html =~ "NetBox"
  end

  test "armis provenance can come from discovery_sources alone" do
    html =
      render_summary(%{
        # No armis_device_id and integration_type is not armis, but the device
        # was genuinely merged from Armis per its authoritative source list.
        "discovery_sources" => ["armis"],
        "metadata" => %{
          "integration_type" => "plugin_device_discovery",
          "armis_risk_level" => "High"
        }
      })

    assert html =~ "Armis"
    assert html =~ "High"
  end

  test "a device with real netbox_* metadata shows the NetBox card" do
    html =
      render_summary(%{
        "discovery_sources" => ["netbox"],
        "metadata" => %{
          "netbox_device_id" => "nb-123",
          "device_role" => "core-switch",
          "status" => "active"
        }
      })

    assert html =~ "NetBox"
    assert html =~ "nb-123"
    assert html =~ "core-switch"
    assert html =~ "/images/integrations/netbox.svg"
    refute html =~ "hero-server-stack"
    refute html =~ "Armis"
  end

  test "netbox provenance can come from discovery_sources alone" do
    html =
      render_summary(%{
        "discovery_sources" => ["netbox", "sweep"],
        "metadata" => %{
          "device_role" => "access-switch",
          "status" => "active"
        }
      })

    assert html =~ "NetBox"
    assert html =~ "access-switch"
  end

  test "generic role/status on a plain device never fabricate an integration card" do
    html =
      render_summary(%{
        "discovery_sources" => ["mapper", "sweep"],
        "metadata" => %{
          "device_role" => "router",
          "status" => "reachable"
        }
      })

    refute html =~ "Armis"
    refute html =~ "NetBox"
    # Still shown truthfully under the neutral "Device" group.
    assert html =~ "router"
    assert html =~ "reachable"
  end

  test "manufacturer, model, and OS live on the Device card, not a separate Inventory card" do
    html =
      render_summary(%{
        "discovery_sources" => ["armis", "sweep"],
        "metadata" => %{
          "device_role" => "Multifunction Printer",
          "device_type" => "Printer",
          "status" => "active",
          "manufacturer" => "Hewlett Packard",
          "model" => "LaserJet MFP",
          "operating_system" => "FutureSmart",
          "identity_source" => "armis",
          "identity_state" => "confirmed"
        }
      })

    assert html =~ "Device"
    assert html =~ "Hewlett Packard"
    assert html =~ "LaserJet MFP"
    assert html =~ "FutureSmart"
    assert html =~ "confirmed"
    refute html =~ "Inventory"
    refute html =~ "hero-identification"
  end

  test "accepts a raw Postgres text-array literal for discovery_sources" do
    html =
      render_summary(%{
        "discovery_sources" => "{armis,sweep}",
        "metadata" => %{"armis_risk_level" => "Low"}
      })

    assert html =~ "Armis"
    assert html =~ "Low"
  end

  test "a device with Proxmox candidate evidence shows the Proxmox wordmark" do
    html =
      render_summary(%{
        "discovery_sources" => ["proxmox", "sweep"],
        "metadata" => %{
          "proxmox_candidate" => true,
          "proxmox_candidate_title" => "pve-01",
          "proxmox_candidate_service" => "pveproxy"
        }
      })

    assert html =~ "Proxmox"
    assert html =~ "pve-01"
    assert html =~ "/images/integrations/proxmox.svg"
    assert html =~ "/images/integrations/proxmox-dark.svg"
    refute html =~ "hero-cube-transparent"
  end
end
