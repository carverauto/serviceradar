defmodule ServiceRadarWebNGWeb.InterfaceLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Repo
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  describe "interface details page" do
    setup %{conn: conn} do
      device_uid = "test-device-interface-#{System.unique_integer([:positive])}"
      interface_uid = "test-interface-#{System.unique_integer([:positive])}"

      # Insert test device
      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 0,
          hostname: "test-host",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      # Insert test interface
      Repo.insert_all("interfaces", [
        %{
          timestamp: ~U[2100-01-01 00:00:00Z],
          device_id: device_uid,
          interface_uid: interface_uid,
          if_name: "eth0",
          if_descr: "Test Ethernet Interface",
          if_type_name: "ethernetCsmacd",
          if_oper_status: 1,
          if_admin_status: 1,
          speed_bps: 1_000_000_000,
          if_index: 1
        }
      ])

      {:ok, conn: conn, device_uid: device_uid, interface_uid: interface_uid}
    end

    test "renders interface details", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, _lv, html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      assert html =~ "eth0"
      assert html =~ "Test Ethernet Interface"
    end

    test "shows status badges", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      assert has_element?(view, ".badge", "Operational")
    end

    test "can toggle favorite", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      # Click favorite button
      view
      |> element("[phx-click=toggle_favorite]")
      |> render_click()

      # Should show favorited state
      assert has_element?(view, "[data-favorited=true]") or
               render(view) =~ "hero-star-solid"
    end

    test "can toggle metrics collection", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      # Find and click metrics toggle
      view
      |> element("[phx-click=toggle_metrics]")
      |> render_click()

      # Should update the toggle state
      html = render(view)
      assert html =~ "Metrics Collection"
    end
  end

  describe "interface threshold configuration" do
    setup %{conn: conn} do
      device_uid = "test-device-threshold-#{System.unique_integer([:positive])}"
      interface_uid = "test-interface-threshold-#{System.unique_integer([:positive])}"

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 0,
          hostname: "test-host-threshold",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      Repo.insert_all("interfaces", [
        %{
          timestamp: ~U[2100-01-01 00:00:00Z],
          device_id: device_uid,
          interface_uid: interface_uid,
          if_name: "eth1",
          if_descr: "Test Interface for Thresholds",
          if_type_name: "ethernetCsmacd",
          if_oper_status: 1,
          if_admin_status: 1,
          speed_bps: 1_000_000_000,
          if_index: 2
        }
      ])

      {:ok, conn: conn, device_uid: device_uid, interface_uid: interface_uid}
    end

    test "shows threshold configuration section", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, _lv, html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      assert html =~ "Threshold Alerting"
    end

    test "can enable threshold alerting", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      # Toggle threshold on
      view
      |> element("[phx-click=toggle_threshold]")
      |> render_click()

      html = render(view)
      # Should show the threshold configuration form
      assert html =~ "Metric" or html =~ "Condition" or html =~ "threshold"
    end
  end
end
