defmodule ServiceRadar.Identity.PrivilegeMutationResourceContractTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership

  test "group profile and delete actions are boundary guarded and not code-interface mutations" do
    assert %{accept: [:role_profile_id]} = Info.action(UserGroup, :assign_role_profile)
    assert %{accept: []} = Info.action(UserGroup, :clear_role_profile)
    assert %{type: :destroy} = Info.action(UserGroup, :destroy)

    assert Info.action(UserGroup, :update).accept == [:name, :description, :metadata]

    assert Enum.map(Info.interfaces(UserGroup), & &1.name) == [
             :list,
             :create_group,
             :update_group
           ]
  end

  test "membership writes are dedicated boundary actions without code-interface escape hatches" do
    assert %{type: :create, upsert?: true} = Info.action(UserGroupMembership, :create_manual)

    assert %{type: :create, upsert?: true, return_skipped_upsert?: true} =
             Info.action(UserGroupMembership, :create_idp)

    assert %{type: :destroy} = Info.action(UserGroupMembership, :destroy)
    refute Info.action(UserGroupMembership, :create)
    refute Info.action(UserGroupMembership, :update)

    assert Enum.map(Info.interfaces(UserGroupMembership), & &1.name) == [
             :list,
             :list_by_user
           ]
  end
end
