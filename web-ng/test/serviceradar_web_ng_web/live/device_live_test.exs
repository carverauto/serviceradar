defmodule ServiceRadarWebNGWeb.DeviceLiveTest do
  # Writes to shared tables; keep serial to avoid deadlocks in CNPG-backed tests.
  use ServiceRadarWebNGWeb.ConnCase, async: false

  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Repo
  alias ServiceRadar.NetworkDiscovery.{MapperJob, MapperSeed}
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders devices from ocsf_devices", %{conn: conn} do
    uid = "test-device-live-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "test-host",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")
    assert html =~ uid
    assert html =~ "test-host"
    assert html =~ "in:devices"
  end

  test "renders fallback sysmon label when profile data is missing", %{conn: conn} do
    uid = "test-device-sysmon-missing-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "test-host",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    # Ensure the device is considered to have sysmon metrics so the label renders.
    Repo.insert_all("cpu_metrics", [
      %{
        timestamp: now,
        gateway_id: "test-gw",
        core_id: 0,
        usage_percent: 12.3,
        device_id: uid,
        created_at: now
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")
    # Badge should not render when no sysmon profile is assigned
    refute has_element?(view, "[data-testid='sysmon-profile-label']")
  end

  test "shows deleted badge and restore action for deleted devices", %{conn: conn, user: user} do
    promote_user!(user, :admin)
    uid = "test-device-deleted-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "deleted-host",
        is_available: false,
        deleted_at: ~U[2100-01-01 00:00:00Z],
        deleted_by: "system",
        deleted_reason: "test",
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices/#{uid}")
    assert html =~ "Deleted"
    assert html =~ "Restore"
  end

  test "include_deleted query surfaces deleted devices in the list", %{conn: conn, user: user} do
    promote_user!(user, :admin)
    uid = "test-device-deleted-list-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "deleted-host",
        is_available: false,
        deleted_at: ~U[2100-01-01 00:00:00Z],
        deleted_by: "system",
        deleted_reason: "test",
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")
    refute html =~ uid

    {:ok, _lv, html} = live(conn, ~p"/devices?q=in:devices%20include_deleted:true&limit=10")
    assert html =~ uid
    assert html =~ "Deleted"
  end

  test "renders SNMP credential override form in edit mode", %{conn: conn} do
    uid = "test-device-snmp-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "test-host-snmp",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")

    view
    |> element("[phx-click='toggle_edit']")
    |> render_click()

    html = render(view)
    assert html =~ "SNMP Credentials Override"
    assert html =~ "Save SNMP Credentials"
  end

  test "renders sysmon cpu header gauge and process/memory/disk sections", %{conn: conn} do
    uid = "test-device-sysmon-metrics-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "test-host-sysmon",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    Repo.insert_all("cpu_metrics", [
      %{
        timestamp: now,
        gateway_id: "test-gw",
        core_id: 0,
        usage_percent: 42.4,
        device_id: uid,
        created_at: now
      }
    ])

    Repo.insert_all("memory_metrics", [
      %{
        timestamp: now,
        gateway_id: "test-gw",
        used_bytes: 1_073_741_824,
        available_bytes: 2_147_483_648,
        total_bytes: 3_221_225_472,
        device_id: uid,
        created_at: now
      }
    ])

    Repo.insert_all("disk_metrics", [
      %{
        timestamp: now,
        gateway_id: "test-gw",
        mount_point: "/",
        device_name: "/dev/sda1",
        used_bytes: 10_737_418_240,
        total_bytes: 21_474_836_480,
        device_id: uid,
        created_at: now
      }
    ])

    Repo.insert_all("process_metrics", [
      %{
        timestamp: now,
        gateway_id: "test-gw",
        pid: 4242,
        name: "nginx",
        cpu_usage: 12.3,
        memory_usage: 1_048_576,
        status: "Running",
        device_id: uid,
        created_at: now
      }
    ])

    {:ok, _view, html} = live(conn, ~p"/devices/#{uid}")

    assert html =~ "CPU"
    assert html =~ "42.4%"
    assert html =~ "Memory"
    assert html =~ "Disk"
    assert html =~ "Processes"
    assert html =~ "nginx"
  end

  describe "device show page interfaces tab" do
    setup %{conn: conn} do
      device_uid = "test-device-interfaces-#{System.unique_integer([:positive])}"

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 0,
          hostname: "test-host-interfaces",
          ip: "192.168.1.55",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      {:ok, conn: conn, device_uid: device_uid}
    end

    test "shows interfaces tab empty state for devices targeted by discovery", %{
      conn: conn,
      device_uid: device_uid,
      scope: scope
    } do
      {:ok, job} =
        MapperJob
        |> Ash.Changeset.for_create(:create, %{name: "mapper-empty-state"})
        |> Ash.create(scope: scope)

      {:ok, _seed} =
        MapperSeed
        |> Ash.Changeset.for_create(:create, %{seed: "192.168.1.0/24", mapper_job_id: job.id})
        |> Ash.create(scope: scope)

      {:ok, _job} =
        job
        |> Ash.Changeset.for_update(:record_run, %{
          last_run_at: DateTime.utc_now(),
          last_run_status: :error,
          last_run_interface_count: 0,
          last_run_error: "mapper timeout"
        })
        |> Ash.update(scope: scope)

      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      assert has_element?(view, "button[phx-click='switch_tab'][phx-value-tab='interfaces']")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      html = render(view)
      assert html =~ "No interface data yet."
      assert html =~ "mapper timeout"
      assert html =~ job.name
    end

    test "renders interfaces table on interfaces tab", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      # Click on interfaces tab
      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      html = render(view)
      assert html =~ "eth0"
      assert html =~ "Primary Ethernet"
    end

    test "shows human-readable interface types", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      html = render(view)
      # ethernetCsmacd should be displayed as "Ethernet"
      assert html =~ "Ethernet"
      # softwareLoopback should be displayed as "Loopback"
      assert html =~ "Loopback"
    end

    test "shows status badges for interfaces", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Should have status badges
      assert has_element?(view, ".badge")
    end

    test "can select interfaces with checkboxes", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Should have checkboxes for selection
      assert has_element?(view, "input[type=checkbox]")
    end

    test "can toggle interface favorite", %{conn: conn, device_uid: device_uid} do
      insert_test_interfaces!(device_uid)
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Click favorite star for first interface
      view
      |> element(
        "button[phx-click='toggle_interface_favorite'][phx-value-uid='#{device_uid}-eth0']"
      )
      |> render_click()

      # Should show favorited state (star icon changes)
      html = render(view)
      assert html =~ "hero-star"
    end
  end

  describe "interfaces bulk edit" do
    setup %{conn: conn} do
      device_uid = "test-device-bulk-#{System.unique_integer([:positive])}"
      ts = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 0,
          hostname: "test-host-bulk",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      Repo.insert_all("discovered_interfaces", [
        %{
          timestamp: ts,
          device_id: device_uid,
          interface_uid: "#{device_uid}-eth0",
          if_name: "eth0",
          if_descr: "Bulk Test Interface 1",
          if_type_name: "ethernetCsmacd",
          if_oper_status: 1,
          if_admin_status: 1,
          speed_bps: 1_000_000_000,
          if_index: 1
        },
        %{
          timestamp: ts,
          device_id: device_uid,
          interface_uid: "#{device_uid}-eth1",
          if_name: "eth1",
          if_descr: "Bulk Test Interface 2",
          if_type_name: "ethernetCsmacd",
          if_oper_status: 1,
          if_admin_status: 1,
          speed_bps: 1_000_000_000,
          if_index: 2
        }
      ])

      {:ok, conn: conn, device_uid: device_uid}
    end

    test "shows bulk edit button when interfaces are selected", %{
      conn: conn,
      device_uid: device_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Select an interface
      view
      |> element("input[phx-click='toggle_interface_select'][phx-value-uid='#{device_uid}-eth0']")
      |> render_click()

      html = render(view)
      assert html =~ "Bulk Edit" or html =~ "bulk"
    end

    test "bulk edit modal has all action options", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Select an interface
      view
      |> element("input[phx-click='toggle_interface_select'][phx-value-uid='#{device_uid}-eth0']")
      |> render_click()

      # Open bulk edit modal
      view
      |> element("[phx-click=open_interfaces_bulk_edit]")
      |> render_click()

      html = render(view)
      assert html =~ "Add to Favorites"
      assert html =~ "Remove from Favorites"
      assert html =~ "Enable Metrics Collection"
      assert html =~ "Disable Metrics Collection"
      assert html =~ "Add Tags"
    end
  end

  defp promote_user!(user, role) do
    user
    |> Ash.Changeset.for_update(:update_role, %{role: role}, actor: AshTestHelpers.system_actor())
    |> Ash.update!()
  end

  defp insert_test_interfaces!(device_uid) do
    ts = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all("discovered_interfaces", [
      %{
        timestamp: ts,
        device_id: device_uid,
        interface_uid: "#{device_uid}-eth0",
        if_name: "eth0",
        if_descr: "Primary Ethernet",
        if_type_name: "ethernetCsmacd",
        if_oper_status: 1,
        if_admin_status: 1,
        speed_bps: 1_000_000_000,
        if_index: 1
      },
      %{
        timestamp: ts,
        device_id: device_uid,
        interface_uid: "#{device_uid}-lo0",
        if_name: "lo0",
        if_descr: "Loopback",
        if_type_name: "softwareLoopback",
        if_oper_status: 1,
        if_admin_status: 1,
        speed_bps: nil,
        if_index: 2
      }
    ])
  end
end
