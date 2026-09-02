defmodule ServiceRadarWebNGWeb.DashboardPackageLive.AccessControlsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.DashboardPackageLive.AccessControls

  @moduletag :unit
  @moduletag :db_free

  test "owners can share without the package share permission" do
    instance = %{owner_id: "user-1"}
    scope = %{user: %{id: "user-1"}}

    assert AccessControls.can_share_instance?(instance, scope)
    assert AccessControls.instance_owner?(instance, scope)
  end

  test "viewers cannot share an instance they do not own" do
    instance = %{owner_id: "other"}
    scope = %{user: %{id: "user-1"}}

    refute AccessControls.can_share_instance?(instance, scope)
  end

  test "share permission holders can share without owning" do
    instance = %{owner_id: "other"}

    scope = %Scope{
      user: %{id: "user-1"},
      permissions: MapSet.new(["dashboards.packages.share"])
    }

    assert AccessControls.can_share_instance?(instance, scope)
  end

  test "view_all does not confer sharing" do
    instance = %{owner_id: "other"}

    scope = %Scope{
      user: %{id: "user-1"},
      permissions: MapSet.new(["dashboards.packages.view_all"])
    }

    refute AccessControls.can_share_instance?(instance, scope)
  end
end
