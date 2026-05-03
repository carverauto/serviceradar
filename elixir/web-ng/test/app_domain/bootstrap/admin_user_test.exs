defmodule ServiceRadarWebNG.Bootstrap.AdminUserTest do
  use ServiceRadarWebNG.DataCase

  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadarWebNG.Bootstrap.AdminUser

  setup do
    System.put_env("SERVICERADAR_ADMIN_EMAIL", "root@localhost")
    System.put_env("SERVICERADAR_ADMIN_PASSWORD", "test_admin_password_123!")

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
end
