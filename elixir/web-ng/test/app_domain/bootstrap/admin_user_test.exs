defmodule ServiceRadarWebNG.Bootstrap.AdminUserTest do
  use ServiceRadarWebNG.DataCase

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadarWebNG.Bootstrap.AdminUser

  @moduletag :web_ng_shared_fixture_db

  setup do
    System.put_env("SERVICERADAR_ADMIN_EMAIL", "root@localhost")
    System.put_env("SERVICERADAR_ADMIN_PASSWORD", "test_admin_password_123!")
    System.delete_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC")

    on_exit(fn ->
      System.delete_env("SERVICERADAR_ADMIN_EMAIL")
      System.delete_env("SERVICERADAR_ADMIN_PASSWORD")
    end)

    :ok
  end

  test "bootstraps admin user once" do
    assert :ok = AdminUser.ensure_admin_user()

    user = Users.get_by_email("root@localhost", authorize?: false)
    assert %User{} = user
    assert user.role == :admin
    assert user.confirmed_at
    refute user.hashed_password in [nil, ""]

    assert :ok = AdminUser.ensure_admin_user()

    query = Ash.Query.for_read(User, :read, %{}, authorize?: false)

    {:ok, users} = Ash.read(query)
    assert length(users) == 1
  end

  test "preserves UI-changed password when force-sync is unset" do
    assert :ok = AdminUser.ensure_admin_user()
    user = Users.get_by_email("root@localhost", authorize?: false)

    System.put_env("SERVICERADAR_ADMIN_PASSWORD", "drifted_env_password_123!")
    assert :ok = AdminUser.ensure_admin_user()

    refreshed = Users.get_by_email("root@localhost", authorize?: false)
    assert refreshed.hashed_password == user.hashed_password
  end

  test "resets stored hash to env value when force-sync is enabled" do
    assert :ok = AdminUser.ensure_admin_user()
    original = Users.get_by_email("root@localhost", authorize?: false)

    new_password = "force_synced_password_123!"
    System.put_env("SERVICERADAR_ADMIN_PASSWORD", new_password)
    System.put_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC", "true")

    on_exit(fn ->
      System.delete_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC")
    end)

    assert :ok = AdminUser.ensure_admin_user()

    refreshed = Users.get_by_email("root@localhost", authorize?: false)
    refute refreshed.hashed_password == original.hashed_password
    assert Users.valid_password?(refreshed, new_password)
  end

  test "preserves operator-set password across restarts when force-sync is enabled" do
    System.put_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC", "true")

    on_exit(fn ->
      System.delete_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC")
    end)

    assert :ok = AdminUser.ensure_admin_user()

    user = Users.get_by_email("root@localhost", authorize?: false)

    operator_password = "operator-chosen-passphrase-7f31a9"

    assert {:ok, _user} =
             User.admin_set_password(user, %{password: operator_password}, actor: SystemActor.system(:admin_user_test))

    endpoint_config = Application.get_env(:serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, ServiceRadarWebNGWeb.Endpoint, endpoint_config) end)

    Application.put_env(
      :serviceradar_web_ng,
      ServiceRadarWebNGWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, String.duplicate("rotated-signing-key", 4))
    )

    # Restarting the pod (helm upgrade, rollout, crash) re-runs bootstrap
    # with the SAME secret. The operator's password must survive.
    assert :ok = AdminUser.ensure_admin_user()
    assert :ok = AdminUser.ensure_admin_user()

    refreshed = Users.get_by_email("root@localhost", authorize?: false)
    assert Users.valid_password?(refreshed, operator_password)
    refute Users.valid_password?(refreshed, "test_admin_password_123!")
  end

  test "resets to the secret after it rotates even when an operator password is set" do
    System.put_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC", "true")

    on_exit(fn ->
      System.delete_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC")
    end)

    assert :ok = AdminUser.ensure_admin_user()

    user = Users.get_by_email("root@localhost", authorize?: false)

    operator_password = "operator-interim-passphrase-2c48e0"

    assert {:ok, _user} =
             User.admin_set_password(user, %{password: operator_password}, actor: SystemActor.system(:admin_user_test))

    # Sanity: with the secret unchanged, the operator password is preserved.
    assert :ok = AdminUser.ensure_admin_user()
    assert Users.valid_password?(Users.get_by_email("root@localhost", authorize?: false), operator_password)

    rotated_secret = "rotated-bootstrap-secret-91bd54"
    System.put_env("SERVICERADAR_ADMIN_PASSWORD", rotated_secret)

    assert :ok = AdminUser.ensure_admin_user()

    refreshed = Users.get_by_email("root@localhost", authorize?: false)
    assert Users.valid_password?(refreshed, rotated_secret)
  end

  test "preserves an existing operator password on the first upgrade with rotation tracking" do
    assert :ok = AdminUser.ensure_admin_user()
    user = Users.get_by_email("root@localhost", authorize?: false)
    operator_password = "upgrade-operator-passphrase-42!"

    assert {:ok, _} =
             User.admin_set_password(user, %{password: operator_password}, actor: SystemActor.system(:admin_user_test))

    # A deployment upgrading from the old bootstrap has no rotation history.
    ServiceRadar.Repo.query!("DELETE FROM platform.admin_secret_markers")
    System.put_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC", "true")
    on_exit(fn -> System.delete_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC") end)

    assert :ok = AdminUser.ensure_admin_user()
    assert :ok = AdminUser.ensure_admin_user()
    assert Users.valid_password?(Users.get_by_email("root@localhost", authorize?: false), operator_password)
  end
end
