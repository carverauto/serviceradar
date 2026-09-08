defmodule ServiceRadar.Identity.EffectivePermissionsDbTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadar.Identity.UserGroupMembership
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    marker = "effective-authority-#{System.unique_integer([:positive])}"
    actor = SystemActor.system(:effective_permissions_db_test)
    RBAC.invalidate_all_caches()

    on_exit(fn ->
      cleanup!(marker)
      RBAC.invalidate_all_caches()
      RBAC.clear_process_cache()
    end)

    {:ok, actor: actor, marker: marker}
  end

  test "strict authority unions a base profile and every group profile", %{
    actor: actor,
    marker: marker
  } do
    user = user!(actor, marker)
    base = profile!(actor, marker, ["devices.view", "services.update"])

    group_profile =
      profile!(actor, marker, ["services.update", "observability.alerts.manage"])

    duplicate_profile = profile!(actor, marker, ["devices.view"])
    group = group!(actor, marker, group_profile.id)
    duplicate_group = group!(actor, marker, duplicate_profile.id)
    group_without_profile = group!(actor, marker, nil)

    {:ok, user} = User.update_role_profile(user, %{role_profile_id: base.id}, actor: actor)
    membership!(actor, user.id, group.id)
    membership!(actor, user.id, duplicate_group.id)
    membership!(actor, user.id, group_without_profile.id)

    assert {:ok, %{permissions: permissions, profile_versions: profile_versions}} =
             RBAC.effective_authority(user, actor)

    assert permissions ==
             MapSet.new(["devices.view", "services.update", "observability.alerts.manage"])

    assert Enum.map(profile_versions, & &1.id) ==
             Enum.sort([base.id, group_profile.id, duplicate_profile.id])

    assert {:ok, ^permissions} = RBAC.effective_permissions(user, actor)
  end

  test "strict authority preserves the base profile when the user has no group memberships", %{
    actor: actor,
    marker: marker
  } do
    user = user!(actor, marker)
    base = profile!(actor, marker, ["devices.view", "services.update"])

    {:ok, user} = User.update_role_profile(user, %{role_profile_id: base.id}, actor: actor)

    assert {:ok,
            %{
              permissions: permissions,
              profile_versions: [%{id: base_id, updated_at: base_updated_at}]
            }} = RBAC.effective_authority(user, actor)

    assert permissions == MapSet.new(["devices.view", "services.update"])
    assert base_id == base.id
    assert base_updated_at == base.updated_at
  end

  test "removing a membership removes its group-derived permissions", %{
    actor: actor,
    marker: marker
  } do
    user = user!(actor, marker)
    base = profile!(actor, marker, ["devices.view"])
    group_profile = profile!(actor, marker, ["observability.alerts.manage"])
    group = group!(actor, marker, group_profile.id)

    {:ok, user} = User.update_role_profile(user, %{role_profile_id: base.id}, actor: actor)
    membership = membership!(actor, user.id, group.id)

    assert RBAC.permissions_for_user(user, actor: actor) ==
             MapSet.new(["devices.view", "observability.alerts.manage"])

    assert :ok =
             membership
             |> Ash.Changeset.for_destroy(:destroy, %{},
               actor: actor,
               context: %{privilege_boundary_owned: true}
             )
             |> Ash.destroy(actor: actor)

    assert :ok = RBAC.invalidate_user_cache(user.id)
    assert RBAC.permissions_for_user(user, actor: actor) == MapSet.new(["devices.view"])
  end

  test "ordinary resolution does not use a stale process dictionary value", %{
    actor: actor,
    marker: marker
  } do
    user = user!(actor, marker)
    base = profile!(actor, marker, ["devices.view"])
    group_profile = profile!(actor, marker, ["observability.alerts.manage"])
    group = group!(actor, marker, group_profile.id)

    {:ok, user} = User.update_role_profile(user, %{role_profile_id: base.id}, actor: actor)
    membership!(actor, user.id, group.id)

    stale = MapSet.new(["stale.permission"])
    Process.put({:rbac_permissions, user.id}, stale)

    assert RBAC.permissions_for_user(user, actor: actor) ==
             MapSet.new(["devices.view", "observability.alerts.manage"])
  end

  test "invalidating shared cache refreshes resolution in a supervised resolver process", %{
    actor: actor,
    marker: marker
  } do
    user = user!(actor, marker)
    base = profile!(actor, marker, ["devices.view"])
    group_profile = profile!(actor, marker, ["services.update"])
    group = group!(actor, marker, group_profile.id)

    {:ok, user} = User.update_role_profile(user, %{role_profile_id: base.id}, actor: actor)
    membership!(actor, user.id, group.id)

    assert {:ok, permissions} = RBAC.effective_permissions(user, actor)
    assert permissions == MapSet.new(["devices.view", "services.update"])

    resolver_spec =
      fn ->
        receive_loop = fn receive_loop ->
          receive do
            {:resolve, reply_to} ->
              send(reply_to, {:resolved, RBAC.permissions_for_user(user)})
              receive_loop.(receive_loop)

            :stop ->
              :ok
          end
        end

        receive_loop.(receive_loop)
      end
      |> Task.child_spec()
      |> Supervisor.child_spec(id: make_ref())

    resolver = start_supervised!(resolver_spec)
    resolver_ref = Process.monitor(resolver)

    send(resolver, {:resolve, self()})
    assert_receive {:resolved, before_revoke}
    assert MapSet.member?(before_revoke, "services.update")

    group_id = Ecto.UUID.dump!(group.id)

    Repo.update_all(
      from(g in "user_groups", prefix: "platform", where: g.id == ^group_id),
      set: [role_profile_id: nil]
    )

    assert :ok = RBAC.invalidate_user_cache(user.id)
    send(resolver, {:resolve, self()})
    assert_receive {:resolved, after_revoke}
    refute MapSet.member?(after_revoke, "services.update")
    send(resolver, :stop)
    assert_receive {:DOWN, ^resolver_ref, :process, ^resolver, :normal}
  end

  test "strict authority fails closed when the selected base profile cannot load", %{
    actor: actor,
    marker: marker
  } do
    user = user!(actor, marker)
    missing_profile_user = %{user | role_profile_id: Ecto.UUID.generate()}

    assert {:error, _reason} = RBAC.effective_authority(missing_profile_user, actor)
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

  defp group!(actor, marker, role_profile_id) do
    {:ok, group} =
      UserGroup.create_group(
        %{name: "#{marker}-group-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    if role_profile_id do
      {:ok, group} =
        group
        |> Ash.Changeset.for_update(:assign_role_profile, %{role_profile_id: role_profile_id},
          actor: actor,
          context: %{privilege_boundary_owned: true}
        )
        |> Ash.update(actor: actor)

      group
    else
      group
    end
  end

  defp membership!(actor, user_id, group_id) do
    {:ok, membership} =
      UserGroupMembership
      |> Ash.Changeset.for_create(:create_manual, %{user_id: user_id, group_id: group_id},
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create(actor: actor)

    membership
  end

  defp user!(actor, marker) do
    suffix = System.unique_integer([:positive])
    password = "SyntheticAuthority#{suffix}!"

    {:ok, user} =
      Users.register_with_password(
        %{
          email: "#{marker}-#{suffix}@example.test",
          password: password,
          password_confirmation: password
        },
        actor: actor
      )

    user
  end

  defp cleanup!(marker) do
    groups =
      from(g in "user_groups", prefix: "platform", where: like(g.name, ^"#{marker}-group-%"))

    users =
      from(u in "ng_users", prefix: "platform", where: like(u.email, ^"#{marker}-%@example.test"))

    profiles =
      from(p in "role_profiles", prefix: "platform", where: like(p.name, ^"#{marker}-profile-%"))

    memberships =
      from(m in "user_group_memberships",
        prefix: "platform",
        where: m.group_id in subquery(from(g in groups, select: g.id))
      )

    membership_ids = Repo.all(from(m in memberships, select: m.id))
    Repo.delete_all(memberships)
    Repo.delete_all(groups)
    Repo.delete_all(users)
    Repo.delete_all(profiles)

    refute Repo.exists?(
             from(m in "user_group_memberships",
               prefix: "platform",
               where: m.id in ^membership_ids
             )
           )

    for query <- [groups, users, profiles], do: refute(Repo.exists?(query))
  end
end
