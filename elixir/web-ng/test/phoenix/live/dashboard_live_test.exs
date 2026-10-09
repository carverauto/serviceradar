defmodule ServiceRadarWebNGWeb.DashboardLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.Source, as: CameraSource
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationStorageSystem
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.TestSupport.CameraRelaySessionManagerStub
  alias ServiceRadarWebNGWeb.DashboardLive.Data

  @moduletag :web_ng_shared_fixture_db

  setup :register_and_log_in_user

  test "renders the operations dashboard inside the authenticated shell", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dashboard")

    assert html =~ "Unified Operations Dashboard"
    assert has_element?(view, "[data-testid='operations-dashboard']")
    assert has_element?(view, "a[aria-current='page'][href='/dashboard']")
    assert has_element?(view, "#ops-traffic-map[phx-hook='OperationsTrafficMap']")
    assert has_element?(view, "select[name='map_view']", "NetFlow Map")
    # Full Screen carries the panel's NetFlow window (default last_15m).
    assert has_element?(view, "a[href='/netflow-map?window=last_15m']", "Full Screen")
    assert has_element?(view, "#ops-traffic-map[data-topology-links]")
    assert has_element?(view, "a.sr-ops-topbar-icon[href='/observability/alerts'][aria-label='Alerts']")
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
    assert has_element?(view, "a.sr-ops-kpi-card[href='/observability/events']", "Threat Level")
    assert has_element?(view, "a.sr-ops-kpi-card[href='/services']", "Network Health")
    assert has_element?(view, "a.sr-ops-kpi-card[href='/observability/alerts']", "Active Alerts")
    assert has_element?(view, "a.sr-ops-small-stat[href^='/observability/netflows?']", "Window")
    assert has_element?(view, "a.sr-ops-small-stat[href^='/observability/netflows?']", "Conversations")
    assert has_element?(view, "a.sr-ops-metric-card[href='/diagnostics/mtr']", "Destination Latency")
    assert has_element?(view, "a.sr-ops-metric-card[href='/diagnostics/mtr']", "Destination Loss")
    assert has_element?(view, "a.sr-ops-metric-card[href='/services']", "Service Health")
    assert has_element?(view, "[data-testid='threat-intel-summary']")
    assert has_element?(view, "a[href='/settings/networks/threat-intel']", "Manage")
    assert has_element?(view, "a[data-testid='alerts-feed-empty'][href='/observability/alerts']")
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

    # Dashboard slices hydrate asynchronously; the feed must arrive while the
    # camera preview task is still blocked.
    assert eventually_has_element?(
             view,
             "[data-testid='alerts-feed'] a[href='/alerts/#{alert.id}']",
             5_000
           )

    send(preview_task, :finish_camera_preview)
    _html = render_async(view, 5_000)
  end

  test "dashboard KPI metadata includes drill-downs for conditionally hidden cards" do
    cards = Data.empty().kpi_cards

    assert Enum.find(cards, &(&1.title == "Camera Fleet")).href == "/cameras"
    assert Enum.find(cards, &(&1.title == "Wi-Fi Coverage")).href == "/spatial/field-surveys"
  end

  describe "camera preview viewer teardown" do
    setup %{conn: conn} do
      test_pid = self()
      user = admin_user_fixture()

      {:ok, source} =
        CameraSource.create_source(
          %{
            device_uid: "sr:#{Ecto.UUID.generate()}",
            vendor: "axis",
            vendor_camera_id: "preview-#{Ecto.UUID.generate()}",
            display_name: "Example preview camera",
            availability_status: "online"
          },
          actor: system_actor()
        )

      profile_id = Ecto.UUID.generate()
      session = %RelaySession{id: Ecto.UUID.generate(), status: :active, media_ingest_id: "core-media-example"}

      candidate = %{
        camera_source_id: source.id,
        stream_profile_id: profile_id,
        label: source.display_name,
        detail: "Primary stream",
        source_status: "online",
        session: nil,
        error: nil
      }

      overrides = [
        camera_relay_candidate_loader: fn _scope, _limit ->
          send(test_pid, {:preview_candidates_loaded, source.id})
          [candidate]
        end,
        camera_relay_session_manager: CameraRelaySessionManagerStub,
        camera_relay_session_manager_open_result: fn camera_id, stream_id, _opts ->
          send(test_pid, {:preview_opened, camera_id, stream_id})
          {:ok, session}
        end,
        camera_relay_poll_interval_ms: 120_000
      ]

      previous = Enum.map(overrides, fn {key, _value} -> {key, Application.get_env(:serviceradar_web_ng, key)} end)
      Enum.each(overrides, fn {key, value} -> Application.put_env(:serviceradar_web_ng, key, value) end)
      on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

      %{conn: log_in_user(conn, user), source_id: source.id, profile_id: profile_id, relay_id: session.id}
    end

    for {path, tiles_key, player_prefix} <- [
          {"/dashboard", :camera_preview_tiles, "dashboard-camera-relay"},
          {"/cameras", :camera_tiles, "camera-multiview-relay"}
        ] do
      test "#{path} keeps its mounted preview after viewers close WebRTC", ctx do
        %{conn: conn, relay_id: relay_id, source_id: source_id, profile_id: profile_id} = ctx
        {:ok, view, _html} = live(conn, unquote(path))
        _html = render_async(view, 10_000)
        player_selector = "##{unquote(player_prefix)}-#{relay_id}"

        assert has_element?(view, player_selector)
        assert_received {:preview_candidates_loaded, ^source_id}
        assert_received {:preview_opened, ^source_id, ^profile_id}

        before_socket = :sys.get_state(view.pid).socket
        tiles = Map.fetch!(before_socket.assigns, unquote(tiles_key))
        assert MapSet.member?(before_socket.assigns.camera_relay_subscriptions, relay_id)
        monitor = Process.monitor(view.pid)

        # A second viewer can close the same shared session from another page.
        for _viewer <- 1..2 do
          viewer_id = Ecto.UUID.generate()
          :ok = RelayPubSub.viewer_join(relay_id, viewer_id, %{transport: "membrane_webrtc"})

          :ok =
            RelayPubSub.viewer_leave(relay_id, viewer_id, %{
              transport: "membrane_webrtc",
              reason: "viewer closed webrtc signaling session"
            })

          # The broadcast and this barrier originate in this process, so the
          # closure has been handled before state and rendering are asserted.
          after_socket = :sys.get_state(view.pid).socket
          assert Map.fetch!(after_socket.assigns, unquote(tiles_key)) == tiles
          assert Process.alive?(view.pid)
          assert render(view) =~ "Example preview camera"
          assert has_element?(view, player_selector)
        end

        send(view.pid, {:unexpected_relay_event, %{relay_session_id: relay_id}})
        assert render(view) =~ "Example preview camera"
        refute_received {:DOWN, ^monitor, :process, _, _}
        refute_received {:preview_candidates_loaded, _}
        refute_received {:preview_opened, _, _}
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  test "NetFlow map hourly rollup predicate includes the current aggregate bucket" do
    assert Data.netflow_map_time_predicate("bucket") == "f.bucket >= date_trunc('hour', $1::timestamptz)"
    assert Data.netflow_map_time_predicate("time") == "f.time >= $1"
  end

  test "dashboard falls back to NetFlow for unsupported map modes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    html = render_hook(view, "select_map_view", %{"map_view" => "unsupported"})

    assert html =~ "NetFlow Map"
    assert has_element?(view, "a[href='/netflow-map?window=last_15m']", "Full Screen")
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
    # The builder opens on the dashboards catalog entity, fully representable.
    assert html =~ "Query Builder"
    assert html =~ ~r/<option value="dashboards" selected/
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

    # New Proxmox rows must carry an authoritative v3 identity (insert guard).
    integration_id = Ecto.UUID.generate()
    controller_id = Ecto.UUID.generate()
    cluster = "dashboard-cluster-#{unique}"

    {:ok, host_identity} =
      IntegrationIdentity.proxmox_v3_fields(
        integration_id,
        controller_id,
        cluster,
        "node",
        "dashboard-pve-#{unique}"
      )

    {:ok, guest_identity} =
      IntegrationIdentity.proxmox_v3_fields(integration_id, controller_id, cluster, "qemu", 100)

    host_attrs =
      Map.merge(host_identity, %{
        provider: "proxmox",
        device_uid: host_uid,
        name: "dashboard-pve-#{unique}",
        status: "online",
        cpu_ratio: 0.91,
        memory_used_bytes: 90,
        memory_total_bytes: 100,
        observed_at: observed_at
      })

    {:ok, host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(:create, host_attrs)
      |> Ash.create(actor: system_actor())

    guest_attrs =
      Map.merge(guest_identity, %{
        provider: "proxmox",
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

    {:ok, _guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(:create, guest_attrs)
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
    # The shared-fixture lane can hold OCSF events committed by other tests.
    # Clear the default events window (last_24h, raw-table path) inside this
    # test's sandbox transaction; the rollback restores them afterwards.
    Repo.query!("DELETE FROM platform.ocsf_events WHERE time >= now() - interval '25 hours'", [])

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    # Wait for every dashboard slice, including the events window, to finish
    # loading so the empty state is asserted on hydrated data, not the mount.
    _html = render_async(view, 10_000)

    assert has_element?(view, "[data-testid='traffic-map-empty']")
    assert has_element?(view, "[data-testid='security-events-empty']", "No event trend data")
    assert has_element?(view, "[data-testid='alerts-feed-empty']", "No alerts in the last 24 hours")
    refute has_element?(view, "[data-testid='fieldsurvey-heatmap']")
    refute has_element?(view, "[data-testid='camera-operations']")
  end

  test "alerts feed keeps older retained alerts out of the default dashboard window", %{conn: conn} do
    observed_at =
      DateTime.utc_now()
      |> DateTime.shift(day: -2)
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
      [Ecto.UUID.dump!(alert.id), observed_at]
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard")
    _html = render_async(view, 5_000)

    refute has_element?(view, "[data-testid='alerts-feed'] a[href='/alerts/#{alert.id}']")
    assert has_element?(view, "[data-testid='alerts-feed-empty']", "No alerts in the last 24 hours")
    assert has_element?(view, "a[data-testid='alerts-feed-empty'][href='/observability/alerts']")
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

  defp eventually_has_element?(view, selector, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_has_element?(view, selector, deadline)
  end

  defp poll_has_element?(view, selector, deadline) do
    cond do
      has_element?(view, selector) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        poll_has_element?(view, selector, deadline)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
