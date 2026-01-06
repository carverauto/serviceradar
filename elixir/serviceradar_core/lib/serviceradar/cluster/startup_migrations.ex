defmodule ServiceRadar.Cluster.StartupMigrations do
  @moduledoc """
  Runs database migrations on startup for public and tenant schemas.

  This task is intended for core-elx only and will fail fast if migrations
  cannot be applied.
  """

  require Logger

  alias ServiceRadar.Cluster.TenantSchemas

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> run!() end]},
      restart: :temporary,
      shutdown: :infinity
    }
  end

  @spec run!() :: :ok
  def run! do
    if migrations_enabled?() do
      Logger.info("[StartupMigrations] Running public migrations")
      TenantSchemas.run_public_migrations!()

      Logger.info("[StartupMigrations] Running tenant migrations")
      TenantSchemas.run_all_tenant_migrations!()
    else
      Logger.debug("[StartupMigrations] Startup migrations disabled; skipping")
    end

    :ok
  end

  defp migrations_enabled? do
    repo_enabled?() &&
      Application.get_env(:serviceradar_core, :run_startup_migrations, false)
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      Process.whereis(ServiceRadar.Repo)
  end
end
