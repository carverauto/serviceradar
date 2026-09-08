defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTabsComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTabsComponents

  @moduletag :db_free

  test "keeps interface and flow navigation visible while availability is being checked" do
    html =
      render_component(&DeviceTabsComponents.device_tabs/1,
        device_row: %{"uid" => "sr:router-1"},
        active_tab: "details",
        details_loading: true,
        interface_availability: :checking,
        flow_availability: :checking
      )

    assert html =~ "Interfaces"
    assert html =~ "Flows"
    assert html =~ "Checking interface availability"
    assert html =~ "Checking flows availability"
    assert html =~ "disabled"
  end

  test "an inconclusive probe remains retryable after the details batch completes" do
    html =
      render_component(&DeviceTabsComponents.device_tabs/1,
        device_row: %{"uid" => "sr:router-1"},
        active_tab: "details",
        has_ifaces: true,
        has_flows: true,
        interface_availability: :unknown,
        flow_availability: :unknown
      )

    assert html =~ "Interface availability was inconclusive; open to retry"
    assert html =~ "Flows availability was inconclusive; open to retry"
    refute html =~ "disabled"
  end

  test "hides interface and flow tabs when the probe did not confirm data" do
    html =
      render_component(&DeviceTabsComponents.device_tabs/1,
        device_row: %{"uid" => "sr:router-1"},
        active_tab: "details",
        details_loading: false,
        has_ifaces: false,
        has_flows: false,
        interface_availability: :unknown,
        flow_availability: :unknown
      )

    refute html =~ "Interfaces"
    refute html =~ "Flows"
  end
end
