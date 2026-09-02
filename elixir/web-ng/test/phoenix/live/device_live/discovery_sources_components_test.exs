defmodule ServiceRadarWebNGWeb.DeviceLive.DiscoverySourcesComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.DiscoverySourcesComponents

  @moduletag :db_free

  test "renders package-declared inventory provenance without hiding other sources" do
    html =
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{
          "discovery_sources" => ["armis", "example-inventory"],
          "metadata" => %{"armis_device_id" => "armis-42"}
        },
        source_observations: [
          %{
            "source" => "example-inventory",
            "source_label" => "External Network Inventory",
            "source_instance" => "example-prod",
            "source_object_id" => "12091",
            "collection_id" => "20260713T180000Z-deadbeef",
            "present" => false,
            "last_observed_at" => "2026-07-13T18:00:00Z",
            "metadata" => %{"site" => "IAD", "management_status" => "Managed"},
            "metadata_fields" => [
              %{"key" => "site", "label" => "Site"},
              %{"key" => "management_status", "label" => "Management status"}
            ]
          }
        ]
      )

    assert html =~ "Armis"
    assert html =~ "/images/integrations/armis.svg"
    assert html =~ "/images/integrations/armis-dark.svg"
    assert html =~ "Example Inventory"
    assert html =~ "External Network Inventory"
    assert html =~ "example-prod"
    assert html =~ "12091"
    assert html =~ "Site:"
    assert html =~ "IAD"
    assert html =~ "Management status:"
    assert html =~ "Managed"
    assert html =~ "20260713T180000Z-deadbeef"
    assert html =~ "2026-07-13T18:00:00Z"
    assert html =~ "Absent"
  end

  test "renders atom-keyed source observations without creating provider atoms" do
    html =
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{discovery_sources: ["other-inventory"], metadata: %{}},
        source_observations: [
          %{
            source: "other-inventory",
            source_label: "Other Inventory",
            source_instance: "other-prod",
            source_object_id: "12091",
            collection_id: "collection-1",
            present: true,
            last_observed_at: "2026-07-13T18:00:00Z",
            metadata: %{region: "central"},
            metadata_fields: [%{"key" => "region", "label" => "Region"}]
          }
        ]
      )

    assert html =~ "Other Inventory"
    assert html =~ "other-prod"
    assert html =~ "12091"
    assert html =~ "Region:"
    assert html =~ "central"
    assert html =~ "Current"
  end

  test "renders the vendored Armis wordmark instead of a shield-and-text chip" do
    html =
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{
          "discovery_sources" => ["armis"],
          "metadata" => %{"armis_device_id" => "armis-42"}
        }
      )

    assert html =~ "Armis"
    assert html =~ "/images/integrations/armis.svg"
    assert html =~ "/images/integrations/armis-dark.svg"
    refute html =~ "hero-shield-check"
  end

  test "packages both Armis wordmarks with the app" do
    priv = Application.app_dir(:serviceradar_web_ng, "priv/static/images/integrations")

    assert File.exists?(Path.join(priv, "armis.svg"))
    assert File.exists?(Path.join(priv, "armis-dark.svg"))
  end

  test "renders the vendored NetBox wordmark instead of a stack-and-text chip" do
    html =
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{
          "discovery_sources" => ["netbox"],
          "metadata" => %{"netbox_device_id" => "nb-9"}
        }
      )

    assert html =~ "NetBox"
    assert html =~ "/images/integrations/netbox.svg"
    refute html =~ "hero-server-stack"
  end

  test "packages the NetBox wordmark with the app" do
    priv = Application.app_dir(:serviceradar_web_ng, "priv/static/images/integrations")

    assert File.exists?(Path.join(priv, "netbox.svg"))
  end

  test "renders the vendored Proxmox wordmark instead of a cube-and-text chip" do
    html =
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{
          "discovery_sources" => ["proxmox"],
          "metadata" => %{"proxmox_node" => "pve-01"}
        }
      )

    assert html =~ "Proxmox"
    assert html =~ "/images/integrations/proxmox.svg"
    assert html =~ "/images/integrations/proxmox-dark.svg"
    refute html =~ "hero-cube-transparent"
  end

  test "uses the Proxmox wordmark for proxmox-api and proxmox_candidate sources" do
    for source <- ["proxmox-api", "proxmox_candidate"] do
      html =
        render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
          device_row: %{"discovery_sources" => [source], "metadata" => %{}}
        )

      assert html =~ "/images/integrations/proxmox.svg"
      refute html =~ "hero-cube-transparent"
    end
  end

  test "packages both Proxmox wordmarks with the app" do
    priv = Application.app_dir(:serviceradar_web_ng, "priv/static/images/integrations")

    assert File.exists?(Path.join(priv, "proxmox.svg"))
    assert File.exists?(Path.join(priv, "proxmox-dark.svg"))
  end

  test "renders the vendored Ansible wordmark instead of a command-and-text chip" do
    html =
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{
          "discovery_sources" => ["awx"],
          "metadata" => %{"query_label" => "prod-inventory"}
        }
      )

    assert html =~ "AWX / Ansible"
    assert html =~ "/images/integrations/ansible.svg"
    assert html =~ "/images/integrations/ansible-dark.svg"
    refute html =~ "hero-command-line"
  end

  test "uses the Ansible wordmark for ansible discovery sources" do
    html =
      render_component(&DiscoverySourcesComponents.discovery_sources_section/1,
        device_row: %{"discovery_sources" => ["ansible"], "metadata" => %{}}
      )

    assert html =~ "/images/integrations/ansible.svg"
    refute html =~ "hero-command-line"
  end

  test "packages both Ansible wordmarks with the app" do
    priv = Application.app_dir(:serviceradar_web_ng, "priv/static/images/integrations")

    assert File.exists?(Path.join(priv, "ansible.svg"))
    assert File.exists?(Path.join(priv, "ansible-dark.svg"))
  end
end
