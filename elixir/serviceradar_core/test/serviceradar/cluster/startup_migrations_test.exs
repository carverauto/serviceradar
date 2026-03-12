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
    {:ok, tracker} = Agent.start_link(fn -> %{run: 0} end)

    on_exit(fn ->
      if Process.alive?(tracker) do
        Agent.stop(tracker)
      end
    end)

    migrations_fun = fn ->
      Agent.update(tracker, fn state ->
        Map.update!(state, :run, fn value -> value + 1 end)
      end)

      :ok
    end

    assert :ok =
             StartupMigrations.run!(migrations: migrations_fun)

    assert %{run: 1} = Agent.get(tracker, & &1)
  end

  test "run! fails fast when a migration hook raises" do
    assert_raise RuntimeError, "boom", fn ->
      StartupMigrations.run!(migrations: fn -> raise "boom" end)
    end
  end
end
