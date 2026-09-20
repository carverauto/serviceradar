defmodule ServiceRadarWebNGWeb.DeviceLive.IndexViewTableTagsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ServiceRadarWebNGWeb.DeviceLive.IndexView.Table

  @moduletag :db_free

  test "device list omits the Tags column and uses the 10-column empty colspan" do
    html = render_table(%{})
    refute html =~ ">Tags</th>"
    assert html =~ ~s(colspan="10")
  end

  test "device list with composite verdicts uses the 11-column empty colspan" do
    html = render_table(%{"sr:host-alpha" => %{verdict: :pass}})
    refute html =~ ">Tags</th>"
    assert html =~ ~s(colspan="11")
    assert html =~ "Verdict"
  end

  defp render_table(verdicts) do
    render_component(&Table.render/1,
      devices: [],
      selected_devices: MapSet.new(),
      all_selected: false,
      icmp_sparklines: %{},
      icmp_error: nil,
      effective_availability_by_device: %{},
      composite_verdicts_by_device: verdicts,
      snmp_presence: %{},
      sysmon_presence: %{},
      sysmon_profiles_by_device: %{},
      agent_device_uids: MapSet.new(),
      total_device_count: 0,
      current_page: 1,
      pagination: %{},
      srql: %{query: "in:devices"},
      limit: 20,
      devices_return_path: "/devices",
      current_scope: %{user: %{timezone: "Etc/UTC"}}
    )
  end
end
