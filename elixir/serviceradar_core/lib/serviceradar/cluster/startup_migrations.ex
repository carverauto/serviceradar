defmodule ServiceRadar.Cluster.StartupMigrations do
  @moduledoc """
  Runs database migrations on startup.

  In the single-deployment architecture, migrations run against the single schema
  determined by the PostgreSQL search_path (set by CNPG credentials).

  This task is intended for core-elx only and will fail fast if migrations
  cannot be applied.
  """

  require Logger

  @migrations_complete_marker "/tmp/serviceradar_migrations_complete"

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
      clear_migrations_marker()
      migrations_fn = Keyword.get(opts, :migrations, &run_migrations!/0)

      Logger.info("[StartupMigrations] Running migrations")
      migrations_fn.()

      validate_public_schema!()
      # Validate Oban tables exist in correct schema after migrations
      validate_oban_schema!()
    else
      Logger.debug("[StartupMigrations] Startup migrations disabled; skipping")

      # Even if migrations are disabled, validate Oban schema if Oban is enabled
      if oban_enabled?() do
        validate_oban_schema!()
      end
    end

    write_migrations_marker()

    :ok
  end

  defp run_migrations! do
    ensure_platform_schema!()
    sync_platform_schema_migrations!()

    Ecto.Migrator.run(
      ServiceRadar.Repo,
      Application.app_dir(:serviceradar_core, "priv/repo/migrations"),
      :up,
      all: true,
      prefix: "platform"
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

  defp validate_public_schema! do
    if repo_enabled?() do
      Logger.info("[StartupMigrations] Validating public schema is empty")

      %{rows: rows} =
        ServiceRadar.Repo.query!(
          "SELECT tablename FROM pg_tables\n" <>
            "WHERE schemaname = 'public'\n" <>
            "AND tableowner = current_user\n" <>
            "AND tablename <> 'schema_migrations'"
        )

      case rows do
        [] ->
          :ok

        _ ->
          tables = Enum.map_join(rows, ", ", fn [name] -> name end)
          raise RuntimeError, "public schema has ServiceRadar tables: #{tables}"
      end
    end
  end

  defp ensure_platform_schema! do
    if repo_enabled?() do
      ServiceRadar.Repo.query!("CREATE SCHEMA IF NOT EXISTS platform")
    end
  end

  defp clear_migrations_marker do
    case File.rm(@migrations_complete_marker) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("Failed to clear migrations marker: #{inspect(reason)}")
    end
  end

  defp write_migrations_marker do
    case File.write(@migrations_complete_marker, "#{DateTime.utc_now()}\n") do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to write migrations marker: #{inspect(reason)}")
    end
  end

  defp sync_platform_schema_migrations! do
    if repo_enabled?() do
      if table_exists?("public.schema_migrations") do
        ServiceRadar.Repo.query!(
          "CREATE TABLE IF NOT EXISTS platform.schema_migrations (LIKE public.schema_migrations INCLUDING ALL)"
        )

        ServiceRadar.Repo.query!(
          "INSERT INTO platform.schema_migrations (version, inserted_at)\n" <>
            "SELECT version, inserted_at FROM public.schema_migrations\n" <>
            "ON CONFLICT (version) DO NOTHING"
        )
      end
    end
  end

  defp table_exists?(qualified_table) do
    case ServiceRadar.Repo.query!("SELECT to_regclass($1)", [qualified_table]) do
      %{rows: [[nil]]} -> false
      %{rows: [[_]]} -> true
    end
  end
end
