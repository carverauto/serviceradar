defmodule ServiceRadar.Cluster.StartupMigrationsTest do
  @moduledoc """
  Integration tests for startup migration behavior.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Cluster.StartupMigrations

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    old_run = Application.get_env(:serviceradar_core, :run_startup_migrations)
    old_repo_enabled = Application.get_env(:serviceradar_core, :repo_enabled)

    Application.put_env(:serviceradar_core, :run_startup_migrations, true)
    Application.put_env(:serviceradar_core, :repo_enabled, true)

    on_exit(fn ->
      Application.put_env(:serviceradar_core, :run_startup_migrations, old_run)
      Application.put_env(:serviceradar_core, :repo_enabled, old_repo_enabled)
    end)

    :ok
  end

  test "run! executes configured migration hooks when enabled" do
    {:ok, tracker} = Agent.start_link(fn -> %{public: 0, tenant: 0} end)

    on_exit(fn ->
      Agent.stop(tracker)
    end)

    public_fun = fn ->
      Agent.update(tracker, fn state ->
        Map.update!(state, :public, fn value -> value + 1 end)
      end)
      :ok
    end

    tenant_fun = fn ->
      Agent.update(tracker, fn state ->
        Map.update!(state, :tenant, fn value -> value + 1 end)
      end)
      :ok
    end

    assert :ok =
             StartupMigrations.run!(
               public_migrations: public_fun,
               tenant_migrations: tenant_fun
             )

    assert %{public: 1, tenant: 1} = Agent.get(tracker, & &1)
  end

  test "run! fails fast when a migration hook raises" do
    assert_raise RuntimeError, "boom", fn ->
      StartupMigrations.run!(
        public_migrations: fn -> raise "boom" end,
        tenant_migrations: fn -> :ok end
      )
    end
  end
end
