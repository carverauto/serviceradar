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
  @default_search_path "platform, public, ag_catalog"
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
    ensure_app_database_exists!(app_database())

    app_user = app_user()
    app_password = app_password!()

    bootstrap_app_role!(app_user, app_password)
    ensure_platform_schema!(app_user)
    sync_platform_schema_migrations!()
    set_session_search_path!(search_path())

    Ecto.Migrator.run(
      ServiceRadar.Repo,
      Application.app_dir(:serviceradar_core, "priv/repo/migrations"),
      :up,
      all: true,
      prefix: "platform"
    )

    # Sync to ash_schema_migrations after migrations complete.
    # Ash Framework uses this table to track migrations via Repo config.
    sync_ash_schema_migrations!()

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
      Process.whereis(ServiceRadar.Repo) != nil
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

  defp set_session_search_path!(path) do
    if repo_enabled?() do
      ServiceRadar.Repo.query!("SET search_path TO #{path}")
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
      # First, fix any existing misconfigured search_path (with quoted identifier)
      fix_search_path!(app_user, database)

      # Format the search_path as a proper comma-separated list of identifiers.
      # Each schema name is quoted individually to handle any special characters.
      formatted_path = format_search_path(search_path)

      ServiceRadar.Repo.query!(
        "ALTER DATABASE #{quote_ident(database)} SET search_path TO #{formatted_path}"
      )

      ServiceRadar.Repo.query!(
        "ALTER ROLE #{quote_ident(app_user)} SET search_path TO #{formatted_path}"
      )
    end
  end

  # Format search_path as comma-separated quoted identifiers.
  # Input: "platform, public, ag_catalog"
  # Output: "platform", "public", "ag_catalog"
  defp format_search_path(search_path) do
    search_path
    |> String.split(",")
    |> Enum.map_join(", ", fn schema -> schema |> String.trim() |> quote_ident() end)
  end

  # Fix existing misconfigured search_path where the entire value was stored as a single
  # quoted identifier (e.g., "platform, public, ag_catalog" with quotes in the value).
  defp fix_search_path!(app_user, database) do
    # Check if the current search_path has the bug (contains literal double quotes)
    case ServiceRadar.Repo.query!("SELECT current_setting('search_path')") do
      %{rows: [[current_path]]} when is_binary(current_path) ->
        if String.starts_with?(current_path, "\"") do
          Logger.warning(
            "[StartupMigrations] Detected misconfigured search_path: #{inspect(current_path)}. " <>
              "Resetting to fix quoted identifier issue."
          )

          # Reset to default then re-apply correctly
          ServiceRadar.Repo.query!("ALTER DATABASE #{quote_ident(database)} RESET search_path")
          ServiceRadar.Repo.query!("ALTER ROLE #{quote_ident(app_user)} RESET search_path")
        end

      _ ->
        :ok
    end
  end

  defp ensure_ag_catalog_privileges!(app_user) do
    if repo_enabled?() and schema_exists?("ag_catalog") do
      # AGE privileges must be granted by superuser since the schemas may be owned by postgres.
      # Use admin connection for all AGE-related grants.
      with_admin_connection(fn conn ->
        Postgrex.query!(conn, "GRANT USAGE ON SCHEMA ag_catalog TO #{quote_ident(app_user)}", [])

        Postgrex.query!(
          conn,
          "GRANT ALL ON ALL TABLES IN SCHEMA ag_catalog TO #{quote_ident(app_user)}",
          []
        )

        Postgrex.query!(
          conn,
          "GRANT ALL ON ALL SEQUENCES IN SCHEMA ag_catalog TO #{quote_ident(app_user)}",
          []
        )

        Postgrex.query!(
          conn,
          "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO #{quote_ident(app_user)}",
          []
        )

        # Also grant privileges on the AGE graph schema (configured graph name).
        # AGE creates a schema for each graph to store vertex/edge labels.
        graph_name = Application.get_env(:serviceradar_core, :age_graph_name, "platform_graph")
        ensure_age_graph_privileges!(conn, app_user, graph_name)
      end)
    end
  end

  # Grant privileges on an AGE graph schema using an admin connection.
  # AGE creates a schema with the same name as the graph to store vertex/edge tables.
  # The schema is owned by whoever ran create_graph(), which may be postgres superuser.
  defp ensure_age_graph_privileges!(conn, app_user, graph_name) do
    # Check if schema exists using the admin connection
    case Postgrex.query!(conn, "SELECT 1 FROM pg_namespace WHERE nspname = $1", [graph_name]) do
      %{rows: []} ->
        Logger.debug("[StartupMigrations] AGE graph schema #{graph_name} does not exist; skipping privileges")

      _ ->
        Logger.info("[StartupMigrations] Granting privileges on AGE graph schema #{graph_name}")

        Postgrex.query!(
          conn,
          "GRANT USAGE, CREATE ON SCHEMA #{quote_ident(graph_name)} TO #{quote_ident(app_user)}",
          []
        )

        Postgrex.query!(
          conn,
          "GRANT ALL ON ALL TABLES IN SCHEMA #{quote_ident(graph_name)} TO #{quote_ident(app_user)}",
          []
        )

        Postgrex.query!(
          conn,
          "GRANT ALL ON ALL SEQUENCES IN SCHEMA #{quote_ident(graph_name)} TO #{quote_ident(app_user)}",
          []
        )

        # Set default privileges for future objects created in this graph
        Postgrex.query!(
          conn,
          "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quote_ident(graph_name)} GRANT ALL ON TABLES TO #{quote_ident(app_user)}",
          []
        )

        Postgrex.query!(
          conn,
          "ALTER DEFAULT PRIVILEGES IN SCHEMA #{quote_ident(graph_name)} GRANT ALL ON SEQUENCES TO #{quote_ident(app_user)}",
          []
        )

        # Ensure ownership matches app user to satisfy AGE label-table ownership requirements.
        ensure_age_graph_ownership!(conn, app_user, graph_name)
    end
  end

  defp ensure_age_graph_ownership!(conn, app_user, graph_name) do
    Logger.info("[StartupMigrations] Ensuring ownership for AGE graph schema #{graph_name}")

    Postgrex.query!(
      conn,
      "ALTER SCHEMA #{quote_ident(graph_name)} OWNER TO #{quote_ident(app_user)}",
      []
    )

    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT c.relkind, c.relname\n" <>
          "FROM pg_class c\n" <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace\n" <>
          "WHERE n.nspname = $1\n" <>
          "AND c.relkind IN ('r', 'p', 'S')",
        [graph_name]
      )

    Enum.each(rows, fn [relkind, relname] ->
      stmt =
        case relkind do
          "S" ->
            "ALTER SEQUENCE #{quote_ident(graph_name)}.#{quote_ident(relname)} OWNER TO #{quote_ident(app_user)}"

          _ ->
            "ALTER TABLE #{quote_ident(graph_name)}.#{quote_ident(relname)} OWNER TO #{quote_ident(app_user)}"
        end

      Postgrex.query!(conn, stmt, [])
    end)
  end

  # Execute a function with a temporary admin (superuser) database connection.
  # Used for operations that require elevated privileges (e.g., granting on schemas owned by postgres).
  defp with_admin_connection(fun) do
    {admin_user, admin_password} = admin_credentials!()

    opts = [
      hostname: System.get_env("CNPG_HOST", "localhost"),
      port: parse_int(System.get_env("CNPG_PORT"), 5432),
      username: admin_user,
      password: admin_password,
      database: app_database(),
      ssl: admin_ssl_opts()
    ]

    case Postgrex.start_link(opts) do
      {:ok, conn} ->
        try do
          fun.(conn)
        after
          GenServer.stop(conn)
        end

      {:error, reason} ->
        Logger.error("[StartupMigrations] Failed to connect as admin for AGE privileges: #{inspect(reason)}")
        raise RuntimeError, "Failed to connect as admin: #{inspect(reason)}"
    end
  end

  defp ensure_platform_ownership!(app_user) do
    if repo_enabled?() do
      ServiceRadar.Repo.query!("ALTER SCHEMA platform OWNER TO #{quote_ident(app_user)}")

      objects =
        ServiceRadar.Repo.query!(
          "SELECT c.oid, c.relname, c.relkind\n" <>
            "FROM pg_class c\n" <>
            "JOIN pg_namespace n ON n.oid = c.relnamespace\n" <>
            "WHERE n.nspname = 'platform'\n" <>
            "AND c.relkind IN ('r', 'S', 'v', 'm')"
        ).rows

      Enum.each(objects, &update_object_ownership(&1, app_user))
    end
  end

  defp update_object_ownership([oid, name, kind], app_user) do
    case ownership_statement(oid, name, kind, app_user) do
      nil -> :ok
      statement -> execute_ownership_update(statement, name)
    end
  end

  defp ownership_statement(_oid, name, "r", app_user) do
    "ALTER TABLE #{quote_ident("platform")}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
  end

  defp ownership_statement(oid, name, "S", app_user) do
    if sequence_owned_by_table?(oid),
      do: nil,
      else: "ALTER SEQUENCE #{quote_ident("platform")}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
  end

  defp ownership_statement(_oid, name, "v", app_user) do
    "ALTER VIEW #{quote_ident("platform")}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
  end

  defp ownership_statement(_oid, name, "m", app_user) do
    "ALTER MATERIALIZED VIEW #{quote_ident("platform")}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
  end

  defp ownership_statement(_oid, _name, _kind, _app_user), do: nil

  defp execute_ownership_update(statement, name) do
    ServiceRadar.Repo.query!(statement)
  rescue
    error ->
      Logger.warning(
        "[StartupMigrations] Skipping ownership update for #{name}: #{Exception.message(error)}"
      )
  end

  defp sequence_owned_by_table?(sequence_oid) do
    case ServiceRadar.Repo.query!(
           "SELECT 1\n" <>
             "FROM pg_depend d\n" <>
             "JOIN pg_class c ON c.oid = d.refobjid\n" <>
             "WHERE d.objid = $1\n" <>
             "AND d.deptype = 'a'\n" <>
             "AND c.relkind = 'r'\n" <>
             "LIMIT 1",
           [sequence_oid]
         ) do
      %{rows: []} -> false
      _ -> true
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

      # Ash Framework uses ash_schema_migrations as the migration source.
      # Sync from schema_migrations to ensure both tables stay in sync.
      sync_ash_schema_migrations!()
    end
  end

  defp sync_ash_schema_migrations! do
    # Create ash_schema_migrations if it doesn't exist
    ServiceRadar.Repo.query!("""
    CREATE TABLE IF NOT EXISTS platform.ash_schema_migrations (
      version bigint NOT NULL PRIMARY KEY,
      inserted_at timestamp(0) without time zone
    )
    """)

    # Sync any migrations from schema_migrations that aren't in ash_schema_migrations.
    # Only sync if platform.schema_migrations exists (it won't on fresh installs before migrations run).
    if table_exists?("platform.schema_migrations") do
      ServiceRadar.Repo.query!("""
      INSERT INTO platform.ash_schema_migrations (version, inserted_at)
      SELECT version, inserted_at FROM platform.schema_migrations
      ON CONFLICT (version) DO NOTHING
      """)
    end
  end

  defp table_exists?(qualified_table) do
    case ServiceRadar.Repo.query!("SELECT to_regclass($1)", [qualified_table]) do
      %{rows: [[nil]]} -> false
      %{rows: [[_]]} -> true
    end
  end

  defp ensure_app_database_exists!(database) do
    admin_database = System.get_env("CNPG_ADMIN_DATABASE", "postgres")
    {admin_user, admin_password} = admin_credentials!()
    attempts = parse_int(System.get_env("SERVICERADAR_DB_BOOTSTRAP_ATTEMPTS"), 30)
    delay_ms = parse_int(System.get_env("SERVICERADAR_DB_BOOTSTRAP_DELAY_MS"), 2000)

    with_retry(attempts, delay_ms, fn ->
      opts = [
        hostname: System.get_env("CNPG_HOST", "localhost"),
        port: parse_int(System.get_env("CNPG_PORT"), 5432),
        username: admin_user,
        password: admin_password,
        database: admin_database,
        ssl: admin_ssl_opts()
      ]

      case Postgrex.start_link(opts) do
        {:ok, conn} ->
          try do
            %{rows: rows} =
              Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [database])

            if rows == [] do
              Logger.info("[StartupMigrations] Creating database #{database}")
              Postgrex.query!(conn, "CREATE DATABASE #{quote_ident(database)}")
            else
              Logger.info("[StartupMigrations] Database #{database} already exists; skipping")
            end

            :ok
          rescue
            e in [DBConnection.ConnectionError, Postgrex.Error] ->
              {:retry, e}
          after
            GenServer.stop(conn)
          end

        {:error, reason} ->
          {:retry, reason}
      end
    end)
  end

  defp admin_credentials! do
    admin_user = System.get_env("CNPG_USERNAME")

    admin_password =
      read_password_file(System.get_env("CNPG_PASSWORD_FILE")) ||
        System.get_env("CNPG_PASSWORD")

    cond do
      admin_user not in [nil, ""] and admin_password not in [nil, ""] ->
        {admin_user, admin_password}

      admin_user in [nil, ""] and admin_password not in [nil, ""] ->
        {app_user(), admin_password}

      true ->
        Logger.warning("[StartupMigrations] CNPG superuser credentials missing; falling back to app credentials")
        {app_user(), app_password!()}
    end
  end

  defp admin_ssl_opts do
    case System.get_env("CNPG_SSL_MODE", "require") do
      "disable" ->
        false

      mode ->
        verify =
          if mode in ["verify-full", "verify-ca"],
            do: :verify_peer,
            else: :verify_none

        opts =
          [verify: verify]
          |> maybe_put(:cacertfile, System.get_env("CNPG_CA_FILE"))
          |> maybe_put(:certfile, System.get_env("CNPG_CERT_FILE"))
          |> maybe_put(:keyfile, System.get_env("CNPG_KEY_FILE"))
          |> maybe_put(
            :server_name_indication,
            System.get_env("CNPG_TLS_SERVER_NAME") |> to_sni()
          )

        if opts == [], do: true, else: opts
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp to_sni(nil), do: nil
  defp to_sni(""), do: nil
  defp to_sni(value), do: String.to_charlist(value)

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp with_retry(attempts, delay_ms, fun) when attempts > 0 do
    case fun.() do
      :ok ->
        :ok

      {:retry, reason} ->
        if attempts == 1 do
          raise RuntimeError, "failed to connect to admin database: #{inspect(reason)}"
        else
          Logger.warning(
            "[StartupMigrations] Admin DB not ready; retrying in #{delay_ms}ms (#{attempts - 1} left)"
          )

          Process.sleep(delay_ms)
          with_retry(attempts - 1, delay_ms, fun)
        end
    end
  end
end
