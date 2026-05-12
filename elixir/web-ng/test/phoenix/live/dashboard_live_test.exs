defmodule ServiceRadarWebNGWeb.DashboardLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationStorageSystem
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNGWeb.DashboardLive.Data

  setup :register_and_log_in_user

  test "renders the operations dashboard inside the authenticated shell", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Unified Operations Dashboard"
    assert has_element?(view, "[data-testid='operations-dashboard']")
    assert has_element?(view, "a[aria-current='page'][href='/dashboard']")
    assert has_element?(view, "#ops-traffic-map[phx-hook='OperationsTrafficMap']")
    assert has_element?(view, "select[name='map_view']", "NetFlow Map")
    assert has_element?(view, "a[href='/netflow-map']", "Full Screen")
    assert has_element?(view, "#ops-traffic-map[data-topology-links]")
    assert has_element?(view, "a.sr-ops-topbar-icon[href='/alerts'][aria-label='Alerts']")
    assert has_element?(view, "a.sr-ops-avatar[href='/settings/profile'][aria-label='Open profile']")
    refute has_element?(view, ".sr-ops-notification-dot")
  end

  test "dashboard summary cards expose drill-down links", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "a.sr-ops-kpi-card[href='/devices']", "Total Assets")
    assert has_element?(view, "a.sr-ops-kpi-card[href='/events']", "Threat Level")
    assert has_element?(view, "a.sr-ops-kpi-card[href='/services']", "Network Health")
    assert has_element?(view, "a.sr-ops-kpi-card[href='/alerts']", "Active Alerts")
    assert has_element?(view, "a.sr-ops-small-stat[href*='tab=netflows']", "Window")
    assert has_element?(view, "a.sr-ops-small-stat[href*='tab=netflows']", "Conversations")
    assert has_element?(view, "a.sr-ops-metric-card[href='/diagnostics/mtr']", "Latency (Avg)")
    assert has_element?(view, "a.sr-ops-metric-card[href='/diagnostics/mtr']", "Packet Loss")
    assert has_element?(view, "a.sr-ops-metric-card[href='/services']", "Service Health")
    assert has_element?(view, "a[data-testid='threat-intel-summary'][href='/settings/networks/threat-intel']")
    assert has_element?(view, "a[data-testid='alerts-feed-empty'][href='/alerts']")
  end

  test "dashboard KPI metadata includes drill-downs for conditionally hidden cards" do
    cards = Data.empty().kpi_cards

    assert Enum.find(cards, &(&1.title == "Camera Fleet")).href == "/cameras"
    assert Enum.find(cards, &(&1.title == "Wi-Fi Coverage")).href == "/spatial/field-surveys"
  end

  test "dashboard falls back to NetFlow for unsupported map modes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_hook(view, "select_map_view", %{"map_view" => "unsupported"})

    assert html =~ "NetFlow Map"
    assert has_element?(view, "a[href='/netflow-map']", "Full Screen")
  end

  test "dashboard selects the default dashboard package map view", %{conn: conn} do
    route_slug = "dashboard-default-map-#{System.unique_integer([:positive])}"
    create_dashboard_instance!(route_slug)

    {:ok, view, _html} = live(conn, ~p"/dashboard")
    html = render_async(view, 5_000)

    assert html =~ "Default Map Package"
    assert has_element?(view, "option[value='dashboard:#{route_slug}'][selected]")
    assert has_element?(view, "a[href='/dashboards/#{route_slug}']", "Full Screen")
    refute has_element?(view, "#ops-traffic-map[phx-hook='OperationsTrafficMap']")
  end

  test "renders virtualization efficiency panel from SRQL inventory", %{conn: conn} do
    unique = System.unique_integer([:positive])
    observed_at = DateTime.truncate(DateTime.utc_now(), :second)
    host_uid = "sr:dashboard-pve-#{unique}"
    guest_uid = "sr:dashboard-vm-#{unique}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: host_uid,
        type_id: 1,
        hostname: "dashboard-pve-#{unique}",
        is_available: true,
        first_seen_time: observed_at,
        last_seen_time: observed_at
      },
      %{
        uid: guest_uid,
        type_id: 1,
        hostname: "dashboard-vm-#{unique}",
        is_available: true,
        first_seen_time: observed_at,
        last_seen_time: observed_at
      }
    ])

    {:ok, host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(:create, %{
        provider: "proxmox",
        provider_ref: "proxmox:node:dashboard-pve-#{unique}",
        device_uid: host_uid,
        name: "dashboard-pve-#{unique}",
        status: "online",
        cpu_ratio: 0.91,
        memory_used_bytes: 90,
        memory_total_bytes: 100,
        observed_at: observed_at
      })
      |> Ash.create(actor: system_actor())

    {:ok, _guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(:create, %{
        provider: "proxmox",
        provider_ref: "proxmox:guest:dashboard-pve-#{unique}:qemu:100",
        host_id: host.id,
        device_uid: guest_uid,
        name: "dashboard-vm-#{unique}",
        guest_type: "vm",
        vmid: 100,
        status: "running",
        cpu_ratio: 0.42,
        memory_used_bytes: 1,
        memory_total_bytes: 4,
        disk_used_bytes: 2,
        disk_total_bytes: 10,
        observed_at: observed_at
      })
      |> Ash.create(actor: system_actor())

    {:ok, _datastore} =
      VirtualizationDatastore
      |> Ash.Changeset.for_create(:create, %{
        provider: "proxmox",
        provider_ref: "proxmox:datastore:dashboard-pve-#{unique}:local-zfs",
        host_id: host.id,
        name: "local-zfs",
        storage_type: "zfspool",
        used_bytes: 92,
        total_bytes: 100,
        observed_at: observed_at
      })
      |> Ash.create(actor: system_actor())

    {:ok, _storage} =
      VirtualizationStorageSystem
      |> Ash.Changeset.for_create(:create, %{
        provider: "proxmox",
        provider_ref: "proxmox:ceph:dashboard-pve-#{unique}",
        host_id: host.id,
        name: "Ceph",
        storage_system_type: "ceph",
        health: "HEALTH_WARN",
        observed_at: observed_at
      })
      |> Ash.create(actor: system_actor())

    {:ok, view, _html} = live(conn, ~p"/dashboard")
    html = render_async(view, 10_000)

    assert has_element?(view, "[data-testid='virtualization-efficiency']")
    assert html =~ "Virtualization Efficiency"
    assert html =~ "Proxmox"
    assert html =~ "Running"
    assert html =~ "Pressure"
    assert html =~ "Pressure sources"
    assert html =~ "dashboard-pve-#{unique}"
    assert html =~ "local-zfs"
    assert html =~ "1 storage warnings"
  end

  test "renders honest empty states for feeds that are not implemented yet", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "[data-testid='traffic-map-empty']")
    assert has_element?(view, "[data-testid='security-events-empty']", "No event trend data")
    assert has_element?(view, "[data-testid='alerts-feed-empty']", "No recent alerts")
    refute has_element?(view, "[data-testid='fieldsurvey-heatmap']")
    refute has_element?(view, "[data-testid='camera-operations']")
  end

  defp create_dashboard_instance!(route_slug) do
    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, package_attrs())
      |> Ash.create!()
      |> Ash.Changeset.for_update(:enable, %{})
      |> Ash.update!()

    DashboardInstance
    |> Ash.Changeset.for_create(:create, %{
      dashboard_package_id: package.id,
      name: "Default Map Package",
      route_slug: route_slug,
      placement: :map,
      enabled: true,
      is_default: true,
      settings: %{},
      metadata: %{}
    })
    |> Ash.create!()
  end

  defp package_attrs do
    manifest = %{
      "id" => "com.test.dashboard.default-map.#{System.unique_integer([:positive])}",
      "name" => "Default Map Package",
      "version" => "0.1.0",
      "renderer" => %{
        "kind" => "browser_module",
        "interface_version" => "dashboard-browser-module-v1",
        "artifact" => "renderer.js",
        "sha256" => String.duplicate("a", 64),
        "trust" => "trusted"
      },
      "data_frames" => [%{"id" => "sites", "query" => "in:wifi_sites", "encoding" => "json_rows"}],
      "capabilities" => ["srql.execute"],
      "settings_schema" => %{}
    }

    %{
      dashboard_id: manifest["id"],
      name: manifest["name"],
      version: manifest["version"],
      manifest: manifest,
      renderer: manifest["renderer"],
      data_frames: manifest["data_frames"],
      capabilities: manifest["capabilities"],
      settings_schema: manifest["settings_schema"],
      wasm_object_key: "dashboards/test/renderer.js",
      content_hash: String.duplicate("a", 64),
      verification_status: "verified"
    }
  end
end
