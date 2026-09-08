defmodule ServiceRadar.Identity.PrivilegeMutationResourceContractTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership

  @boundary_context %{privilege_boundary_owned: true}
  @boundary_error "must be called through the privilege mutation boundary"

  test "atomic cache changes install transaction hooks unless the boundary owns effects" do
    for {change, resource} <- [
          {ServiceRadar.Identity.Changes.InvalidateRbacCache, RoleProfile},
          {ServiceRadar.Identity.Changes.InvalidateUserRbacCache, User}
        ] do
      changeset = Ash.Changeset.new(resource)
      assert {:ok, atomic} = change.atomic(changeset, [], %{})
      assert [_hook] = atomic.after_transaction

      owned = Ash.Changeset.set_context(changeset, @boundary_context)
      assert {:ok, suppressed} = change.atomic(owned, [], %{})
      assert suppressed.after_transaction == []
    end
  end

  test "custom role-profile writes are boundary guarded and absent from the code interface" do
    assert %{type: :create, accept: [:name, :description, :permissions]} =
             Info.action(RoleProfile, :create)

    assert %{type: :update, accept: [:name, :description, :permissions]} =
             Info.action(RoleProfile, :update)

    assert %{type: :destroy} = Info.action(RoleProfile, :destroy)
    assert %{type: :create} = Info.action(RoleProfile, :create_system)
    assert %{type: :update} = Info.action(RoleProfile, :update_system)

    assert Enum.map(Info.interfaces(RoleProfile), & &1.name) == [
             :list,
             :get_by_id,
             :create_system_profile,
             :update_system_profile
           ]
  end

  test "profile deletion has dedicated boundary-owned user and group clear actions" do
    assert %{type: :update, accept: []} = Info.action(User, :clear_role_profile_for_boundary)

    assert %{type: :update, accept: []} =
             Info.action(UserGroup, :clear_role_profile_for_boundary)
  end

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

  test "group profile and delete constructors accept owned context and reject unowned calls" do
    group = %UserGroup{
      id: "11111111-1111-4111-8111-111111111111",
      name: "Synthetic group"
    }

    attrs = %{role_profile_id: "22222222-2222-4222-8222-222222222222"}

    assert group
           |> Ash.Changeset.for_update(:assign_role_profile, attrs, context: @boundary_context)
           |> valid_boundary_changeset?()

    assert group
           |> Ash.Changeset.for_update(:assign_role_profile, attrs)
           |> boundary_error?()

    assert group
           |> Ash.Changeset.for_update(:clear_role_profile, %{}, context: @boundary_context)
           |> valid_boundary_changeset?()

    assert group
           |> Ash.Changeset.for_update(:clear_role_profile, %{})
           |> boundary_error?()

    assert group
           |> Ash.Changeset.for_destroy(:destroy, %{}, context: @boundary_context)
           |> valid_boundary_changeset?()

    assert group
           |> Ash.Changeset.for_destroy(:destroy, %{})
           |> boundary_error?()
  end

  test "manual and IdP membership constructors accept owned context and reject unowned calls" do
    attrs = %{
      group_id: "33333333-3333-4333-8333-333333333333",
      user_id: "44444444-4444-4444-8444-444444444444",
      metadata: %{}
    }

    for action <- [:create_manual, :create_idp] do
      assert UserGroupMembership
             |> Ash.Changeset.for_create(action, attrs, context: @boundary_context)
             |> valid_boundary_changeset?()

      assert UserGroupMembership
             |> Ash.Changeset.for_create(action, attrs)
             |> boundary_error?()
    end
  end

  test "manual and IdP membership destroy constructors accept owned context and reject unowned calls" do
    for source <- [:manual, :idp] do
      membership = %UserGroupMembership{
        id: "66666666-6666-4666-8666-666666666666",
        group_id: "77777777-7777-4777-8777-777777777777",
        user_id: "88888888-8888-4888-8888-888888888888",
        source: source
      }

      assert membership
             |> Ash.Changeset.for_destroy(:destroy, %{}, context: @boundary_context)
             |> valid_boundary_changeset?()

      assert membership
             |> Ash.Changeset.for_destroy(:destroy, %{})
             |> boundary_error?()
    end
  end

  test "custom profile create constructor accepts owned context and rejects an unowned call" do
    attrs = %{
      name: "Synthetic custom profile",
      description: "Invented constructor fixture",
      permissions: ["devices.view"]
    }

    assert RoleProfile
           |> Ash.Changeset.for_create(:create, attrs, context: @boundary_context)
           |> valid_boundary_changeset?()

    assert RoleProfile
           |> Ash.Changeset.for_create(:create, attrs)
           |> boundary_error?()
  end

  test "custom profile update and destroy constructors accept owned context and reject unowned calls" do
    profile = %RoleProfile{
      id: "55555555-5555-4555-8555-555555555555",
      name: "Synthetic existing profile",
      description: "Invented constructor fixture",
      permissions: ["devices.view"],
      system: false
    }

    assert profile
           |> Ash.Changeset.for_update(
             :update,
             %{description: "Synthetic update"},
             context: @boundary_context
           )
           |> valid_boundary_changeset?()

    assert profile
           |> Ash.Changeset.for_update(:update, %{description: "Synthetic update"})
           |> boundary_error?()

    assert profile
           |> Ash.Changeset.for_destroy(:destroy, %{}, context: @boundary_context)
           |> valid_boundary_changeset?()

    assert profile
           |> Ash.Changeset.for_destroy(:destroy, %{})
           |> boundary_error?()
  end

  test "setting owned context after action selection does not erase a boundary error" do
    changeset =
      RoleProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Synthetic late-context profile",
        permissions: ["devices.view"]
      })
      |> Ash.Changeset.set_context(@boundary_context)

    refute changeset.valid?
    assert boundary_error?(changeset)
  end

  defp valid_boundary_changeset?(changeset) do
    changeset.valid? and not boundary_error?(changeset)
  end

  defp boundary_error?(changeset) do
    Enum.any?(changeset.errors, &(Exception.message(&1) == @boundary_error))
  end
end
