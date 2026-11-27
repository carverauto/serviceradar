defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceEgressComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceEditComponents
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceComponents
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceRuntime

  @moduletag :db_free

  test "apply_interface_settings projects egress fields and interfaces_tab_content renders badge" do
    settings_by_uid = %{
      "if-wan-1" => %{
        metrics_enabled: false,
        metrics_selected: [],
        favorited: false,
        metric_thresholds: %{},
        threshold_enabled: false,
        threshold_value: nil,
        threshold_comparison: nil,
        threshold_metric: nil,
        threshold_severity: :warning,
        internet_egress: true,
        egress_upstream_asn: 174,
        egress_vantage_id: "vantage-1b3a6111",
        egress_port_speed_mbps: 10_000
      }
    }

    interfaces =
      InterfaceData.apply_interface_settings(
        [
          %{
            "interface_uid" => "if-wan-1",
            "if_name" => "xe-0/0/0",
            "speed_bps" => 10_000_000_000
          }
        ],
        settings_by_uid
      )

    [iface] = interfaces
    assert iface["internet_egress"] == true
    assert iface["egress_upstream_asn"] == 174
    assert iface["egress_vantage_id"] == "vantage-1b3a6111"
    assert iface["egress_port_speed_mbps"] == 10_000

    html =
      render_component(&InterfaceComponents.interfaces_tab_content/1,
        interfaces: interfaces,
        selected_interfaces: MapSet.new(),
        favorited_interfaces: MapSet.new(),
        device_uid: "sr:gw-1",
        timezone: "Etc/UTC"
      )

    assert html =~ "Internet Egress · AS174 · 10G"
  end

  test "bulk edit modal exposes Internet egress actions and device edit shows tag hint" do
    bulk_html =
      render_component(&InterfaceComponents.interfaces_bulk_edit_modal/1,
        form: to_form(%{"action" => "favorite"}, as: :bulk),
        selected_count: 2
      )

    assert bulk_html =~ "mark_internet_egress"
    assert bulk_html =~ "Mark as Internet Egress"
    assert bulk_html =~ "clear_internet_egress"
    assert bulk_html =~ "Clear Internet Egress"

    edit_html =
      render_component(&DeviceEditComponents.device_edit_section/1,
        device_row: %{"uid" => "sr:fw-1", "gateway_id" => "gw-1"},
        device_form: to_form(%{"tags" => "internet_egress=true"}, as: :device),
        snmp_credential_form: to_form(%{"version" => "v2c"}, as: :snmp)
      )

    assert edit_html =~ "internet_egress=true"
    assert edit_html =~ "egress_upstream_asn=174"
  end

  test "interfaces_tab_content hides Bulk Edit when can_edit is false and InterfaceRuntime blocks unauthorized bulk edits" do
    interfaces = [%{"interface_uid" => "if-wan-1", "if_name" => "xe-0/0/0"}]

    viewer_html =
      render_component(&InterfaceComponents.interfaces_tab_content/1,
        interfaces: interfaces,
        selected_interfaces: MapSet.new(["if-wan-1"]),
        favorited_interfaces: MapSet.new(),
        device_uid: "sr:gw-1",
        timezone: "Etc/UTC",
        can_edit: false
      )

    refute viewer_html =~ "Bulk Edit"

    editor_html =
      render_component(&InterfaceComponents.interfaces_tab_content/1,
        interfaces: interfaces,
        selected_interfaces: MapSet.new(["if-wan-1"]),
        favorited_interfaces: MapSet.new(),
        device_uid: "sr:gw-1",
        timezone: "Etc/UTC",
        can_edit: true
      )

    assert editor_html =~ "Bulk Edit"

    viewer_scope = %Scope{
      user: %{id: "viewer-1", role: :viewer},
      permissions: MapSet.new(["devices.view"])
    }

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_scope: viewer_scope,
        selected_interfaces: MapSet.new(["if-wan-1"]),
        device_uid: "sr:gw-1",
        show_interfaces_bulk_edit: true
      }
    }

    denied_open = InterfaceRuntime.open_bulk_edit(socket)
    assert denied_open.assigns.flash["error"] =~ "permission"

    denied_apply =
      InterfaceRuntime.apply_bulk_edit(socket, %{"action" => "mark_internet_egress"}, nil)

    assert denied_apply.assigns.show_interfaces_bulk_edit == false
    assert denied_apply.assigns.flash["error"] =~ "permission"
  end
end
