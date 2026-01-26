defmodule ServiceRadar.Cluster.StartupMigrations do
  @moduledoc """
  Runs database migrations on startup.

  In the single-deployment architecture, migrations run against the single schema
  determined by the PostgreSQL search_path (set by CNPG credentials).

  This task is intended for core-elx only and will fail fast if migrations
  cannot be applied.
  """

  require Logger

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
      migrations_fn = Keyword.get(opts, :migrations, &run_migrations!/0)

      Logger.info("[StartupMigrations] Running migrations")
      migrations_fn.()

      # Validate Oban tables exist in correct schema after migrations
      validate_oban_schema!()
    else
      Logger.debug("[StartupMigrations] Startup migrations disabled; skipping")

      # Even if migrations are disabled, validate Oban schema if Oban is enabled
      if oban_enabled?() do
        validate_oban_schema!()
      end
    end

    :ok
  end

  defp run_migrations! do
    # Run Ecto migrations for the current schema (determined by search_path)
    Ecto.Migrator.run(
      ServiceRadar.Repo,
      Application.app_dir(:serviceradar_core, "priv/repo/migrations"),
      :up,
      all: true
    )
  end

  defp migrations_enabled? do
    repo_enabled?() &&
      Application.get_env(:serviceradar_core, :run_startup_migrations, false)
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) &&
      Process.whereis(ServiceRadar.Repo)
  end

  defp oban_enabled? do
    Application.get_env(:serviceradar_core, :oban_enabled, true) &&
      Application.get_env(:serviceradar_core, Oban) not in [nil, false]
  end

  defp validate_oban_schema! do
    if repo_enabled?() do
      Logger.info("[StartupMigrations] Validating Oban schema")

      case ServiceRadar.Oban.SchemaValidator.validate() do
        :ok ->
          :ok

        {:error, msg} ->
          Logger.error("[StartupMigrations] Oban schema validation failed: #{msg}")
          raise RuntimeError, "Oban schema validation failed - see logs for details"
      end
    end
  end
end
