defmodule ServiceRadarWebNG.Dashboards.GroupAccessContractTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardAccessGrant
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardInstanceAccessGrant
  alias ServiceRadarWebNG.Dashboards.GroupAccess

  @moduletag :db_free

  test "the dashboard audience boundary exposes only bounded target-typed pages" do
    assert Code.ensure_loaded?(GroupAccess)
    assert function_exported?(GroupAccess, :page, 4)
    assert function_exported?(GroupAccess, :ensure_group_view, 4)
    assert function_exported?(GroupAccess, :ensure_group_view, 5)
    assert function_exported?(GroupAccess, :revoke_group_view, 4)
    assert function_exported?(GroupAccess, :revoke_group_view, 5)
    assert function_exported?(GroupAccess, :set_group_access, 5)
    assert function_exported?(GroupAccess, :set_group_access, 6)

    for resource <- [AuthoredDashboard, DashboardInstance] do
      assert %{pagination: %{keyset?: true, default_limit: 50, max_page_size: 50}} =
               Info.action(resource, :policy_editor_audience, :read)

      assert %{get?: true} =
               Info.action(resource, :policy_editor_group_access_target, :read)

      assert %{get?: true} =
               Info.action(resource, :local_group_access_target, :read)
    end
  end

  test "group grant resource actions are guarded and absent from the public code interface" do
    for resource <- [DashboardAccessGrant, DashboardInstanceAccessGrant],
        action_name <- [
          :ensure_group_view,
          :set_group_access,
          :revoke_group_view,
          :revoke_group_access
        ] do
      action = Info.action(resource, action_name)
      assert action

      assert Enum.any?(action.changes, fn
               %{validation: {ServiceRadar.Dashboards.Changes.RequireGroupAccessBoundary, _}} ->
                 true

               _ ->
                 false
             end)
    end

    refute function_exported?(DashboardAccessGrant, :create_group_grant, 2)
    refute function_exported?(DashboardInstanceAccessGrant, :create_group_grant, 2)
  end

  test "ensure-view actions encode a monotonic partial-identity upsert" do
    for resource <- [DashboardAccessGrant, DashboardInstanceAccessGrant] do
      assert %{
               type: :create,
               upsert?: true,
               upsert_identity: :unique_group_grant,
               return_skipped_upsert?: true,
               upsert_condition: condition,
               upsert_fields: fields
             } = Info.action(resource, :ensure_group_view, :create)

      refute is_nil(condition)
      assert fields == [:access, :granted_by_id, :updated_at]
    end
  end
end
