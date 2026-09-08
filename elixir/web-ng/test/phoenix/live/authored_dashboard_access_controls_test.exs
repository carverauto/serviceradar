defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControlsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.AccessControls

  @moduletag :unit
  @moduletag :db_free

  test "owners with schedule permission can schedule private dashboards" do
    dashboard = %{visibility: :private, owner_id: "user-1"}
    assigns = %{can_schedule_reports?: true, can_edit?: false, current_scope: %{user: %{id: "user-1"}}}

    assert AccessControls.can_schedule_dashboard?(dashboard, assigns)
  end

  test "viewers with schedule permission can schedule public reports" do
    dashboard = %{visibility: :public, owner_id: "other"}
    assigns = %{can_schedule_reports?: true, can_edit?: false, current_scope: %{user: %{id: "user-1"}}}

    assert AccessControls.can_schedule_dashboard?(dashboard, assigns)
  end

  test "viewers cannot schedule private dashboards they do not own" do
    dashboard = %{visibility: :private, owner_id: "other"}
    assigns = %{can_schedule_reports?: true, can_edit?: false, current_scope: %{user: %{id: "user-1"}}}

    refute AccessControls.can_schedule_dashboard?(dashboard, assigns)
  end

  test "schedule permission is still required for public dashboards" do
    dashboard = %{visibility: :public, owner_id: nil}
    assigns = %{can_schedule_reports?: false, can_edit?: true, current_scope: %{user: %{id: "user-1"}}}

    refute AccessControls.can_schedule_dashboard?(dashboard, assigns)
  end
end
