defmodule ServiceRadar.Cluster.StartupMigrations do
  @moduledoc """
  Runs database migrations on startup.

  In the single-deployment architecture, migrations run against the single schema
  determined by the PostgreSQL search_path (set by CNPG credentials).

  This task is intended for core-elx only and will fail fast if migrations
  cannot be applied.
  """

  require Logger

  @default_marker_path "/tmp/serviceradar_migrations_complete"
  @default_search_path "platform, ag_catalog"
  @default_app_user "serviceradar"

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

    if migration_only?() do
      Logger.info("[StartupMigrations] Migration-only mode enabled; shutting down")
      System.stop(0)
    end

    :ok
  end

  defp run_migrations! do
    app_user = app_user()
    app_password = app_password!()

    bootstrap_app_role!(app_user, app_password)
    ensure_platform_schema!(app_user)
    sync_platform_schema_migrations!()

    Ecto.Migrator.run(
      ServiceRadar.Repo,
      Application.app_dir(:serviceradar_core, "priv/repo/migrations"),
      :up,
      all: true,
      prefix: "platform"
    )

    ensure_platform_ownership!(app_user)
    ensure_database_search_path!(app_user, app_database(), search_path())
    ensure_ag_catalog_privileges!(app_user)
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
      rows = public_tables_for_current_user()
      raise_if_public_tables!(rows)
    end
  end

  defp public_tables_for_current_user do
    %{rows: rows} =
      ServiceRadar.Repo.query!(
        "SELECT tablename FROM pg_tables\n" <>
          "WHERE schemaname = 'public'\n" <>
          "AND tableowner = current_user\n" <>
          "AND tablename <> 'schema_migrations'"
      )

    rows
  end

  defp raise_if_public_tables!([]), do: :ok

  defp raise_if_public_tables!(rows) do
    tables = Enum.map_join(rows, ", ", fn [name] -> name end)
    raise RuntimeError, "public schema has ServiceRadar tables: #{tables}"
  end

  defp ensure_platform_schema!(app_user) do
    if repo_enabled?() do
      ServiceRadar.Repo.query!("CREATE SCHEMA IF NOT EXISTS platform")
      ServiceRadar.Repo.query!("ALTER SCHEMA platform OWNER TO #{quote_ident(app_user)}")
    end
  end

  defp clear_migrations_marker do
    case File.rm(migrations_marker_path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("Failed to clear migrations marker: #{inspect(reason)}")
    end
  end

  defp write_migrations_marker do
    case File.write(migrations_marker_path(), "#{DateTime.utc_now()}\n") do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to write migrations marker: #{inspect(reason)}")
    end
  end

  defp migrations_marker_path do
    System.get_env("SERVICERADAR_MIGRATIONS_MARKER_PATH", @default_marker_path)
  end

  defp migration_only? do
    System.get_env("SERVICERADAR_MIGRATION_ONLY", "false") in ~w(true 1 yes)
  end

  defp app_user do
    System.get_env("CNPG_APP_USER") ||
      sanitize_app_user(System.get_env("CNPG_USERNAME")) ||
      @default_app_user
  end

  defp sanitize_app_user(nil), do: nil
  defp sanitize_app_user(""), do: nil
  defp sanitize_app_user("postgres"), do: nil
  defp sanitize_app_user(value), do: value

  defp app_database do
    System.get_env("CNPG_DATABASE", "serviceradar")
  end

  defp search_path do
    System.get_env("CNPG_SEARCH_PATH", @default_search_path)
  end

  defp app_password! do
    password =
      read_password_file(System.get_env("CNPG_APP_PASSWORD_FILE")) ||
        read_password_file(System.get_env("CNPG_PASSWORD_FILE")) ||
        System.get_env("CNPG_APP_PASSWORD") ||
        System.get_env("CNPG_PASSWORD")

    if password in [nil, ""] do
      raise RuntimeError, "missing CNPG app password (CNPG_APP_PASSWORD[_FILE] or CNPG_PASSWORD[_FILE])"
    end

    password
  end

  defp read_password_file(nil), do: nil

  defp read_password_file(path) do
    case File.read(path) do
      {:ok, value} ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      {:error, _} ->
        nil
    end
  end

  defp bootstrap_app_role!(app_user, app_password) do
    if repo_enabled?() do
      if role_exists?(app_user) do
        ServiceRadar.Repo.query!(
          "ALTER ROLE #{quote_ident(app_user)} WITH PASSWORD #{quote_literal(app_password)}"
        )
      else
        ServiceRadar.Repo.query!(
          "CREATE ROLE #{quote_ident(app_user)} LOGIN PASSWORD #{quote_literal(app_password)}"
        )
      end

      ServiceRadar.Repo.query!(
        "ALTER DATABASE #{quote_ident(app_database())} OWNER TO #{quote_ident(app_user)}"
      )
    end
  end

  defp ensure_database_search_path!(app_user, database, search_path) do
    if repo_enabled?() do
      ServiceRadar.Repo.query!(
        "ALTER DATABASE #{quote_ident(database)} SET search_path TO #{quote_literal(search_path)}"
      )

      ServiceRadar.Repo.query!(
        "ALTER ROLE #{quote_ident(app_user)} SET search_path TO #{quote_literal(search_path)}"
      )
    end
  end

  defp ensure_ag_catalog_privileges!(app_user) do
    if repo_enabled?() and schema_exists?("ag_catalog") do
      ServiceRadar.Repo.query!(
        "GRANT USAGE ON SCHEMA ag_catalog TO #{quote_ident(app_user)}"
      )

      ServiceRadar.Repo.query!(
        "GRANT ALL ON ALL TABLES IN SCHEMA ag_catalog TO #{quote_ident(app_user)}"
      )

      ServiceRadar.Repo.query!(
        "GRANT ALL ON ALL SEQUENCES IN SCHEMA ag_catalog TO #{quote_ident(app_user)}"
      )

      ServiceRadar.Repo.query!(
        "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO #{quote_ident(app_user)}"
      )
    end
  end

  defp ensure_platform_ownership!(app_user) do
    if repo_enabled?() do
      ServiceRadar.Repo.query!("ALTER SCHEMA platform OWNER TO #{quote_ident(app_user)}")

      objects =
        ServiceRadar.Repo.query!(
          "SELECT c.relname, c.relkind\n" <>
            "FROM pg_class c\n" <>
            "JOIN pg_namespace n ON n.oid = c.relnamespace\n" <>
            "WHERE n.nspname = 'platform'\n" <>
            "AND c.relkind IN ('r', 'S', 'v', 'm')"
        ).rows

      Enum.each(objects, fn [name, kind] ->
        statement =
          case kind do
            "r" -> "ALTER TABLE #{quote_ident("platform")}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
            "S" -> "ALTER SEQUENCE #{quote_ident("platform")}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
            "v" -> "ALTER VIEW #{quote_ident("platform")}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
            "m" -> "ALTER MATERIALIZED VIEW #{quote_ident("platform")}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
            _ -> nil
          end

        if statement do
          ServiceRadar.Repo.query!(statement)
        end
      end)
    end
  end

  defp role_exists?(role_name) do
    case ServiceRadar.Repo.query!("SELECT 1 FROM pg_roles WHERE rolname = $1", [role_name]) do
      %{rows: []} -> false
      _ -> true
    end
  end

  defp schema_exists?(schema_name) do
    case ServiceRadar.Repo.query!("SELECT 1 FROM pg_namespace WHERE nspname = $1", [schema_name]) do
      %{rows: []} -> false
      _ -> true
    end
  end

  defp quote_ident(value) do
    ~s("#{String.replace(value, "\"", "\"\"")}")
  end

  defp quote_literal(value) do
    "'#{String.replace(value, "'", "''")}'"
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
