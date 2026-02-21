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
    assert user.confirmed_at != nil
    assert user.hashed_password not in [nil, ""]

    assert :ok = AdminUser.ensure_admin_user()

    query =
      User
      |> Ash.Query.for_read(:read, %{}, authorize?: false)

    {:ok, users} = Ash.read(query)
    assert length(users) == 1
  end
end
