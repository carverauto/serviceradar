defmodule ServiceRadarWebNG.AdminApi.LocalTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AdminApi.Local

  setup do
    %{scope: Scope.for_user(admin_user_fixture())}
  end

  test "update_user rolls back earlier changes when a later update fails", %{scope: scope} do
    user = viewer_user_fixture()

    assert {:error, _reason} =
             Local.update_user(scope, user.id, %{
               "role" => :admin,
               "role_profile_id" => Ecto.UUID.generate()
             })

    assert {:ok, reloaded} = Ash.get(User, user.id, scope: scope)
    assert reloaded.role == :viewer
    assert is_nil(reloaded.role_profile_id)
  end

  test "update_user clears an explicitly provided nil role_profile_id", %{scope: scope} do
    user = viewer_user_fixture()
    profile = role_profile_fixture()

    assert {:ok, updated} =
             Local.update_user(scope, user.id, %{
               "role_profile_id" => profile.id
             })

    assert updated.role_profile_id == profile.id

    assert {:ok, cleared} =
             Local.update_user(scope, user.id, %{
               "role_profile_id" => nil
             })

    assert is_nil(cleared.role_profile_id)
  end

  test "list_users accepts integer limits safely", %{scope: scope} do
    _user_one = viewer_user_fixture(%{email: "viewer-one@example.com"})
    _user_two = viewer_user_fixture(%{email: "viewer-two@example.com"})

    assert {:ok, users} = Local.list_users(scope, %{"limit" => 1})
    assert length(users) == 1
  end

  defp role_profile_fixture do
    unique = System.unique_integer([:positive])

    RoleProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Support #{unique}",
        description: "Role profile for admin API tests",
        permissions: ["settings.auth.manage"]
      },
      actor: system_actor()
    )
    |> Ash.create!()
  end
end
