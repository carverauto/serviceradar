defmodule ServiceRadar.Cluster.StartupMigrations do
  @moduledoc """
  Runs database migrations on startup.

  In the single-deployment architecture, migrations run against the single schema
  determined by the PostgreSQL search_path (set by CNPG credentials).

  This task is intended for core-elx only and will fail fast if migrations
  cannot be applied.
  """

  alias ServiceRadar.Repo.SchemaBootstrap

  require Logger

  @default_marker_path "/tmp/serviceradar_migrations_complete"
  @default_search_path "platform, public, ag_catalog"
  @default_app_user "serviceradar"
  @max_migration_repair_attempts 500
  @managed_public_function "public.age_device_neighborhood(text,boolean,boolean)"
  @cnpg_pooler_auth_function "public.user_search(text)"
  @cnpg_pooler_auth_language "sql"
  @cnpg_pooler_auth_result "TABLE(usename name, passwd text)"
  @cnpg_pooler_auth_body "SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename=$1;"
  @cnpg_pooler_auth_legacy_body "SELECT usename, passwd FROM pg_shadow WHERE usename=$1;"
  @cnpg_pooler_role "cnpg_pooler_pgbouncer"

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

  @doc false
  defdelegate classify_bootstrap_state(migration_versions, platform_object_count),
    to: SchemaBootstrap,
    as: :classify_state

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
    ensure_database_search_path!(app_user, app_database(), search_path())
    set_session_search_path!(search_path())
    ensure_managed_database_ownership!(app_user)
    ensure_ag_catalog_privileges!(app_user)

    run_bootstrap_or_migrations!(app_user)

    # Sync to ash_schema_migrations after migrations complete.
    # Ash Framework uses this table to track migrations via Repo config.
    sync_ash_schema_migrations!()

    ensure_managed_database_ownership!(app_user)
    ensure_ag_catalog_privileges!(app_user)
  end

  defp migrations_enabled? do
    repo_enabled?() &&
      Application.get_env(:serviceradar_core, :run_startup_migrations, false)
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false &&
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
        "SELECT t.tablename\n" <>
          "FROM pg_tables t\n" <>
          "LEFT JOIN pg_class c ON c.relname = t.tablename\n" <>
          "LEFT JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = t.schemaname\n" <>
          "LEFT JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e'\n" <>
          "LEFT JOIN pg_extension e ON e.oid = d.refobjid\n" <>
          "WHERE t.schemaname = 'public'\n" <>
          "AND t.tableowner = current_user\n" <>
          "AND t.tablename <> 'schema_migrations'\n" <>
          "AND e.oid IS NULL"
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
      read_text_file(System.get_env("CNPG_APP_PASSWORD_FILE")) ||
        read_text_file(System.get_env("CNPG_PASSWORD_FILE")) ||
        System.get_env("CNPG_APP_PASSWORD") ||
        System.get_env("CNPG_PASSWORD")

    if password in [nil, ""] do
      raise RuntimeError,
            "missing CNPG app password (CNPG_APP_PASSWORD[_FILE] or CNPG_PASSWORD[_FILE])"
    end

    password
  end

  defp app_password_or_nil do
    password =
      read_text_file(System.get_env("CNPG_APP_PASSWORD_FILE")) ||
        read_text_file(System.get_env("CNPG_PASSWORD_FILE")) ||
        System.get_env("CNPG_APP_PASSWORD") ||
        System.get_env("CNPG_PASSWORD")

    if password in [nil, ""], do: nil, else: password
  end

  defp read_text_file(nil), do: nil

  defp read_text_file(path) do
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
        # A role is CLUSTER-WIDE, so the check above is not atomic with this create: a concurrent
        # bootstrap can take the gap and this raises 42710. Converge on ALTER rather than fail.
        try do
          ServiceRadar.Repo.query!(
            "CREATE ROLE #{quote_ident(app_user)} LOGIN PASSWORD #{quote_literal(app_password)}"
          )
        rescue
          error in Postgrex.Error ->
            if duplicate_ddl_error?(error) do
              ServiceRadar.Repo.query!(
                "ALTER ROLE #{quote_ident(app_user)} WITH PASSWORD #{quote_literal(app_password)}"
              )
            else
              reraise error, __STACKTRACE__
            end
        end
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
      graph_name = Application.get_env(:serviceradar_core, :age_graph_name, "platform_graph")

      if age_privileges_already_satisfied?(app_user, graph_name) do
        :ok
      else
        # AGE privileges must be granted by superuser when the schema was created by postgres.
        with_admin_connection(fn conn ->
          Postgrex.query!(
            conn,
            "GRANT USAGE ON SCHEMA ag_catalog TO #{quote_ident(app_user)}",
            []
          )

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

          ensure_age_graph_privileges!(conn, app_user, graph_name)
        end)
      end
    end
  end

  defp age_privileges_already_satisfied?(app_user, graph_name) do
    has_ag_catalog_usage?() and age_graph_owner(graph_name) == app_user
  end

  defp has_ag_catalog_usage? do
    case ServiceRadar.Repo.query!(
           "SELECT has_schema_privilege(current_user, 'ag_catalog', 'USAGE')"
         ) do
      %{rows: [[true]]} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp age_graph_owner(graph_name) do
    case ServiceRadar.Repo.query!(
           "SELECT schema_owner FROM information_schema.schemata WHERE schema_name = $1",
           [graph_name]
         ) do
      %{rows: [[owner]]} when is_binary(owner) -> owner
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Grant privileges on an AGE graph schema using an admin connection.
  # AGE creates a schema with the same name as the graph to store vertex/edge tables.
  # The schema is owned by whoever ran create_graph(), which may be postgres superuser.
  defp ensure_age_graph_privileges!(conn, app_user, graph_name) do
    # Check if schema exists using the admin connection
    case Postgrex.query!(conn, "SELECT 1 FROM pg_namespace WHERE nspname = $1", [graph_name]) do
      %{rows: []} ->
        Logger.debug(
          "[StartupMigrations] AGE graph schema #{graph_name} does not exist; skipping privileges"
        )

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

    %{rows: table_rows} =
      Postgrex.query!(
        conn,
        "SELECT c.relname\n" <>
          "FROM pg_class c\n" <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace\n" <>
          "WHERE n.nspname = $1\n" <>
          "AND c.relkind IN ('r', 'p')",
        [graph_name]
      )

    Enum.each(table_rows, fn [relname] ->
      Postgrex.query!(
        conn,
        "ALTER TABLE #{quote_ident(graph_name)}.#{quote_ident(relname)} OWNER TO #{quote_ident(app_user)}",
        []
      )
    end)

    # Skip sequences owned by tables; PostgreSQL forbids changing their owner directly.
    # Both dependency kinds, for the reason spelled out on admin_sequence_owned_by_table?/2:
    # serial gives deptype 'a', an identity column gives 'i', and only the pair is complete.
    %{rows: seq_rows} =
      Postgrex.query!(
        conn,
        "SELECT c.relname\n" <>
          "FROM pg_class c\n" <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace\n" <>
          "WHERE n.nspname = $1\n" <>
          "AND c.relkind = 'S'\n" <>
          "AND NOT EXISTS (\n" <>
          "  SELECT 1 FROM pg_depend d\n" <>
          "  WHERE d.objid = c.oid\n" <>
          "  AND d.deptype IN ('a', 'i')\n" <>
          ")",
        [graph_name]
      )

    Enum.each(seq_rows, fn [relname] ->
      Postgrex.query!(
        conn,
        "ALTER SEQUENCE #{quote_ident(graph_name)}.#{quote_ident(relname)} OWNER TO #{quote_ident(app_user)}",
        []
      )
    end)
  end

  # Execute a function with a temporary admin (superuser) database connection.
  # Used for operations that require elevated privileges, such as repairing ownership
  # of objects created by postgres in older releases.
  defp with_admin_connection(fun) do
    case execute_with_admin_credentials(fun) do
      {:ok, value} ->
        value

      {:retry, reason} ->
        Logger.error(
          "[StartupMigrations] Failed to connect as admin for privileged database maintenance: #{inspect(reason)}"
        )

        raise RuntimeError, "Failed to connect as admin: #{inspect(reason)}"

      {:error, reason} ->
        Logger.error(
          "[StartupMigrations] Failed to connect as admin for privileged database maintenance: #{inspect(reason)}"
        )

        raise RuntimeError, "Failed to connect as admin: #{inspect(reason)}"

      :ok ->
        :ok

      other ->
        Logger.error("[StartupMigrations] Unexpected admin connection result: #{inspect(other)}")
        raise RuntimeError, "Failed to connect as admin"
    end
  end

  defp ensure_managed_database_ownership!(app_user) do
    if repo_enabled?() and managed_database_ownership_repair_needed?(app_user) do
      Logger.info("[StartupMigrations] Repairing ServiceRadar database object ownership")

      with_admin_connection(fn conn ->
        restore_cnpg_pooler_auth_function_ownership!(conn, app_user)
        ensure_schema_owner!(conn, "platform", app_user)
        ensure_platform_relation_ownership!(conn, app_user)
        ensure_continuous_aggregate_backing_privileges!(conn, app_user)
        ensure_managed_function_ownership!(conn, app_user)
      end)
    end
  end

  defp managed_database_ownership_repair_needed?(app_user) do
    platform_repair_needed? =
      case ServiceRadar.Repo.query!(managed_database_ownership_repair_needed_sql(), [app_user]) do
        %{rows: [[true]]} -> true
        _ -> false
      end

    platform_repair_needed? or continuous_aggregate_backing_privileges_missing?(app_user)
  rescue
    error ->
      Logger.warning(
        "[StartupMigrations] Failed to inspect database ownership before migrations: #{Exception.message(error)}"
      )

      false
  end

  defp continuous_aggregate_backing_privileges_missing?(app_user) do
    case ServiceRadar.Repo.query!(continuous_aggregate_information_available_query_sql()) do
      %{rows: [[true]]} ->
        case ServiceRadar.Repo.query!(continuous_aggregate_backing_privileges_query_sql(), [
               app_user
             ]) do
          %{rows: []} -> false
          _ -> true
        end

      _ ->
        false
    end
  end

  @doc false
  def managed_database_ownership_repair_needed_sql do
    """
    SELECT EXISTS (
      SELECT 1
      FROM pg_namespace n
      JOIN pg_roles r ON r.rolname = $1
      WHERE n.nspname = 'platform'
        AND n.nspowner <> r.oid

      UNION ALL

      SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_roles r ON r.rolname = $1
      LEFT JOIN pg_depend d
        ON d.classid = 'pg_class'::regclass
       AND d.objid = c.oid
       AND d.deptype = 'e'
      WHERE n.nspname = 'platform'
        AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
        AND d.objid IS NULL
        AND c.relowner <> r.oid
        AND (
          c.relkind <> 'S'
          OR NOT EXISTS (
            SELECT 1
            FROM pg_depend owned
            JOIN pg_class owner_rel ON owner_rel.oid = owned.refobjid
            WHERE owned.objid = c.oid
              AND owned.deptype = 'a'
              AND owner_rel.relkind = 'r'
          )
        )

      UNION ALL

      SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_roles r ON r.rolname = $1
      LEFT JOIN pg_depend d
        ON d.classid = 'pg_proc'::regclass
       AND d.objid = p.oid
       AND d.deptype = 'e'
      WHERE (
          n.nspname = 'platform'
          OR p.oid = to_regprocedure('#{@managed_public_function}')
        )
        AND d.objid IS NULL
        AND p.proowner <> r.oid

      UNION ALL

      SELECT 1
      FROM pg_proc p
      JOIN pg_roles r ON r.rolname = $1
      WHERE p.oid = to_regprocedure('#{@cnpg_pooler_auth_function}')
        AND p.proowner = r.oid
    )
    """
  end

  defp restore_cnpg_pooler_auth_function_ownership!(conn, app_user) do
    # v1.4.10 briefly claimed every non-extension function in public. Verify and
    # recreate CNPG's pooler lookup before returning it to a privileged owner.
    %{rows: rows} =
      Postgrex.query!(conn, cnpg_pooler_auth_function_recovery_query_sql(), [app_user])

    Enum.each(rows, fn [admin_user, language, result, security_definer, body] ->
      if admin_user == app_user do
        raise RuntimeError,
              "CNPG pooler auth ownership recovery requires database admin credentials"
      end

      if !cnpg_pooler_auth_function_canonical?(language, result, security_definer, body) do
        raise RuntimeError,
              "CNPG pooler auth function is not canonical; refusing admin ownership promotion"
      end

      case Postgrex.transaction(conn, fn transaction ->
             Postgrex.query!(
               transaction,
               "SELECT 1 FROM pg_catalog.pg_shadow LIMIT 0",
               []
             )

             ensure_cnpg_pooler_role!(transaction)

             Postgrex.query!(
               transaction,
               cnpg_pooler_auth_function_recreate_statement(),
               []
             )

             normalize_cnpg_pooler_auth_function_acl!(transaction)

             Postgrex.query!(
               transaction,
               cnpg_pooler_auth_function_owner_statement(admin_user),
               []
             )

             :ok
           end) do
        {:ok, :ok} ->
          :ok

        {:error, reason} ->
          raise RuntimeError,
                "CNPG pooler auth ownership recovery failed: #{inspect(reason)}"
      end
    end)
  end

  @doc false
  def cnpg_pooler_auth_function_recovery_query_sql do
    """
    SELECT current_user::text,
           l.lanname,
           pg_get_function_result(p.oid),
           p.prosecdef,
           btrim(p.prosrc)
    FROM pg_proc p
    JOIN pg_roles r ON r.rolname = $1
    JOIN pg_language l ON l.oid = p.prolang
    WHERE p.oid = to_regprocedure('#{@cnpg_pooler_auth_function}')
      AND p.proowner = r.oid
    """
  end

  @doc false
  def cnpg_pooler_auth_function_canonical?(language, result, security_definer, body) do
    normalized_body = normalize_sql_body(body)

    language == @cnpg_pooler_auth_language and
      result == @cnpg_pooler_auth_result and
      security_definer == true and
      normalized_body in [
        normalize_sql_body(@cnpg_pooler_auth_body),
        normalize_sql_body(@cnpg_pooler_auth_legacy_body)
      ]
  end

  @doc false
  def cnpg_pooler_auth_function_recreate_statement do
    """
    CREATE OR REPLACE FUNCTION public.user_search(uname text)
    RETURNS TABLE(usename name, passwd text)
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path = pg_catalog
    AS $function$
    #{@cnpg_pooler_auth_body}
    $function$
    """
  end

  @doc false
  def cnpg_pooler_auth_function_owner_statement(admin_user) when is_binary(admin_user) do
    function_ownership_statement("public", "user_search", "text", admin_user)
  end

  @doc false
  def cnpg_pooler_auth_function_grantees_query_sql do
    """
    SELECT DISTINCT grantee_role.rolname
    FROM pg_proc p
    CROSS JOIN LATERAL aclexplode(
      COALESCE(p.proacl, acldefault('f', p.proowner))
    ) AS acl
    JOIN pg_roles grantee_role ON grantee_role.oid = acl.grantee
    WHERE p.oid = to_regprocedure('#{@cnpg_pooler_auth_function}')
      AND acl.grantee <> p.proowner
    ORDER BY grantee_role.rolname
    """
  end

  @doc false
  def cnpg_pooler_auth_function_revoke_statement(role) when is_binary(role) do
    "REVOKE ALL PRIVILEGES ON FUNCTION \"public\".\"user_search\"(text) FROM #{quote_ident(role)}"
  end

  @doc false
  def cnpg_pooler_auth_function_grant_statement do
    "GRANT EXECUTE ON FUNCTION \"public\".\"user_search\"(text) TO #{quote_ident(@cnpg_pooler_role)}"
  end

  defp ensure_cnpg_pooler_role!(conn) do
    case Postgrex.query!(
           conn,
           "SELECT rolcanlogin FROM pg_roles WHERE rolname = $1",
           [@cnpg_pooler_role]
         ) do
      %{rows: [[true]]} ->
        :ok

      _ ->
        raise RuntimeError,
              "CNPG pooler auth ownership recovery requires the canonical pooler role"
    end
  end

  defp normalize_cnpg_pooler_auth_function_acl!(conn) do
    Postgrex.query!(
      conn,
      ~s{REVOKE ALL PRIVILEGES ON FUNCTION "public"."user_search"(text) FROM PUBLIC},
      []
    )

    %{rows: grantee_rows} =
      Postgrex.query!(conn, cnpg_pooler_auth_function_grantees_query_sql(), [])

    Enum.each(grantee_rows, fn [role] ->
      Postgrex.query!(conn, cnpg_pooler_auth_function_revoke_statement(role), [])
    end)

    Postgrex.query!(conn, cnpg_pooler_auth_function_grant_statement(), [])
  end

  defp normalize_sql_body(body) when is_binary(body) do
    body
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize_sql_body(_body), do: nil

  defp ensure_schema_owner!(conn, schema, app_user) do
    if admin_schema_exists?(conn, schema) do
      Postgrex.query!(
        conn,
        "ALTER SCHEMA #{quote_ident(schema)} OWNER TO #{quote_ident(app_user)}",
        []
      )
    end
  end

  defp admin_schema_exists?(conn, schema) do
    case Postgrex.query!(conn, "SELECT 1 FROM pg_namespace WHERE nspname = $1", [schema]) do
      %{rows: []} -> false
      _ -> true
    end
  end

  defp ensure_platform_relation_ownership!(conn, app_user) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT c.oid, n.nspname, c.relname, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_roles r ON r.rolname = $1
        LEFT JOIN pg_depend d
          ON d.classid = 'pg_class'::regclass
         AND d.objid = c.oid
         AND d.deptype = 'e'
        WHERE n.nspname = 'platform'
          AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
          AND d.objid IS NULL
          AND c.relowner <> r.oid
          AND (
            c.relkind <> 'S'
            OR NOT EXISTS (
              SELECT 1
              FROM pg_depend owned
              JOIN pg_class owner_rel ON owner_rel.oid = owned.refobjid
              WHERE owned.objid = c.oid
                AND owned.deptype = 'a'
                AND owner_rel.relkind = 'r'
            )
          )
        ORDER BY c.relkind, c.relname
        """,
        [app_user]
      )

    Enum.each(rows, fn [oid, schema, name, kind] ->
      case relation_ownership_statement(conn, oid, schema, name, kind, app_user) do
        nil ->
          :ok

        statement ->
          Postgrex.query!(conn, statement, [])
      end
    end)
  end

  defp ensure_continuous_aggregate_backing_privileges!(conn, app_user) do
    # Continuous aggregates are definer views over Timescale-owned internal tables.
    # Restores can leave the public view on the canonical owner while its backing-table
    # ACL still lacks SELECT, so platform-only ownership checks cannot see the drift.
    case Postgrex.query!(conn, continuous_aggregate_information_available_query_sql(), []) do
      %{rows: [[true]]} ->
        %{rows: rows} =
          Postgrex.query!(conn, continuous_aggregate_backing_privileges_query_sql(), [app_user])

        Enum.each(rows, fn [schema, name] ->
          Postgrex.query!(
            conn,
            continuous_aggregate_backing_grant_statement(schema, name, app_user),
            []
          )
        end)

      _ ->
        :ok
    end
  end

  @doc false
  def continuous_aggregate_information_available_query_sql do
    "SELECT to_regclass('timescaledb_information.continuous_aggregates') IS NOT NULL"
  end

  @doc false
  def continuous_aggregate_backing_privileges_query_sql do
    """
    SELECT ca.materialization_hypertable_schema,
           ca.materialization_hypertable_name
    FROM timescaledb_information.continuous_aggregates ca
    JOIN pg_namespace materialization_namespace
      ON materialization_namespace.nspname = ca.materialization_hypertable_schema
    JOIN pg_class materialization
      ON materialization.relnamespace = materialization_namespace.oid
     AND materialization.relname = ca.materialization_hypertable_name
    JOIN pg_roles r ON r.rolname = $1
    WHERE ca.view_schema = 'platform'
      AND ca.view_owner = r.rolname
      AND NOT has_table_privilege(r.oid, materialization.oid, 'SELECT')
    ORDER BY ca.materialization_hypertable_schema, ca.materialization_hypertable_name
    """
  end

  @doc false
  def continuous_aggregate_backing_grant_statement(schema, name, app_user)
      when is_binary(schema) and is_binary(name) and is_binary(app_user) do
    "GRANT SELECT ON TABLE #{quote_ident(schema)}.#{quote_ident(name)} TO #{quote_ident(app_user)}"
  end

  defp relation_ownership_statement(_conn, _oid, schema, name, kind, app_user)
       when kind in ["r", "p"] do
    "ALTER TABLE #{quote_ident(schema)}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
  end

  defp relation_ownership_statement(conn, oid, schema, name, "S", app_user) do
    if admin_sequence_owned_by_table?(conn, oid),
      do: nil,
      else:
        "ALTER SEQUENCE #{quote_ident(schema)}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
  end

  defp relation_ownership_statement(conn, _oid, schema, name, "v", app_user) do
    # TimescaleDB continuous aggregates are exposed as relkind 'v' but must be altered as
    # materialized views (ALTER VIEW is not supported).
    if admin_continuous_aggregate_view?(conn, schema, name) do
      "ALTER MATERIALIZED VIEW #{quote_ident(schema)}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
    else
      "ALTER VIEW #{quote_ident(schema)}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
    end
  end

  defp relation_ownership_statement(_conn, _oid, schema, name, "m", app_user) do
    "ALTER MATERIALIZED VIEW #{quote_ident(schema)}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
  end

  defp relation_ownership_statement(_conn, _oid, schema, name, "f", app_user) do
    "ALTER FOREIGN TABLE #{quote_ident(schema)}.#{quote_ident(name)} OWNER TO #{quote_ident(app_user)}"
  end

  defp relation_ownership_statement(_conn, _oid, _schema, _name, _kind, _app_user), do: nil

  # PostgreSQL refuses `ALTER SEQUENCE ... OWNER TO` on a sequence that belongs to a table
  # ("cannot change owner of sequence X / Sequence X is linked to table Y"), so the ownership
  # sweep has to recognise and skip them.
  #
  # Both dependency kinds count. `serial`/`bigserial` produce deptype 'a' (auto), but a
  # `GENERATED ... AS IDENTITY` column produces deptype 'i' (internal) -- checking only 'a'
  # left identity sequences looking free-standing, and the sweep then issued an ALTER the
  # server rejects. That aborted DatabaseBootstrap the first time any platform table used an
  # identity column (cold_chunk_exports), which is how it was found; it was latent in every
  # release before that only because none did.
  #
  # 'p' alongside 'r' so a partitioned table's identity sequence is caught too.
  defp admin_sequence_owned_by_table?(conn, sequence_oid) do
    case Postgrex.query!(
           conn,
           "SELECT 1\n" <>
             "FROM pg_depend d\n" <>
             "JOIN pg_class c ON c.oid = d.refobjid\n" <>
             "WHERE d.objid = $1\n" <>
             "AND d.deptype IN ('a', 'i')\n" <>
             "AND c.relkind IN ('r', 'p')\n" <>
             "LIMIT 1",
           [sequence_oid]
         ) do
      %{rows: []} -> false
      _ -> true
    end
  end

  defp admin_continuous_aggregate_view?(conn, schema, name)
       when is_binary(schema) and is_binary(name) do
    case Postgrex.query!(
           conn,
           "SELECT 1 FROM timescaledb_information.continuous_aggregates\n" <>
             "WHERE view_schema = $1 AND view_name = $2\n" <>
             "LIMIT 1",
           [schema, name]
         ) do
      %{rows: []} -> false
      _ -> true
    end
  rescue
    _ -> false
  end

  defp ensure_managed_function_ownership!(conn, app_user) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        managed_function_ownership_query_sql(),
        [app_user]
      )

    Enum.each(rows, fn [schema, name, args] ->
      Postgrex.query!(conn, function_ownership_statement(schema, name, args, app_user), [])
    end)
  end

  @doc false
  def managed_function_ownership_query_sql do
    """
    SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_roles r ON r.rolname = $1
    LEFT JOIN pg_depend d
      ON d.classid = 'pg_proc'::regclass
     AND d.objid = p.oid
     AND d.deptype = 'e'
    WHERE (
        n.nspname = 'platform'
        OR p.oid = to_regprocedure('#{@managed_public_function}')
      )
      AND d.objid IS NULL
      AND p.proowner <> r.oid
    ORDER BY n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)
    """
  end

  @doc false
  def function_ownership_statement(schema, name, args, app_user)
      when is_binary(schema) and is_binary(name) and is_binary(args) and is_binary(app_user) do
    "ALTER FUNCTION #{quote_ident(schema)}.#{quote_ident(name)}(#{args}) OWNER TO #{quote_ident(app_user)}"
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

  defp sync_legacy_public_schema_migrations! do
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

  defp run_migrations_with_repair! do
    migrations_path = Application.app_dir(:serviceradar_core, "priv/repo/migrations")
    do_run_migrations_with_repair!(migrations_path, @max_migration_repair_attempts)
  end

  defp run_bootstrap_or_migrations!(app_user) do
    migrations_path = Application.app_dir(:serviceradar_core, "priv/repo/migrations")

    case database_bootstrap_state() do
      :empty ->
        Logger.info(
          "[StartupMigrations] Empty platform database detected; applying schema baseline"
        )

        SchemaBootstrap.apply_baseline!(ServiceRadar.Repo, migrations_path)
        run_migrations_with_repair!()

      :migrated ->
        Logger.info(
          "[StartupMigrations] Existing migration history detected; running pending migrations"
        )

        ensure_platform_schema!(app_user)
        sync_legacy_public_schema_migrations!()
        do_run_migrations_with_repair!(migrations_path, @max_migration_repair_attempts)

      {:ambiguous, details} ->
        raise RuntimeError,
              "ambiguous ServiceRadar database state; refusing automatic schema bootstrap. " <>
                "Platform objects exist without coherent migration history. " <>
                "Restore from backup or repair platform.schema_migrations before retrying. " <>
                "Details: #{inspect(details)}"
    end
  end

  defp database_bootstrap_state do
    SchemaBootstrap.classify(ServiceRadar.Repo)
  end

  defp do_run_migrations_with_repair!(_migrations_path, 0) do
    raise RuntimeError,
          "migration self-repair exhausted #{@max_migration_repair_attempts} attempts"
  end

  defp do_run_migrations_with_repair!(migrations_path, attempts_left) do
    case next_pending_migration_version(migrations_path) do
      nil ->
        :ok

      version ->
        try do
          Ecto.Migrator.run(
            ServiceRadar.Repo,
            migrations_path,
            :up,
            step: 1,
            prefix: "platform"
          )
        rescue
          error in Postgrex.Error ->
            if duplicate_ddl_error?(error) do
              Logger.warning(
                "[StartupMigrations] Duplicate DDL while running migration #{version}; " <>
                  "marking as applied and continuing: #{postgres_error_summary(error)}"
              )

              mark_platform_migration_applied!(version)
            else
              reraise error, __STACKTRACE__
            end
        end

        do_run_migrations_with_repair!(migrations_path, attempts_left - 1)
    end
  end

  defp next_pending_migration_version(migrations_path) do
    migrated_versions =
      ServiceRadar.Repo
      |> Ecto.Migrator.migrated_versions(prefix: "platform")
      |> MapSet.new()

    migrations_path
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&migration_version_from_file/1)
    |> Enum.reject(&MapSet.member?(migrated_versions, &1))
    |> Enum.sort()
    |> List.first()
  end

  defp migration_version_from_file(path), do: SchemaBootstrap.migration_version_from_file(path)

  defp duplicate_ddl_error?(%Postgrex.Error{postgres: %{code: code}}) do
    code in [:duplicate_column, :duplicate_table, :duplicate_object, :duplicate_function] or
      code in ["42701", "42P07", "42710", "42723"]
  end

  defp duplicate_ddl_error?(_), do: false

  defp postgres_error_summary(%Postgrex.Error{postgres: %{code: code, message: message}}),
    do: "#{code} #{message}"

  defp postgres_error_summary(error), do: inspect(error)

  defp mark_platform_migration_applied!(version) when is_integer(version) do
    # Self-repair must mark the ledger read by `next_pending_migration_version/1` to converge;
    # see SchemaBootstrap.migration_ledger_table/1 for the ledger selection contract.
    ledger = SchemaBootstrap.migration_ledger_table(ServiceRadar.Repo)

    ServiceRadar.Repo.query!(
      """
      INSERT INTO #{ledger} (version, inserted_at)
      VALUES ($1, NOW())
      ON CONFLICT (version) DO NOTHING
      """,
      [version]
    )
  end

  defp table_exists?(qualified_table) do
    case ServiceRadar.Repo.query!("SELECT to_regclass($1)", [qualified_table]) do
      %{rows: [[nil]]} -> false
      %{rows: [[_]]} -> true
    end
  end

  defp ensure_app_database_exists!(database) do
    if repo_connected_to_database?(database) do
      :ok
    else
      admin_database = System.get_env("CNPG_ADMIN_DATABASE", "postgres")
      attempts = parse_int(System.get_env("SERVICERADAR_DB_BOOTSTRAP_ATTEMPTS"), 30)
      delay_ms = parse_int(System.get_env("SERVICERADAR_DB_BOOTSTRAP_DELAY_MS"), 2000)

      with_retry(attempts, delay_ms, fn ->
        case execute_with_admin_credentials(
               fn conn ->
                 try do
                   %{rows: rows} =
                     Postgrex.query!(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [
                       database
                     ])

                   if rows == [] do
                     Logger.info("[StartupMigrations] Creating database #{database}")
                     Postgrex.query!(conn, "CREATE DATABASE #{quote_ident(database)}")
                   else
                     Logger.info(
                       "[StartupMigrations] Database #{database} already exists; skipping"
                     )
                   end

                   :ok
                 rescue
                   e in [DBConnection.ConnectionError, Postgrex.Error] ->
                     {:retry, e}
                 end
               end,
               admin_database
             ) do
          :ok ->
            :ok

          {:ok, :ok} ->
            :ok

          {:retry, reason} ->
            {:retry, reason}

          {:ok, {:retry, reason}} ->
            {:retry, reason}

          {:error, reason} ->
            {:retry, reason}
        end
      end)
    end
  end

  defp repo_connected_to_database?(database) do
    if repo_enabled?() do
      case ServiceRadar.Repo.query!("SELECT current_database()") do
        %{rows: [[^database]]} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp admin_connection_attempts do
    primary = {
      read_text_file(System.get_env("CNPG_ADMIN_USERNAME_FILE")) ||
        System.get_env("CNPG_ADMIN_USERNAME") ||
        read_text_file(System.get_env("CNPG_USERNAME_FILE")) || System.get_env("CNPG_USERNAME"),
      read_text_file(System.get_env("CNPG_ADMIN_PASSWORD_FILE")) ||
        System.get_env("CNPG_ADMIN_PASSWORD") ||
        read_text_file(System.get_env("CNPG_PASSWORD_FILE")) || System.get_env("CNPG_PASSWORD"),
      "configured admin credentials"
    }

    configured =
      case primary do
        {nil, _, _} -> []
        {"", _, _} -> []
        {user, nil, label} -> [{user, "", label}]
        {user, pwd, label} -> [{user, pwd, label}]
      end

    app_user = app_user()
    app_password = app_password_or_nil()

    # Only include fallback when app credentials are usable and different from primary.
    {primary_user, primary_password, _primary_label} = primary

    app_creds =
      if app_password in [nil, ""],
        do: [],
        else: [{app_user, app_password, "application credentials"}]

    if_result =
      if primary_user == app_user and primary_password == app_password do
        configured
      else
        configured ++ app_creds
      end

    if_result
    |> Enum.reject(fn
      {nil, _, _} -> true
      {_, nil, _} -> true
      {_, "", _} -> true
      _ -> false
    end)
    |> Enum.uniq_by(fn {user, password, _label} -> {user, password} end)
    |> Enum.map(fn {user, password, label} ->
      {user, password, label}
    end)
  end

  defp admin_connection_opts(admin_user, admin_password, database) do
    [
      hostname: System.get_env("CNPG_HOST", "localhost"),
      port: parse_int(System.get_env("CNPG_PORT"), 5432),
      username: admin_user,
      password: admin_password,
      database: database,
      ssl: admin_ssl_opts()
    ]
  end

  defp execute_with_admin_credentials(fun, database \\ app_database()) do
    execute_with_admin_credentials(admin_connection_attempts(), fun, database)
  end

  defp execute_with_admin_credentials([], _fun, _database), do: {:error, :no_admin_credentials}

  defp execute_with_admin_credentials([{user, password, label} | rest], fun, database) do
    opts = admin_connection_opts(user, password, database)

    case Postgrex.start_link(opts) do
      {:ok, conn} ->
        try do
          {:ok, fun.(conn)}
        after
          GenServer.stop(conn)
        end

      {:error, reason} ->
        if fallback_needed?(reason, rest) do
          Logger.warning(
            "[StartupMigrations] Admin connect with #{label} failed (#{inspect(reason)}), trying alternate credentials"
          )

          execute_with_admin_credentials(rest, fun, database)
        else
          {:error, reason}
        end
    end
  end

  defp fallback_needed?(reason, remaining_attempts) do
    invalid_admin_credentials_error?(reason) && remaining_attempts != []
  end

  defp invalid_admin_credentials_error?(%Postgrex.Error{postgres: %{code: code}})
       when code in ["28P01", :invalid_password, :invalid_authorization_specification] do
    true
  end

  defp invalid_admin_credentials_error?(%Postgrex.Error{postgres: %{message: message}})
       when is_binary(message) do
    String.contains?(message, "password authentication failed")
  end

  defp invalid_admin_credentials_error?(%DBConnection.ConnectionError{message: message})
       when is_binary(message) do
    String.contains?(message, "password authentication failed") or
      String.contains?(message, "FATAL 28P01")
  end

  defp invalid_admin_credentials_error?(_reason), do: false

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
            "CNPG_TLS_SERVER_NAME" |> System.get_env() |> to_sni()
          )

        opts
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
