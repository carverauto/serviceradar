defmodule ServiceRadar.Identity.PrivilegeMutationBoundariesDbTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.GroupPolicy
  alias ServiceRadar.Identity.PrivilegedMembership
  alias ServiceRadar.Identity.PrivilegeMutationEffects
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.RoleProfilePolicy
  alias ServiceRadar.Identity.RoleProfileSeeder
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    marker = "boundary-#{System.unique_integer([:positive])}"
    on_exit(fn -> cleanup!(marker) end)

    system = SystemActor.system(:privilege_mutation_boundary_test)

    authority_profile =
      profile!(system, marker, ["settings.rbac.manage", "identity.user_groups.manage"])

    actor = user!(system, marker, "actor")

    {:ok, actor} =
      User.update_role_profile(actor, %{role_profile_id: authority_profile.id}, actor: system)

    %{actor: actor, marker: marker, scope: %{user: actor}, system: system}
  end

  test "outer group-policy transactions are rejected before authorization or effects", context do
    group = group!(context.system, context.marker)
    profile = profile!(context.system, context.marker, ["devices.view"])
    member = user!(context.system, context.marker, "outer-member")
    membership = manual_membership!(context.system, group.id, member.id)
    opts = effect_opts(self())

    assert Repo.transaction(fn ->
             [
               GroupPolicy.assign(context.scope, group.id, profile.id, opts),
               GroupPolicy.clear(context.scope, group.id, opts),
               GroupPolicy.delete(context.scope, group.id, opts),
               PrivilegedMembership.add(context.scope, group.id, member.id, %{}, opts),
               PrivilegedMembership.remove(context.scope, membership.id, opts),
               PrivilegedMembership.reconcile_idp(member.id, [group.id],
                 actor: context.system,
                 audit_writer: Keyword.fetch!(opts, :audit_writer),
                 cache_invalidator: Keyword.fetch!(opts, :cache_invalidator)
               )
             ]
           end) ==
             {:ok, List.duplicate({:error, :outer_transaction_not_supported}, 6)}

    refute_receive {:audit, _}
    refute_receive {:invalidate, _}
    assert {:ok, unchanged} = Ash.get(UserGroup, group.id, actor: context.system)
    assert is_nil(unchanged.role_profile_id)

    assert [%UserGroupMembership{id: membership_id}] =
             memberships_for(member.id, context.system)

    assert membership_id == membership.id
  end

  test "outer role-profile lifecycle transactions are rejected before authorization or effects",
       context do
    profile = profile!(context.system, context.marker, ["devices.view"])
    opts = effect_opts(self())

    assert Repo.transaction(fn ->
             [
               RoleProfilePolicy.create(
                 context.scope,
                 %{name: "#{context.marker}-outer-create", permissions: []},
                 opts
               ),
               RoleProfilePolicy.update(
                 context.scope,
                 profile.id,
                 %{description: "blocked"},
                 opts
               ),
               RoleProfilePolicy.delete(context.scope, profile.id, opts)
             ]
           end) ==
             {:ok, List.duplicate({:error, :outer_transaction_not_supported}, 3)}

    refute_receive {:audit, _}
    refute_receive {:invalidate, _}
    assert {:ok, persisted} = Ash.get(RoleProfile, profile.id, actor: context.system)
    assert is_nil(persisted.description)
  end

  test "create update and delete reconstruct current human authority", context do
    update_target = profile!(context.system, context.marker, ["devices.view"])
    delete_target = profile!(context.system, context.marker, ["devices.view"])
    revoke_profile!(context.system, context.actor.role_profile_id)
    opts = effect_opts(self())

    assert RoleProfilePolicy.create(
             context.scope,
             %{name: "#{context.marker}-revoked-create", permissions: []},
             opts
           ) == {:error, :current_authority_denied}

    assert RoleProfilePolicy.update(
             context.scope,
             update_target.id,
             %{description: "must not persist"},
             opts
           ) == {:error, :current_authority_denied}

    assert RoleProfilePolicy.delete(context.scope, delete_target.id, opts) ==
             {:error, :current_authority_denied}

    refute_receive {:audit, _}
    refute_receive {:invalidate, _}
    assert {:ok, unchanged_update} = Ash.get(RoleProfile, update_target.id, actor: context.system)
    assert is_nil(unchanged_update.description)
    assert {:ok, %RoleProfile{}} = Ash.get(RoleProfile, delete_target.id, actor: context.system)
  end

  test "custom profile creation commits before its audit effect", context do
    attrs = %{
      name: "#{context.marker}-created-profile",
      description: "Synthetic created profile",
      permissions: ["devices.view"]
    }

    assert {:ok, %RoleProfile{name: name} = profile} =
             RoleProfilePolicy.create(
               context.scope,
               attrs,
               transaction_observing_effect_opts(self())
             )

    assert name == attrs.name
    refute_receive {:invalidate, _, _}
    assert_receive {:audit, audit, false}
    assert audit[:action] == :create
    assert audit[:resource_id] == profile.id
    assert {:ok, %RoleProfile{id: id}} = Ash.get(RoleProfile, profile.id, actor: context.system)
    assert id == profile.id
  end

  test "profile update invalidates direct and group users once after commit", context do
    profile = profile!(context.system, context.marker, ["devices.view"])
    group = group!(context.system, context.marker)
    direct_and_group = user!(context.system, context.marker, "direct-and-group")
    group_only = user!(context.system, context.marker, "group-only")

    {:ok, _user} =
      User.update_role_profile(
        direct_and_group,
        %{role_profile_id: profile.id},
        actor: context.system
      )

    assign_group_profile!(context.system, group, profile.id)
    manual_membership!(context.system, group.id, direct_and_group.id)
    manual_membership!(context.system, group.id, group_only.id)

    assert {:ok, %RoleProfile{permissions: ["devices.view", "services.view"]}} =
             RoleProfilePolicy.update(
               context.scope,
               profile.id,
               %{permissions: ["devices.view", "services.view"]},
               transaction_observing_effect_opts(self())
             )

    assert_receive {:invalidate, first, false}
    assert_receive {:invalidate, second, false}

    assert MapSet.new([first, second]) ==
             MapSet.new([direct_and_group.id, group_only.id])

    refute_receive {:invalidate, _, _}
    assert_receive {:audit, audit, false}
    assert audit[:action] == :update
  end

  test "profile deletion clears direct and group references atomically", context do
    profile = profile!(context.system, context.marker, ["devices.view"])
    group = group!(context.system, context.marker)
    direct_user = user!(context.system, context.marker, "delete-direct")
    group_user = user!(context.system, context.marker, "delete-group")

    {:ok, _user} =
      User.update_role_profile(
        direct_user,
        %{role_profile_id: profile.id, role_profile_source: :idp},
        actor: context.system
      )

    assign_group_profile!(context.system, group, profile.id)
    manual_membership!(context.system, group.id, group_user.id)

    assert {:ok, %RoleProfile{id: deleted_id}} =
             RoleProfilePolicy.delete(context.scope, profile.id, effect_opts(self()))

    assert deleted_id == profile.id

    assert {:ok, nil} =
             Ash.get(RoleProfile, profile.id,
               actor: context.system,
               not_found_error?: false
             )

    assert {:ok, %{role_profile_id: nil, role_profile_source: :manual}} =
             User.get_by_id(direct_user.id, actor: context.system)

    assert {:ok, %{role_profile_id: nil}} = Ash.get(UserGroup, group.id, actor: context.system)
    assert_receive {:invalidate, first}
    assert_receive {:invalidate, second}
    assert MapSet.new([first, second]) == MapSet.new([direct_user.id, group_user.id])
    refute_receive {:invalidate, _}
    assert_receive {:audit, audit}
    assert audit[:action] == :delete
  end

  test "profile deletion rollback restores the profile and both reference kinds", context do
    profile = profile!(context.system, context.marker, ["devices.view"])
    group = group!(context.system, context.marker)
    direct_user = user!(context.system, context.marker, "rollback-direct")
    group_user = user!(context.system, context.marker, "rollback-group")

    {:ok, _user} =
      User.update_role_profile(direct_user, %{role_profile_id: profile.id}, actor: context.system)

    assign_group_profile!(context.system, group, profile.id)
    manual_membership!(context.system, group.id, group_user.id)

    opts =
      self()
      |> effect_opts()
      |> Keyword.put(:after_references_cleared, fn -> {:error, :synthetic_delete_failure} end)

    assert RoleProfilePolicy.delete(context.scope, profile.id, opts) ==
             {:error, :synthetic_delete_failure}

    refute_receive {:audit, _}
    refute_receive {:invalidate, _}
    assert {:ok, %RoleProfile{}} = Ash.get(RoleProfile, profile.id, actor: context.system)

    assert {:ok, %{role_profile_id: direct_profile_id}} =
             User.get_by_id(direct_user.id, actor: context.system)

    assert direct_profile_id == profile.id

    assert {:ok, %{role_profile_id: group_profile_id}} =
             Ash.get(UserGroup, group.id, actor: context.system)

    assert group_profile_id == profile.id
  end

  test "raw custom-profile and boundary clear actions fail without boundary context", context do
    profile = profile!(context.system, context.marker, ["devices.view"])
    group = group!(context.system, context.marker)
    user = user!(context.system, context.marker, "raw-profile")

    assert {:error, create_error} =
             RoleProfile
             |> Ash.Changeset.for_create(:create, %{
               name: "#{context.marker}-raw-create",
               permissions: []
             })
             |> Ash.create(actor: context.system)

    assert Exception.message(create_error) =~ "privilege mutation boundary"

    assert {:error, update_error} =
             profile
             |> Ash.Changeset.for_update(:update, %{description: "blocked"})
             |> Ash.update(actor: context.system)

    assert Exception.message(update_error) =~ "privilege mutation boundary"

    assert {:error, destroy_error} =
             profile
             |> Ash.Changeset.for_destroy(:destroy, %{})
             |> Ash.destroy(actor: context.system)

    assert Exception.message(destroy_error) =~ "privilege mutation boundary"

    assert {:error, user_clear_error} =
             user
             |> Ash.Changeset.for_update(:clear_role_profile_for_boundary, %{})
             |> Ash.update(actor: context.system)

    assert Exception.message(user_clear_error) =~ "privilege mutation boundary"

    assert {:error, group_clear_error} =
             group
             |> Ash.Changeset.for_update(:clear_role_profile_for_boundary, %{})
             |> Ash.update(actor: context.system)

    assert Exception.message(group_clear_error) =~ "privilege mutation boundary"
  end

  test "trusted system profile create and update actions remain distinct", context do
    system_name = "#{context.marker}-trusted-system"

    assert {:ok, profile} =
             RoleProfile.create_system_profile(
               %{
                 system_name: system_name,
                 name: "#{context.marker}-trusted-system",
                 permissions: ["devices.view"]
               },
               actor: context.system
             )

    member = user!(context.system, context.marker, "atomic-cache")

    {:ok, member} =
      User.update_role_profile(member, %{role_profile_id: profile.id}, actor: context.system)

    assert RBAC.permissions_for_user(member, actor: context.system) ==
             MapSet.new(["devices.view"])

    assert {:ok, %RoleProfile{description: "Synthetic trusted update"}} =
             RoleProfile.update_system_profile(
               profile,
               %{description: "Synthetic trusted update", permissions: ["services.view"]},
               actor: context.system
             )

    assert RBAC.permissions_for_user(member, actor: context.system) ==
             MapSet.new(["services.view"])

    custom = profile!(context.system, context.marker, ["devices.view"])

    {:ok, reassigned} =
      User.update_role_profile(member, %{role_profile_id: custom.id}, actor: context.system)

    assert RBAC.permissions_for_user(reassigned, actor: context.system) ==
             MapSet.new(["devices.view"])

    assert {:error, error} =
             RoleProfile.update_system_profile(
               custom,
               %{description: "must not update"},
               actor: context.system
             )

    assert Exception.message(error) =~ "trusted system-profile update requires a system profile"
    assert {:ok, unchanged} = RoleProfile.get_by_id(custom.id, actor: context.system)
    assert is_nil(unchanged.description)
  end

  test "the seeder updates a changed built-in profile through the trusted action", context do
    assert :ok = RoleProfileSeeder.seed()
    assert {:ok, viewer} = RoleProfile.get_by_system_name("viewer", actor: context.system)
    original = Map.take(viewer, [:name, :description, :permissions])

    on_exit(fn ->
      {:ok, current} = RoleProfile.get_by_system_name("viewer", actor: context.system)

      {:ok, _restored} =
        RoleProfile.update_system_profile(current, original, actor: context.system)
    end)

    assert {:ok, changed} =
             RoleProfile.update_system_profile(
               viewer,
               %{description: "Synthetic changed built-in", permissions: []},
               actor: context.system
             )

    assert changed.description == "Synthetic changed built-in"
    assert :ok = RoleProfileSeeder.seed()
    assert {:ok, refreshed} = RoleProfile.get_by_system_name("viewer", actor: context.system)
    refute refreshed.description == "Synthetic changed built-in"
    refute refreshed.permissions == []
  end

  test "an owned transaction rollback publishes no audit or cache effects", context do
    group = group!(context.system, context.marker)
    opts = effect_opts(self())

    group_id = Ecto.UUID.dump!(group.id)

    result =
      PrivilegeMutationEffects.run(
        context.scope,
        ["settings.rbac.manage", "identity.user_groups.manage"],
        fn _actor ->
          Repo.update_all(
            from(g in "user_groups", prefix: "platform", where: g.id == ^group_id),
            set: [description: "must roll back"]
          )

          {:error, :forced_rollback}
        end,
        opts
      )

    assert result == {:error, :forced_rollback}
    refute_receive {:audit, _}
    refute_receive {:invalidate, _}
    assert {:ok, unchanged} = Ash.get(UserGroup, group.id, actor: context.system)
    assert is_nil(unchanged.description)
  end

  test "group assignment and clearing deduplicate member invalidation after commit", context do
    group = group!(context.system, context.marker)
    profile = profile!(context.system, context.marker, ["devices.view"])
    member_a = user!(context.system, context.marker, "member-a")
    member_b = user!(context.system, context.marker, "member-b")
    manual_membership!(context.system, group.id, member_a.id)
    manual_membership!(context.system, group.id, member_b.id)

    assert {:ok, %{role_profile_id: profile_id}} =
             GroupPolicy.assign(context.scope, group.id, profile.id, effect_opts(self()))

    assert profile_id == profile.id
    assert_receive {:invalidate, first}
    assert_receive {:invalidate, second}
    assert MapSet.new([first, second]) == MapSet.new([member_a.id, member_b.id])
    refute_receive {:invalidate, _}
    assert_receive {:audit, audit}
    assert audit[:action] == :assign_role_profile
    refute_receive {:audit, _}

    assert {:ok, %{role_profile_id: nil}} =
             GroupPolicy.clear(context.scope, group.id, effect_opts(self()))

    assert_receive {:invalidate, first}
    assert_receive {:invalidate, second}
    assert MapSet.new([first, second]) == MapSet.new([member_a.id, member_b.id])
    refute_receive {:invalidate, _}
    assert_receive {:audit, audit}
    assert audit[:action] == :clear_role_profile
    refute_receive {:audit, _}
  end

  test "group deletion invalidates users captured before membership cascade", context do
    group = group!(context.system, context.marker)
    member_a = user!(context.system, context.marker, "former-a")
    member_b = user!(context.system, context.marker, "former-b")
    manual_membership!(context.system, group.id, member_a.id)
    manual_membership!(context.system, group.id, member_b.id)

    assert {:ok, %UserGroup{id: deleted_id}} =
             GroupPolicy.delete(context.scope, group.id, effect_opts(self()))

    assert deleted_id == group.id
    assert_receive {:invalidate, first}
    assert_receive {:invalidate, second}
    assert MapSet.new([first, second]) == MapSet.new([member_a.id, member_b.id])
    refute_receive {:invalidate, _}

    assert {:ok, nil} =
             Ash.get(UserGroup, group.id,
               actor: context.system,
               not_found_error?: false
             )

    assert memberships_for(member_a.id, context.system) == []
    assert_receive {:audit, audit}
    assert audit[:action] == :delete
  end

  for failure_kind <- [:return, :raise, :exit] do
    @failure_kind failure_kind
    test "audit #{failure_kind} cannot undo a committed assignment", context do
      group = group!(context.system, context.marker)
      profile = profile!(context.system, context.marker, ["devices.view"])

      failure =
        case @failure_kind do
          :return -> fn _audit -> {:error, :synthetic_delivery_failure} end
          :raise -> fn _audit -> raise "synthetic audit raise" end
          :exit -> fn _audit -> exit(:synthetic_audit_exit) end
        end

      opts =
        self()
        |> effect_opts()
        |> Keyword.put(:audit_writer, failure)

      assert {:ok, %{role_profile_id: profile_id}} =
               GroupPolicy.assign(context.scope, group.id, profile.id, opts)

      assert profile_id == profile.id
      assert {:ok, persisted} = Ash.get(UserGroup, group.id, actor: context.system)
      assert persisted.role_profile_id == profile.id
    end
  end

  test "raw group-profile and group-delete actions fail without boundary context", context do
    group = group!(context.system, context.marker)
    profile = profile!(context.system, context.marker, ["devices.view"])

    assert {:error, assign_error} =
             group
             |> Ash.Changeset.for_update(:assign_role_profile, %{role_profile_id: profile.id})
             |> Ash.update(actor: context.system)

    assert Exception.message(assign_error) =~ "privilege mutation boundary"

    assert {:error, destroy_error} =
             group
             |> Ash.Changeset.for_destroy(:destroy, %{})
             |> Ash.destroy(actor: context.system)

    assert Exception.message(destroy_error) =~ "privilege mutation boundary"
    assert {:ok, persisted} = Ash.get(UserGroup, group.id, actor: context.system)
    assert is_nil(persisted.role_profile_id)
  end

  test "raw membership mutation fails before persistence", context do
    group = group!(context.system, context.marker)
    member = user!(context.system, context.marker, "raw-member")

    assert {:error, error} =
             UserGroupMembership
             |> Ash.Changeset.for_create(:create_manual, %{group_id: group.id, user_id: member.id})
             |> Ash.create(actor: context.system)

    assert Exception.message(error) =~ "privilege mutation boundary"
    assert memberships_for(member.id, context.system) == []

    membership = manual_membership!(context.system, group.id, member.id)

    assert {:error, destroy_error} =
             membership
             |> Ash.Changeset.for_destroy(:destroy, %{})
             |> Ash.destroy(actor: context.system)

    assert Exception.message(destroy_error) =~ "privilege mutation boundary"

    assert [%UserGroupMembership{id: membership_id}] =
             memberships_for(member.id, context.system)

    assert membership_id == membership.id
  end

  test "manual add and remove own their effects", context do
    group = group!(context.system, context.marker)
    member = user!(context.system, context.marker, "manual-member")
    opts = effect_opts(self())

    assert {:ok, %UserGroupMembership{source: :manual} = membership} =
             PrivilegedMembership.add(context.scope, group.id, member.id, %{}, opts)

    assert_receive {:invalidate, member_id}
    assert member_id == member.id
    assert_receive {:audit, add_audit}
    assert add_audit[:action] == :add_member

    assert {:ok, %UserGroupMembership{id: membership_id}} =
             PrivilegedMembership.remove(context.scope, membership.id, opts)

    assert membership_id == membership.id
    assert_receive {:invalidate, member_id}
    assert member_id == member.id
    assert_receive {:audit, remove_audit}
    assert remove_audit[:action] == :remove_member
    assert memberships_for(member.id, context.system) == []
  end

  test "IdP reconciliation keeps a desired manual membership without converting it", context do
    group = group!(context.system, context.marker)
    member = user!(context.system, context.marker, "idp-manual-kept")
    membership = manual_membership!(context.system, group.id, member.id)

    assert %{added: [], withdrawn: [], kept: [group_id]} =
             PrivilegedMembership.reconcile_idp(member.id, [group.id],
               actor: context.system,
               audit_writer: notify_audit(self()),
               cache_invalidator: notify_invalidation(self())
             )

    assert group_id == group.id

    assert [%UserGroupMembership{id: id, source: :manual}] =
             memberships_for(member.id, context.system)

    assert id == membership.id
    refute_receive {:audit, _}
    refute_receive {:invalidate, _}
  end

  test "IdP withdrawal never removes a manual membership", context do
    group = group!(context.system, context.marker)
    member = user!(context.system, context.marker, "idp-manual-withdraw")
    membership = manual_membership!(context.system, group.id, member.id)

    assert %{added: [], withdrawn: [], kept: []} =
             PrivilegedMembership.reconcile_idp(member.id, [], actor: context.system)

    assert [%UserGroupMembership{id: id, source: :manual}] =
             memberships_for(member.id, context.system)

    assert id == membership.id
  end

  test "one failed IdP mapping does not block another mapping", context do
    valid_group = group!(context.system, context.marker)
    missing_group_id = Ecto.UUID.generate()
    member = user!(context.system, context.marker, "idp-best-effort")

    result =
      PrivilegedMembership.reconcile_idp(member.id, [missing_group_id, valid_group.id],
        actor: context.system
      )

    assert result.added == [valid_group.id]
    assert result.withdrawn == []
    assert result.kept == []

    assert [%UserGroupMembership{group_id: group_id, source: :idp}] =
             memberships_for(member.id, context.system)

    assert group_id == valid_group.id

    assert %{added: [], withdrawn: [withdrawn_id], kept: []} =
             PrivilegedMembership.reconcile_idp(member.id, [], actor: context.system)

    assert withdrawn_id == valid_group.id
    assert memberships_for(member.id, context.system) == []
  end

  defp effect_opts(test_pid) do
    [audit_writer: notify_audit(test_pid), cache_invalidator: notify_invalidation(test_pid)]
  end

  defp transaction_observing_effect_opts(test_pid) do
    [
      audit_writer: fn audit_opts ->
        send(test_pid, {:audit, audit_opts, Repo.in_transaction?()})
        :ok
      end,
      cache_invalidator: fn user_id ->
        send(test_pid, {:invalidate, user_id, Repo.in_transaction?()})
        :ok
      end
    ]
  end

  defp notify_audit(test_pid) do
    fn audit_opts ->
      send(test_pid, {:audit, audit_opts})
      :ok
    end
  end

  defp notify_invalidation(test_pid) do
    fn user_id ->
      send(test_pid, {:invalidate, user_id})
      :ok
    end
  end

  defp profile!(actor, marker, permissions) do
    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "#{marker}-profile-#{System.unique_integer([:positive])}",
          permissions: permissions
        },
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    profile
  end

  defp revoke_profile!(actor, profile_id) do
    profile = RoleProfile.get_by_id!(profile_id, actor: actor)

    profile
    |> Ash.Changeset.for_update(:update, %{permissions: []},
      actor: actor,
      context: %{privilege_boundary_owned: true}
    )
    |> Ash.update!()
  end

  defp assign_group_profile!(actor, group, profile_id) do
    group
    |> Ash.Changeset.for_update(:assign_role_profile, %{role_profile_id: profile_id},
      actor: actor,
      context: %{privilege_boundary_owned: true}
    )
    |> Ash.update!()
  end

  defp group!(actor, marker) do
    {:ok, group} =
      UserGroup.create_group(
        %{name: "#{marker}-group-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    group
  end

  defp user!(actor, marker, label) do
    suffix = System.unique_integer([:positive])
    password = "SyntheticBoundary#{suffix}!"

    {:ok, user} =
      Users.register_with_password(
        %{
          email: "#{label}-#{marker}-#{suffix}@example.test",
          password: password,
          password_confirmation: password
        },
        actor: actor
      )

    user
  end

  defp manual_membership!(actor, group_id, user_id) do
    UserGroupMembership
    |> Ash.Changeset.for_create(:create_manual, %{group_id: group_id, user_id: user_id},
      context: %{privilege_boundary_owned: true}
    )
    |> Ash.create!(actor: actor)
  end

  defp memberships_for(user_id, actor) do
    UserGroupMembership
    |> Ash.Query.for_read(:by_user, %{user_id: user_id})
    |> Ash.read!(actor: actor)
  end

  defp cleanup!(marker) do
    group_pattern = "#{marker}-group-%"
    user_pattern = "%-#{marker}-%@example.test"
    profile_pattern = "#{marker}-%"

    Repo.delete_all(
      from(g in "user_groups", prefix: "platform", where: like(g.name, ^group_pattern))
    )

    Repo.delete_all(
      from(u in "ng_users", prefix: "platform", where: like(u.email, ^user_pattern))
    )

    Repo.delete_all(
      from(p in "role_profiles", prefix: "platform", where: like(p.name, ^profile_pattern))
    )

    for {table, field, pattern} <- [
          {"user_groups", :name, group_pattern},
          {"ng_users", :email, user_pattern},
          {"role_profiles", :name, profile_pattern}
        ] do
      refute Repo.exists?(
               from(r in table, prefix: "platform", where: like(field(r, ^field), ^pattern))
             )
    end

    RBAC.invalidate_all_caches()
  end
end
