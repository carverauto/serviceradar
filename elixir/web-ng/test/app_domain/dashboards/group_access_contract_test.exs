defmodule ServiceRadarWebNG.Dashboards.GroupAccessContractTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.Changes.RequireGroupAccessBoundary
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
               %{validation: {RequireGroupAccessBoundary, _}} ->
                 true

               _ ->
                 false
             end)
    end

    for action_name <- [
          :policy_editor_ensure_group_view,
          :policy_editor_set_group_access,
          :policy_editor_revoke_group_view
        ] do
      action = Info.action(DashboardAccessGrant, action_name)
      assert action

      assert Enum.any?(action.changes, fn
               %{validation: {RequireGroupAccessBoundary, _}} -> true
               _ -> false
             end)
    end

    refute function_exported?(DashboardAccessGrant, :create_group_grant, 2)
    refute function_exported?(DashboardInstanceAccessGrant, :create_group_grant, 2)
  end

  test "boundary context is present during construction and ensure view accepts only forced inputs" do
    for {resource, target_key} <- [
          {DashboardAccessGrant, :dashboard_id},
          {DashboardInstanceAccessGrant, :dashboard_instance_id}
        ] do
      attrs = %{
        target_key => Ecto.UUID.generate(),
        subject_group_id: Ecto.UUID.generate(),
        granted_by_id: Ecto.UUID.generate()
      }

      owned =
        Ash.Changeset.for_create(resource, :ensure_group_view, attrs,
          context: %{dashboard_group_access_boundary_owned: true}
        )

      assert owned.valid?, inspect(owned.errors)
      assert owned.attributes.access == :view
      assert owned.attributes.subject_type == :group

      unowned = Ash.Changeset.for_create(resource, :ensure_group_view, attrs)
      refute unowned.valid?

      assert Enum.any?(
               unowned.errors,
               &(Exception.message(&1) =~ "dashboard group access boundary")
             )
    end

    authored_attrs = %{
      dashboard_id: Ecto.UUID.generate(),
      subject_group_id: Ecto.UUID.generate(),
      granted_by_id: Ecto.UUID.generate()
    }

    assert %{valid?: true} =
             Ash.Changeset.for_create(
               DashboardAccessGrant,
               :policy_editor_ensure_group_view,
               authored_attrs,
               context: %{dashboard_group_access_boundary_owned: true}
             )
  end

  test "record and atomic guards reject only unowned group mutations" do
    for resource <- [DashboardAccessGrant, DashboardInstanceAccessGrant] do
      group_record = grant_record(resource, :group)
      user_record = grant_record(resource, :user)

      assert %{valid?: true} =
               Ash.Changeset.for_update(group_record, :update, %{access: :edit},
                 context: %{dashboard_group_access_boundary_owned: true}
               )

      refute Ash.Changeset.for_update(group_record, :update, %{access: :edit}).valid?
      assert Ash.Changeset.for_update(user_record, :update, %{access: :edit}).valid?
      refute Ash.Changeset.for_destroy(group_record, :destroy).valid?
      assert Ash.Changeset.for_destroy(user_record, :destroy).valid?

      atomic_changeset = Ash.Changeset.new(resource)

      assert {:atomic, [:subject_type], invalid_predicate, _error_expr} =
               RequireGroupAccessBoundary.atomic(
                 atomic_changeset,
                 [group_only?: false],
                 %{}
               )

      assert Ash.Expr.eval!(invalid_predicate, resource: resource, record: group_record)
      refute Ash.Expr.eval!(invalid_predicate, resource: resource, record: user_record)
    end
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

      assert condition
      assert fields == [:access, :granted_by_id, :updated_at]
    end
  end

  defp grant_record(resource, subject_type) do
    target =
      case resource do
        DashboardAccessGrant -> %{dashboard_id: Ecto.UUID.generate()}
        DashboardInstanceAccessGrant -> %{dashboard_instance_id: Ecto.UUID.generate()}
      end

    struct(
      resource,
      Map.merge(target, %{
        id: Ecto.UUID.generate(),
        subject_type: subject_type,
        subject_user_id: if(subject_type == :user, do: Ecto.UUID.generate()),
        subject_group_id: if(subject_type == :group, do: Ecto.UUID.generate()),
        access: :view,
        metadata: %{}
      })
    )
  end
end
