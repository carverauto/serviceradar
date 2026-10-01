defmodule ServiceRadarWebNG.Bootstrap.AdminUserTest do
  use ServiceRadarWebNG.DataCase

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Identity.Users
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.Bootstrap.AdminUser

  @moduletag :web_ng_shared_fixture_db

  setup do
    System.put_env("SERVICERADAR_ADMIN_EMAIL", "root@localhost")
    System.put_env("SERVICERADAR_ADMIN_PASSWORD", "test_admin_password_123!")
    System.delete_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC")

    on_exit(fn ->
      System.delete_env("SERVICERADAR_ADMIN_EMAIL")
      System.delete_env("SERVICERADAR_ADMIN_PASSWORD")
      System.delete_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC")
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

    operator_password = "operator-passphrase"

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

    operator_password = "operator-password"

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
    operator_password = "operator-password"

    assert {:ok, _} =
             User.admin_set_password(user, %{password: operator_password}, actor: SystemActor.system(:admin_user_test))

    # A deployment upgrading from the old bootstrap has no rotation history.
    Repo.query!("DELETE FROM platform.admin_secret_markers")
    System.put_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC", "true")
    on_exit(fn -> System.delete_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC") end)

    assert :ok = AdminUser.ensure_admin_user()
    assert :ok = AdminUser.ensure_admin_user()
    assert Users.valid_password?(Users.get_by_email("root@localhost", authorize?: false), operator_password)
  end

  @tag sandbox: :unboxed
  test "a delayed concurrent bootstrap preserves a password changed after rotation" do
    email = "bootstrap-race-#{System.unique_integer([:positive])}@example.com"
    initial_secret = "initial-bootstrap-secret-57!"
    rotated_secret = "rotated-bootstrap-secret-82!"
    operator_password = "operator-password"
    actor = SystemActor.system(:admin_user_test)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM platform.admin_secret_markers WHERE admin_email = $1", [email])
        Repo.query!("DELETE FROM platform.ng_users WHERE email = $1", [email])
      end)
    end)

    assert {:ok, _user} =
             Users.register_with_password(
               %{email: email, password: initial_secret, password_confirmation: initial_secret},
               actor: actor
             )

    System.put_env("SERVICERADAR_ADMIN_EMAIL", email)
    System.put_env("SERVICERADAR_ADMIN_PASSWORD", initial_secret)
    System.put_env("SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC", "true")
    assert :ok = AdminUser.ensure_admin_user()

    System.put_env("SERVICERADAR_ADMIN_PASSWORD", rotated_secret)
    parent = self()

    rotation =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert :ok = AdminUser.ensure_admin_user()
          assert Users.valid_password?(Users.get_by_email(email, authorize?: false), rotated_secret)
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:rotation_pending, backend_pid})

          receive do
            :change_operator_password ->
              user = Users.get_by_email(email, authorize?: false)

              assert {:ok, _user} =
                       User.admin_set_password(user, %{password: operator_password}, actor: actor)
          after
            10_000 -> flunk("concurrent bootstrap never reached the rotation transaction")
          end
        end)
      end)

    assert_receive {:rotation_pending, rotation_backend}, 10_000

    delayed =
      Task.async(fn ->
        Repo.transaction(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:delayed_bootstrap, backend_pid})
          AdminUser.ensure_admin_user()
        end)
      end)

    try do
      assert_receive {:delayed_bootstrap, delayed_backend}, 10_000
      await_blocked_bootstrap(delayed_backend, rotation_backend, System.monotonic_time(:millisecond) + 5_000)
      send(rotation.pid, :change_operator_password)
      assert {:ok, {:ok, _user}} = Task.await(rotation, 10_000)
      assert {:ok, :ok} = Task.await(delayed, 10_000)

      refreshed = Users.get_by_email(email, authorize?: false)
      assert Users.valid_password?(refreshed, operator_password)
      refute Users.valid_password?(refreshed, rotated_secret)
      assert :ok = AdminUser.ensure_admin_user()
      assert Users.valid_password?(Users.get_by_email(email, authorize?: false), operator_password)
    after
      Task.shutdown(rotation, :brutal_kill)
      Task.shutdown(delayed, :brutal_kill)
    end
  end

  defp await_blocked_bootstrap(delayed_backend, rotation_backend, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [rotation_backend, delayed_backend])

    if !blocked? do
      assert System.monotonic_time(:millisecond) < deadline,
             "delayed bootstrap did not wait for the pending rotation"

      Process.sleep(10)
      await_blocked_bootstrap(delayed_backend, rotation_backend, deadline)
    end
  end
end
