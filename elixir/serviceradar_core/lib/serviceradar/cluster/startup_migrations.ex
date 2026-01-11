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
      start: {__MODULE__, :start_link, [[]]},
      restart: :temporary,
      shutdown: :infinity
    }
  end

  def start_link(_opts) do
    run!()
    :ignore
  end

  @spec run!(keyword()) :: :ok
  def run!(opts \\ []) do
    if migrations_enabled?() do
      public_migrations = Keyword.get(opts, :public_migrations, &TenantSchemas.run_public_migrations!/0)
      tenant_migrations = Keyword.get(opts, :tenant_migrations, &TenantSchemas.run_all_tenant_migrations!/0)

      Logger.info("[StartupMigrations] Running public migrations")
      public_migrations.()

      Logger.info("[StartupMigrations] Running tenant migrations")
      tenant_migrations.()
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
