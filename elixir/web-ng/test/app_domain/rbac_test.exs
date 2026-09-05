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

  test "raw custom role profile deletion is rejected without the owned boundary" do
    actor = SystemActor.system(:rbac_test)
    user = AccountsFixtures.user_fixture(%{role: :operator})

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Temporary #{System.unique_integer([:positive])}",
          description: "Temporary test profile",
          permissions: ["devices.view"]
        },
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    {:ok, assigned} = User.update_role_profile(user, %{role_profile_id: profile.id}, actor: actor)

    assert assigned.role_profile_id == profile.id

    assert {:error, %Invalid{} = error} = Ash.destroy(profile, actor: actor)
    assert Exception.message(error) =~ "privilege mutation boundary"

    {:ok, refreshed} = User.get_by_id(user.id, actor: actor)
    assert refreshed.role_profile_id == profile.id
  end

  test "system role profiles still cannot be deleted" do
    actor = SystemActor.system(:rbac_test)
    {:ok, admin_profile} = RoleProfile.get_by_system_name("admin", actor: actor)

    assert {:error, %Invalid{} = error} =
             admin_profile
             |> Ash.Changeset.for_destroy(:destroy, %{},
               actor: %{role: :admin},
               context: %{privilege_boundary_owned: true}
             )
             |> Ash.destroy(actor: %{role: :admin})

    assert Exception.message(error) =~ "system profiles cannot be deleted"
  end
end
