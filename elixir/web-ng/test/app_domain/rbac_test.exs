defmodule ServiceRadarWebNG.RBACTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias Ash.Error.Invalid
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.RBAC, as: WebRBAC

  test "can?/2 refreshes stale persisted scope permissions for real users" do
    user = AccountsFixtures.user_fixture(%{role: :admin})

    stale_scope = Scope.for_user(user, permissions: MapSet.new())

    assert WebRBAC.can?(stale_scope, "northbound.actions.launch")
    assert MapSet.member?(RBAC.permissions_for_user(user), "northbound.actions.launch")
  end

  test "can?/2 refreshes stale persisted scope permissions for map-shaped users" do
    user =
      %{role: :admin}
      |> AccountsFixtures.user_fixture()
      |> Map.from_struct()

    stale_scope = Scope.for_user(user, permissions: MapSet.new())

    assert WebRBAC.can?(stale_scope, "northbound.actions.launch")
  end

  test "deleting a custom role profile clears assigned users so they fall back to role defaults" do
    actor = SystemActor.system(:rbac_test)
    user = AccountsFixtures.user_fixture(%{role: :operator})

    {:ok, profile} =
      RoleProfile.create_profile(
        %{
          name: "Temporary #{System.unique_integer([:positive])}",
          description: "Temporary test profile",
          permissions: ["devices.view"]
        },
        actor: actor
      )

    {:ok, assigned} = User.update_role_profile(user, %{role_profile_id: profile.id}, actor: actor)

    assert assigned.role_profile_id == profile.id

    assert :ok = RoleProfile.delete_profile(profile, actor: actor)

    {:ok, refreshed} = User.get_by_id(user.id, actor: actor)
    assert is_nil(refreshed.role_profile_id)
  end

  test "system role profiles still cannot be deleted" do
    actor = SystemActor.system(:rbac_test)
    {:ok, admin_profile} = RoleProfile.get_by_system_name("admin", actor: actor)

    assert {:error, %Invalid{} = error} = RoleProfile.delete_profile(admin_profile, actor: %{role: :admin})
    assert Exception.message(error) =~ "system profiles cannot be deleted"
  end
end
