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
  alias ServiceRadarWebNG.TestSupport.CameraRelaySessionManagerStub
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
    assert has_element?(view, "a.sr-ops-topbar-icon[href='/observability?tab=alerts'][aria-label='Alerts']")
    assert has_element?(view, "#ops-topbar")
    assert has_element?(view, "#ops-brand-logo")
    assert has_element?(view, ".sr-ops-brand-mark")
    assert has_element?(view, "#ops-profile-menu[phx-hook='DetailsState']")
    assert has_element?(view, "#ops-profile-menu-toggle[aria-label='Open profile menu']")
    assert has_element?(view, "#ops-profile-menu-toggle .pointer-events-none")
    assert has_element?(view, "#ops-profile-menu a[href='/settings/profile']", "Profile")
    refute has_element?(view, ".sr-ops-notification-dot")
  end

  test "dashboard summary cards expose drill-down links", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "a.sr-ops-kpi-card[href='/devices']", "Total Assets")
    assert has_element?(view, "a.sr-ops-kpi-card[href='/observability?tab=events']", "Threat Level")
    assert has_element?(view, "a.sr-ops-kpi-card[href='/services']", "Network Health")
    assert has_element?(view, "a.sr-ops-kpi-card[href='/observability?tab=alerts']", "Active Alerts")
    assert has_element?(view, "a.sr-ops-small-stat[href*='tab=netflows']", "Window")
    assert has_element?(view, "a.sr-ops-small-stat[href*='tab=netflows']", "Conversations")
    assert has_element?(view, "a.sr-ops-metric-card[href='/diagnostics/mtr']", "Destination Latency")
    assert has_element?(view, "a.sr-ops-metric-card[href='/diagnostics/mtr']", "Destination Loss")
    assert has_element?(view, "a.sr-ops-metric-card[href='/services']", "Service Health")
    assert has_element?(view, "[data-testid='threat-intel-summary']")
    assert has_element?(view, "a[href='/settings/networks/threat-intel']", "Manage")
    assert has_element?(view, "a[data-testid='alerts-feed-empty'][href='/observability?tab=alerts']")
  end

  test "dashboard data hydrates while camera previews are still opening", %{conn: conn} do
    test_pid = self()
    camera_source_id = Ecto.UUID.generate()
    stream_profile_id = Ecto.UUID.generate()

    alert =
      alert_fixture(%{
        title: "Dashboard hydration relay probe",
        severity: :warning,
        description: "Verifies relay control does not gate dashboard hydration"
      })

    previous_loader =
      Application.get_env(:serviceradar_web_ng, :camera_relay_candidate_loader)

    previous_manager =
      Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)

    previous_open_result =
      Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)

    on_exit(fn ->
      restore_env(:camera_relay_candidate_loader, previous_loader)
      restore_env(:camera_relay_session_manager, previous_manager)
      restore_env(:camera_relay_session_manager_open_result, previous_open_result)
    end)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_candidate_loader,
      fn _scope, _limit ->
        [
          %{
            camera_source_id: camera_source_id,
            stream_profile_id: stream_profile_id,
            label: "Hydration camera",
            detail: "Primary stream",
            session: nil,
            error: nil
          }
        ]
      end
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      CameraRelaySessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_open_result,
      fn ^camera_source_id, ^stream_profile_id, _opts ->
        send(test_pid, {:camera_preview_open_started, self()})

        receive do
          :finish_camera_preview ->
            {:ok, %{id: Ecto.UUID.generate(), status: :opening}}
        end
      end
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert_receive {:camera_preview_open_started, preview_task}, 10_000
    assert has_element?(view, "[data-testid='alerts-feed'] a[href='/alerts/#{alert.id}']")

    send(preview_task, :finish_camera_preview)
    _html = render_async(view, 5_000)
  end

  test "dashboard KPI metadata includes drill-downs for conditionally hidden cards" do
    cards = Data.empty().kpi_cards

    assert Enum.find(cards, &(&1.title == "Camera Fleet")).href == "/cameras"
    assert Enum.find(cards, &(&1.title == "Wi-Fi Coverage")).href == "/spatial/field-surveys"
  end

  test "NetFlow map hourly rollup predicate includes the current aggregate bucket" do
    assert Data.netflow_map_time_predicate("bucket") == "f.bucket >= date_trunc('hour', $1::timestamptz)"
    assert Data.netflow_map_time_predicate("time") == "f.time >= $1"
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

  test "dashboard package topbar builder opens as dashboard catalog search", %{conn: conn} do
    route_slug = "dashboard-builder-map-#{System.unique_integer([:positive])}"
    create_dashboard_instance!(route_slug)

    {:ok, view, _html} = live(conn, ~p"/dashboards/#{route_slug}")
    expected_query = "in:dashboards dashboard_ref:#{route_slug} limit:100"

    assert has_element?(view, "#srql-query-bar input[name='q'][value='#{expected_query}']")

    html = render_click(view, "srql_builder_toggle", %{})

    assert has_element?(view, "#srql-query-bar input[name='q'][value='#{expected_query}']")
    assert html =~ "Entity"
    refute html =~ "can't be fully represented"
    refute html =~ "can’t be fully represented"
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

    # Summary tiles (except Pressure, which expands in-card sources) deep-link to
    # filtered device inventory queries.
    assert has_element?(view, "a[href*='/devices'][href*='type'][href*='Hypervisor']")
    assert has_element?(view, "a[href*='/devices'][href*='type'][href*='Virtual']", "Guests")
    assert has_element?(view, "a[href*='/devices'][href*='is_available']", "Running")
    assert has_element?(view, "a[href='#virtualization-pressure-details']", "Pressure")
  end

  test "renders honest empty states for feeds that are not implemented yet", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "[data-testid='traffic-map-empty']")
    assert has_element?(view, "[data-testid='security-events-empty']", "No event trend data")
    assert has_element?(view, "[data-testid='alerts-feed-empty']", "No alerts in the last 24 hours")
    refute has_element?(view, "[data-testid='fieldsurvey-heatmap']")
    refute has_element?(view, "[data-testid='camera-operations']")
  end

  test "alerts feed keeps older retained alerts out of the default dashboard window", %{conn: conn} do
    observed_at =
      DateTime.utc_now()
      |> DateTime.add(-2, :day)
      |> DateTime.truncate(:second)

    alert =
      alert_fixture(%{
        title: "Older retained alert",
        severity: :critical,
        description: "Still retained in the alert stream"
      })

    Repo.query!(
      """
      UPDATE platform.alerts
      SET triggered_at = $2, created_at = $2
      WHERE id = $1
      """,
      [alert.id, observed_at]
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard")
    _html = render_async(view, 5_000)

    refute has_element?(view, "[data-testid='alerts-feed'] a[href='/alerts/#{alert.id}']")
    assert has_element?(view, "[data-testid='alerts-feed-empty']", "No alerts in the last 24 hours")
    assert has_element?(view, "a[data-testid='alerts-feed-empty'][href='/observability?tab=alerts']")
  end

  defp create_dashboard_instance!(route_slug) do
    actor = ServiceRadarWebNG.AshTestHelpers.system_actor()

    package =
      DashboardPackage
      |> Ash.Changeset.for_create(:create, package_attrs())
      |> Ash.create!(actor: actor)
      |> Ash.Changeset.for_update(:enable, %{})
      |> Ash.update!(actor: actor)

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
    |> Ash.create!(actor: actor)
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
