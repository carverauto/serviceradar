defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntime

  @moduletag :db_free

  describe "tab_content_loading?/3" do
    test "shows the first-load spinner when details are still arriving and no rows exist" do
      assert DeviceTabRuntime.tab_content_loading?(false, true, [])
    end

    test "keeps already-loaded rows visible during a same-device details refresh" do
      refute DeviceTabRuntime.tab_content_loading?(false, true, [%{"if_name" => "eth0"}])
    end

    test "still honors the tab's own loading flag" do
      assert DeviceTabRuntime.tab_content_loading?(true, false, [%{"if_name" => "eth0"}])
    end
  end

  describe "reload_interfaces?/1" do
    test "reloads only when the tab is idle and empty" do
      assert DeviceTabRuntime.reload_interfaces?(%{
               interfaces_loading: false,
               network_interfaces: []
             })
    end

    test "does not wipe a table that already has rows" do
      refute DeviceTabRuntime.reload_interfaces?(%{
               interfaces_loading: false,
               network_interfaces: [%{"if_name" => "eth0"}]
             })
    end

    test "does not start a second load while one is in flight" do
      refute DeviceTabRuntime.reload_interfaces?(%{
               interfaces_loading: true,
               network_interfaces: []
             })
    end
  end
end
