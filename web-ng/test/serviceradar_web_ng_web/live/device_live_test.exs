defmodule ServiceRadarWebNGWeb.DeviceLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Repo
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

    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")
    assert has_element?(view, "[data-testid='sysmon-profile-label']", "Unassigned")
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

  describe "device show page interfaces tab" do
    setup %{conn: conn} do
      device_uid = "test-device-interfaces-#{System.unique_integer([:positive])}"

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 0,
          hostname: "test-host-interfaces",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      # Insert test interfaces
      Repo.insert_all("interfaces", [
        %{
          timestamp: ~U[2100-01-01 00:00:00Z],
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
          timestamp: ~U[2100-01-01 00:00:00Z],
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

      {:ok, conn: conn, device_uid: device_uid}
    end

    test "renders interfaces table on interfaces tab", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      # Click on interfaces tab
      view
      |> element("[phx-click='change_tab'][phx-value-tab='interfaces']")
      |> render_click()

      html = render(view)
      assert html =~ "eth0"
      assert html =~ "Primary Ethernet"
    end

    test "shows human-readable interface types", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("[phx-click='change_tab'][phx-value-tab='interfaces']")
      |> render_click()

      html = render(view)
      # ethernetCsmacd should be displayed as "Ethernet"
      assert html =~ "Ethernet"
      # softwareLoopback should be displayed as "Loopback"
      assert html =~ "Loopback"
    end

    test "shows status badges for interfaces", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("[phx-click='change_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Should have status badges
      assert has_element?(view, ".badge")
    end

    test "can select interfaces with checkboxes", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("[phx-click='change_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Should have checkboxes for selection
      assert has_element?(view, "input[type=checkbox]")
    end

    test "can toggle interface favorite", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("[phx-click='change_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Click favorite star for first interface
      view
      |> element("[phx-click=toggle_interface_favorite]", "")
      |> render_click()

      # Should show favorited state (star icon changes)
      html = render(view)
      assert html =~ "hero-star"
    end
  end

  describe "interfaces bulk edit" do
    setup %{conn: conn} do
      device_uid = "test-device-bulk-#{System.unique_integer([:positive])}"

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

      Repo.insert_all("interfaces", [
        %{
          timestamp: ~U[2100-01-01 00:00:00Z],
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
          timestamp: ~U[2100-01-01 00:00:00Z],
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
      |> element("[phx-click='change_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Select an interface
      view
      |> element("[phx-click=toggle_interface_select]", "")
      |> render_click()

      html = render(view)
      assert html =~ "Bulk Edit" or html =~ "bulk"
    end

    test "bulk edit modal has all action options", %{conn: conn, device_uid: device_uid} do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}")

      view
      |> element("[phx-click='change_tab'][phx-value-tab='interfaces']")
      |> render_click()

      # Select an interface
      view
      |> element("[phx-click=toggle_interface_select]", "")
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
end
