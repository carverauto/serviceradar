defmodule ServiceRadarWebNG.AdminApi.LocalTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AdminApi.Local
  alias ServiceRadarWebNG.Auth.Guardian

  @moduletag :web_ng_shared_fixture_db

  setup do
    %{scope: Scope.for_user(admin_user_fixture())}
  end

  @tag :web_ng_shared_fixture_db
  test "deactivate_user ends the user's sessions", %{scope: scope} do
    user = viewer_user_fixture()
    assert {:ok, token, _claims} = Guardian.create_access_token(user)
    issued_before = DateTime.shift(DateTime.utc_now(), minute: -1)
    ServiceRadarWebNGWeb.Endpoint.subscribe("users_sessions:#{user.id}")

    assert {:ok, %User{status: :inactive}} = Local.deactivate_user(scope, user.id)

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

    assert {:error, _revoked} =
             ServiceRadarWebNG.Auth.TokenRevocation.check_user_revoked(user.id, issued_before)

    # The next authenticated browser request with the pre-deactivation token
    # is unauthenticated: session, bearer, and LiveView paths all resolve
    # through Guardian.verify_token/2.
    assert {:error, _reason} = Guardian.verify_token(token, token_type: "access")

    assert {:ok, %User{status: :active} = reactivated} = Local.reactivate_user(scope, user.id)
    assert {:error, :user_revoked} = Guardian.verify_token(token, token_type: "access")

    wait_until_next_unix_second()
    assert {:ok, fresh_token, _fresh_claims} = Guardian.create_access_token(reactivated)
    assert {:ok, _fresh_user, _claims} = Guardian.verify_token(fresh_token, token_type: "access")
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

  # JWT `iat` is whole seconds. A token minted in the same second as the
  # deactivation marker is still before `revoked_before`.
  defp wait_until_next_unix_second do
    start = System.system_time(:second)
    Process.sleep(1_100)
    if System.system_time(:second) == start, do: Process.sleep(1_000)
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
      actor: system_actor(),
      context: %{privilege_boundary_owned: true}
    )
    |> Ash.create!()
  end
end
