defmodule ServiceRadarWebNG.RBACTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias Ash.Error.Forbidden
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.Users
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.RBAC, as: WebRBAC

  test "can?/2 refreshes stale persisted scope permissions for real users" do
    actor = SystemActor.system(:rbac_test)
    user = AccountsFixtures.user_fixture(%{role: :admin})

    stale_scope = Scope.for_user(user, permissions: MapSet.new())

    assert WebRBAC.can?(stale_scope, "northbound.actions.launch")
    assert MapSet.member?(RBAC.permissions_for_user(user), "northbound.actions.launch")
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

    {:ok, assigned} = Users.update_role_profile(user, profile.id, actor: actor)

    assert assigned.role_profile_id == profile.id

    assert :ok = Ash.destroy(profile, actor: actor)

    {:ok, refreshed} = Users.get_by_id(user.id, actor: actor)
    assert is_nil(refreshed.role_profile_id)
  end

  test "system role profiles still cannot be deleted" do
    actor = SystemActor.system(:rbac_test)
    {:ok, admin_profile} = RoleProfile.get_by_system_name("admin", actor: actor)

    assert {:error, %Forbidden{}} = Ash.destroy(admin_profile, actor: %{role: :admin})
  end
end
