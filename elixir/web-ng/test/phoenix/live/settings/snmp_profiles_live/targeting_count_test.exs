defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.TargetingCountTest do
  @moduledoc """
  "N targets" is a DEVICE count. A switch with twelve matching interfaces is
  one target. `distinct(:device_id)` is what makes it one. GitHub #4021.

  This is a source pin, not a DB test: web-ng's Mix formatter cannot borrow
  another project's deps, and the query itself is the load-bearing line.
  Behaviour is covered in
  `ServiceRadar.Inventory.InterfaceCurrentStateTest`.
  """
  use ExUnit.Case, async: true

  test "interface targeting still distincts on device_id" do
    source =
      File.read!(
        Path.expand(
          "../../../../../lib/serviceradar_web_ng_web/live/settings/snmp_profiles_live/index/targeting.ex",
          __DIR__
        )
      )

    assert source =~ "Ash.Query.distinct(query, :device_id)",
           "deleting this distinct turns the SNMP target count from devices into interfaces"
  end
end
