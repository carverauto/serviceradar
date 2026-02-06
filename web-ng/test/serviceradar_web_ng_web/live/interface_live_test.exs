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
      Repo.insert_all("discovered_interfaces", [
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
          if_index: 1,
          available_metrics: [
            %{"name" => "ifInOctets", "category" => "traffic"},
            %{"name" => "ifOutOctets", "category" => "traffic"},
            %{"name" => "ifInErrors", "category" => "errors"}
          ]
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

      assert has_element?(view, ".badge", "Up")
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

      # Find and click a metric toggle
      view
      |> element("button[phx-click=toggle_metric][phx-value-metric='ifInOctets']")
      |> render_click()

      html = render(view)
      assert html =~ "Collecting" or html =~ "Enabled"
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

      Repo.insert_all("discovered_interfaces", [
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
          if_index: 2,
          available_metrics: [
            %{"name" => "ifInOctets", "category" => "traffic"},
            %{"name" => "ifOutOctets", "category" => "traffic"}
          ]
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

      assert html =~ "Metrics Collection"
      assert html =~ "Available Metrics"
    end

    test "can enable threshold alerting", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      # Open metric settings modal via the Available Metrics card
      view
      |> element("div[phx-click=open_metric_modal][phx-value-metric='ifInOctets']", "Inbound Traffic")
      |> render_click()

      assert render(view) =~ "Configure ifInOctets metric"

      # Enable a concrete threshold config (comparison + value) and enable alert promotion.
      view
      |> element("#metric-settings-form")
      |> render_submit(%{
        "metric" => %{
          "name" => "ifInOctets",
          "enabled" => "true",
          "threshold_type" => "absolute",
          "comparison" => "gt",
          "value" => "1000",
          "duration_seconds" => "0",
          "event_severity" => "warning",
          "event_message" => "",
          "alert_enabled" => "true",
          "alert_threshold" => "2",
          "alert_window_seconds" => "60",
          "alert_cooldown_seconds" => "60",
          "alert_renotify_seconds" => "300",
          "alert_severity" => "critical",
          "alert_title" => "",
          "alert_description" => ""
        }
      })

      html = render(view)
      assert html =~ "Metric settings saved"
      assert html =~ "Enabled"
      assert html =~ "Collecting"

      # Event + Alert badges should be enabled (non-ghost styling).
      assert has_element?(view, "span.badge-info", "Event")
      assert has_element?(view, "span.badge-success", "Alert")
    end
  end

  # ============================================================================
  # Task 7.2: Integration tests for composite charts metric grouping
  # See interface_live_metrics_test.exs for unit tests
  # ============================================================================

  describe "composite charts metric grouping" do
    setup %{conn: conn} do
      device_uid = "test-device-groups-#{System.unique_integer([:positive])}"
      interface_uid = "test-interface-groups-#{System.unique_integer([:positive])}"

      Repo.insert_all("ocsf_devices", [
        %{
          uid: device_uid,
          type_id: 0,
          hostname: "test-host-groups",
          is_available: true,
          first_seen_time: ~U[2100-01-01 00:00:00Z],
          last_seen_time: ~U[2100-01-01 00:00:00Z]
        }
      ])

      # Insert interface with available metrics
      Repo.insert_all("discovered_interfaces", [
        %{
          timestamp: ~U[2100-01-01 00:00:00Z],
          device_id: device_uid,
          interface_uid: interface_uid,
          if_name: "eth2",
          if_descr: "Test Interface for Metric Groups",
          if_type_name: "ethernetCsmacd",
          if_oper_status: 1,
          if_admin_status: 1,
          speed_bps: 1_000_000_000,
          if_index: 3,
          available_metrics: [
            %{"name" => "ifInOctets", "category" => "traffic"},
            %{"name" => "ifOutOctets", "category" => "traffic"},
            %{"name" => "ifInErrors", "category" => "errors"},
            %{"name" => "ifOutErrors", "category" => "errors"}
          ]
        }
      ])

      {:ok, conn: conn, device_uid: device_uid, interface_uid: interface_uid}
    end

    test "shows composite charts section", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, _lv, html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      assert html =~ "Composite Charts"
      assert html =~ "New Group"
    end

    test "can open group creation modal", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      # Click New Group button
      view
      |> element("button[phx-click=open_group_modal]")
      |> render_click()

      html = render(view)
      assert html =~ "Create Chart Group"
      assert html =~ "Group Name"
    end

    test "can create a chart group", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      # Open modal
      view
      |> element("button[phx-click=open_group_modal]")
      |> render_click()

      # Submit form with group data
      view
      |> element("#chart-group-form")
      |> render_submit(%{
        "group" => %{
          "id" => "",
          "name" => "Traffic",
          "metrics" => %{"ifInOctets" => "true", "ifOutOctets" => "true"}
        }
      })

      html = render(view)
      # Modal should close and group should appear
      assert html =~ "Traffic"
      assert html =~ "Chart group saved"
      assert html =~ "Inbound Traffic"
      assert html =~ "Outbound Traffic"
    end

    test "can close group modal", %{
      conn: conn,
      device_uid: device_uid,
      interface_uid: interface_uid
    } do
      {:ok, view, _html} = live(conn, ~p"/devices/#{device_uid}/interfaces/#{interface_uid}")

      # Open modal
      view
      |> element("button[phx-click=open_group_modal]")
      |> render_click()

      assert render(view) =~ "Create Chart Group"

      # Close modal
      view
      |> element("button[phx-click=close_group_modal]", "Cancel")
      |> render_click()

      # Modal should be closed
      refute render(view) =~ "Create Chart Group"
    end
  end
end
