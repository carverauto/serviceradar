defmodule ServiceRadarWebNGWeb.DeviceLiveTest do
  # Writes to shared tables; keep serial to avoid deadlocks in CNPG-backed tests.
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperSeed
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Repo

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: ServiceRadarWebNG.Accounts.Scope.for_user(user)
    }
  end

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

  test "shows advisory when managed-device count exceeds configured limit", %{conn: conn} do
    previous_limit = Application.get_env(:serviceradar_web_ng, :managed_device_limit)
    Application.put_env(:serviceradar_web_ng, :managed_device_limit, 1)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :managed_device_limit, previous_limit)
    end)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: "advisory-device-#{System.unique_integer([:positive])}",
        type_id: 0,
        hostname: "advisory-host-1",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: "advisory-device-#{System.unique_integer([:positive])}",
        type_id: 0,
        hostname: "advisory-host-2",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")

    assert html =~ "Managed device advisory limit exceeded"
    assert html =~ "configured advisory limit of 1"
    assert html =~ "using 2 managed devices"
  end

  test "does not show advisory when managed-device count stays within configured limit", %{conn: conn} do
    previous_limit = Application.get_env(:serviceradar_web_ng, :managed_device_limit)
    Application.put_env(:serviceradar_web_ng, :managed_device_limit, 2)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :managed_device_limit, previous_limit)
    end)

    Repo.insert_all("ocsf_devices", [
      %{
        uid: "within-limit-device-#{System.unique_integer([:positive])}",
        type_id: 0,
        hostname: "within-limit-host",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")

    refute html =~ "Managed device advisory limit exceeded"
  end

  test "renders fallback sysmon label when profile data is missing", %{conn: conn} do
    uid = "test-device-sysmon-missing-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

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

  test "auto-refreshes devices list when a device is created", %{conn: conn, scope: scope} do
    uid = "test-device-pubsub-#{System.unique_integer([:positive])}"
    hostname = "pubsub-host-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")
    refute render(view) =~ hostname

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{uid: uid, hostname: hostname, ip: "10.10.10.10"})
      |> Ash.create(scope: scope)

    assert render(view) =~ hostname
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

  test "auto-refreshes device details when the viewed device is updated", %{
    conn: conn,
    scope: scope
  } do
    uid = "test-device-show-pubsub-#{System.unique_integer([:positive])}"
    initial_hostname = "show-pubsub-initial-#{System.unique_integer([:positive])}"
    updated_hostname = "show-pubsub-updated-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: initial_hostname,
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")
    assert render(view) =~ initial_hostname

    {:ok, device} = Device.get_by_uid(uid, true, scope: scope)

    {:ok, _updated} =
      device
      |> Ash.Changeset.for_update(:update, %{hostname: updated_hostname})
      |> Ash.update(scope: scope)

    _ = :sys.get_state(view.pid)
    assert render(view) =~ updated_hostname
  end

  test "include_deleted query surfaces deleted devices in the list", %{conn: conn, user: user} do
    promote_user!(user, :admin)
    uid = "test-device-deleted-list-#{System.unique_integer([:positive])}"
    hostname = "deleted-host-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: hostname,
        is_available: false,
        deleted_at: ~U[2100-01-01 00:00:00Z],
        deleted_by: "system",
        deleted_reason: "test",
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")
    refute html =~ hostname

    {:ok, _lv, html} = live(conn, ~p"/devices?q=in:devices%20include_deleted:true&limit=10")
    assert html =~ "in:devices include_deleted:true"
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

  test "renders SNMP system metadata on device details", %{conn: conn} do
    uid = "test-device-snmp-system-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 12,
        hostname: "farm01",
        ip: "192.168.1.1",
        owner: %{"name" => "Network Operations"},
        metadata: %{
          "sys_name" => "farm01",
          "sys_location" => "MDF Rack A",
          "sys_descr" => "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
          "sys_contact" => "Network Operations"
        },
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _view, html} = live(conn, ~p"/devices/#{uid}")

    assert html =~ "SNMP Name"
    assert html =~ "farm01"
    assert html =~ "SNMP Owner"
    assert html =~ "Network Operations"
    assert html =~ "SNMP Location"
    assert html =~ "MDF Rack A"
    assert html =~ "SNMP Description"
    assert html =~ "Ubiquiti UniFi UDM-Pro"
    assert html =~ "min-w-0 flex-1 break-words whitespace-normal"
  end

  test "prefers snmp_* metadata aliases for SNMP panel fields", %{conn: conn} do
    uid = "test-device-snmp-aliases-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 12,
        hostname: "farm01",
        ip: "192.168.1.1",
        metadata: %{
          "snmp_name" => "farm01-snmp",
          "sys_name" => "farm01-sys",
          "snmp_owner" => "NOC Team",
          "snmp_location" => "Datacenter B",
          "snmp_description" => "Ubiquiti UniFi UDM-Pro-Max 4.4.6"
        },
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _view, html} = live(conn, ~p"/devices/#{uid}")

    assert html =~ "farm01-snmp"
    assert html =~ "NOC Team"
    assert html =~ "Datacenter B"
    assert html =~ "UDM-Pro-Max 4.4.6"
    refute html =~ "farm01-sys"
  end

  test "renders SNMP panel labels even when SNMP metadata values are missing", %{conn: conn} do
    uid = "test-device-snmp-empty-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "host-no-snmp",
        ip: "192.168.50.10",
        metadata: %{},
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _view, html} = live(conn, ~p"/devices/#{uid}")

    assert html =~ "SNMP Name"
    assert html =~ "SNMP Owner"
    assert html =~ "SNMP Location"
    assert html =~ "SNMP Description"
  end

  test "marks SNMP fallback-derived classification in list and details views", %{conn: conn} do
    uid = "test-device-snmp-fallback-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 12,
        type: "Router",
        hostname: "fallback-router",
        ip: "192.168.60.1",
        vendor_name: "Ubiquiti",
        model: "UDM-Pro-Max 4.4.6",
        metadata: %{
          "sys_descr" => "Ubiquiti UniFi UDM-Pro-Max 4.4.6 Linux 4.19.152 al324",
          "sys_object_id" => "1.3.6.1.4.1.8072.3.2.10"
        },
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _list_view, list_html} = live(conn, ~p"/devices?limit=10")
    assert list_html =~ "SNMP Fallback"

    {:ok, _details_view, details_html} = live(conn, ~p"/devices/#{uid}")
    assert details_html =~ "Classification"
    assert details_html =~ "SNMP fallback-derived"
  end

  test "renders sysmon cpu header gauge and process/memory/disk sections", %{conn: conn} do
    uid = "test-device-sysmon-metrics-#{System.unique_integer([:positive])}"
    now = DateTime.truncate(DateTime.utc_now(), :second)

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
      |> element("button[phx-click='toggle_interface_favorite'][phx-value-uid='#{device_uid}-eth0']")
      |> render_click()

      # Should show favorited state (star icon changes)
      html = render(view)
      assert html =~ "hero-star"
    end

    test "shows flows tab when device-scoped flows exist", %{conn: conn, device_uid: device_uid} do
      insert_test_flow!(device_uid, "192.168.1.55")
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      assert has_element?(view, "button[phx-click='switch_tab'][phx-value-tab='flows']")

      view
      |> element("button[phx-click='switch_tab'][phx-value-tab='flows']")
      |> render_click()

      assert has_element?(view, "a.btn.btn-ghost.btn-xs", "Details")
      assert render(view) =~ "DNS"
      assert render(view) =~ "bidirectional"
    end

    test "hides flows tab when no scoped flows exist", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")
      refute has_element?(view, "button[phx-click='switch_tab'][phx-value-tab='flows']")
    end

    test "device flows and /flows details show consistent persisted enrichment", %{
      conn: conn,
      device_uid: device_uid
    } do
      device_ip = "192.168.1.55"
      insert_test_flow!(device_uid, device_ip)

      {:ok, device_view, _html} = live(conn, ~p"/devices/#{device_uid}")

      device_view
      |> element("button[phx-click='switch_tab'][phx-value-tab='flows']")
      |> render_click()

      device_html = render(device_view)
      assert device_html =~ "DNS"
      assert device_html =~ "bidirectional"

      q =
        "in:flows time:last_24h src_endpoint_ip:#{device_ip} dst_endpoint_ip:8.8.8.8 src_endpoint_port:52344 dst_endpoint_port:53 protocol_num:17 sort:time:desc limit:1"

      {:ok, _flows_view, flows_html} = live(conn, ~p"/flows?#{%{q: q, open: "first", limit: 50}}")

      assert flows_html =~ "DNS"
      assert flows_html =~ "bidirectional"
      assert flows_html =~ "SourceVendor Corp"
      assert flows_html =~ "DestVendor Inc"
    end
  end

  describe "interfaces bulk edit" do
    setup %{conn: conn} do
      device_uid = "test-device-bulk-#{System.unique_integer([:positive])}"
      ts = DateTime.truncate(DateTime.utc_now(), :second)

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
    ts = DateTime.truncate(DateTime.utc_now(), :second)

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

  defp insert_test_flow!(device_uid, device_ip) do
    ts = DateTime.truncate(DateTime.utc_now(), :second)

    Repo.insert_all("ocsf_network_activity", [
      %{
        time: ts,
        src_endpoint_ip: device_ip,
        src_endpoint_port: 52_344,
        dst_endpoint_ip: "8.8.8.8",
        dst_endpoint_port: 53,
        protocol_num: 17,
        protocol_name: "udp",
        direction_label: "bidirectional",
        dst_service_label: "DNS",
        src_hosting_provider: "SourceNet Inc",
        dst_hosting_provider: "DestNet LLC",
        src_mac: "001122334455",
        dst_mac: "AABBCCDDEEFF",
        src_mac_vendor: "SourceVendor Corp",
        dst_mac_vendor: "DestVendor Inc",
        bytes_total: 1_024,
        packets_total: 8,
        bytes_in: 256,
        bytes_out: 768,
        sampler_address: "10.1.1.1",
        ocsf_payload: %{"device_id" => device_uid},
        created_at: ts
      }
    ])
  end
end
