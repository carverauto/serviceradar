defmodule ServiceRadar.Cluster.DatabaseBootstrapIntegrationTest do
  use ServiceRadar.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 180_000

  @result_prefix "BOOTSTRAP_RESULT:"
  @admin_url System.get_env("SERVICERADAR_TEST_ADMIN_URL") ||
               System.get_env("SRQL_TEST_ADMIN_URL")

  if @admin_url in [nil, ""] do
    @moduletag skip: "set SERVICERADAR_TEST_ADMIN_URL or SRQL_TEST_ADMIN_URL"
  end

  setup_all do
    {:ok, admin_url: @admin_url, admin_opts: postgres_opts(@admin_url)}
  end

  setup %{admin_opts: admin_opts} do
    scratch_db = "serviceradar_bootstrap_test_#{System.unique_integer([:positive])}"

    create_database!(admin_opts, scratch_db)

    on_exit(fn ->
      drop_database!(admin_opts, scratch_db)
    end)

    {:ok, scratch_db: scratch_db}
  end

  test "startup applies baseline once and reruns through migration history", %{
    admin_url: admin_url,
    scratch_db: scratch_db
  } do
    first = run_startup_migrations!(admin_url, scratch_db)

    assert first["baseline_count"] == 1
    assert first["migration_count"] > 0
    assert first["platform_object_count"] > 0

    second = run_startup_migrations!(admin_url, scratch_db)

    assert second["baseline_count"] == 1
    assert second["migration_count"] == first["migration_count"]
    assert second["platform_object_count"] == first["platform_object_count"]
  end

  defp run_startup_migrations!(admin_url, database) do
    env = subprocess_env(admin_url, database)
    code = startup_code()

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", code],
        env: env,
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    assert status == 0, output

    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      if String.starts_with?(line, @result_prefix) do
        line
        |> String.replace_prefix(@result_prefix, "")
        |> Jason.decode!()
      end
    end) || flunk("bootstrap result marker not found in output:\n#{output}")
  end

  defp startup_code do
    ~S'''
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    Logger.configure(level: :warning)
    Application.put_env(:serviceradar_core, :run_startup_migrations, true)
    Application.put_env(:serviceradar_core, :repo_enabled, true)
    {:ok, _pid} = ServiceRadar.Repo.start_link()
    :ok = ServiceRadar.Cluster.StartupMigrations.run!()

    %{rows: [[migration_count]]} =
      ServiceRadar.Repo.query!("SELECT count(*) FROM platform.schema_migrations")

    %{rows: [[baseline_count]]} =
      ServiceRadar.Repo.query!("SELECT count(*) FROM platform.serviceradar_schema_baselines")

    %{rows: [[platform_object_count]]} =
      ServiceRadar.Repo.query!("""
      SELECT count(*)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'platform'
      AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
      """)

    IO.puts("BOOTSTRAP_RESULT:" <> Jason.encode!(%{
      migration_count: migration_count,
      baseline_count: baseline_count,
      platform_object_count: platform_object_count
    }))
    '''
  end

  defp subprocess_env(admin_url, database) do
    uri = URI.parse(admin_url)
    query = URI.decode_query(uri.query || "")
    sslmode = query["sslmode"] || System.get_env("CNPG_SSL_MODE") || "require"
    app_user = "serviceradar_bootstrap_test"
    app_password = "serviceradar_bootstrap_test"

    Enum.reject(
      [
        {"MIX_ENV", "test"},
        {"SERVICERADAR_TEST_DATABASE_URL", database_url(admin_url, database)},
        {"SERVICERADAR_TEST_DATABASE_POOL_SIZE", "2"},
        {"CNPG_HOST", uri.host || "localhost"},
        {"CNPG_PORT", Integer.to_string(uri.port || 5432)},
        {"CNPG_DATABASE", database},
        {"CNPG_USERNAME", username(uri)},
        {"CNPG_PASSWORD", password(uri)},
        {"CNPG_ADMIN_USERNAME", username(uri)},
        {"CNPG_ADMIN_PASSWORD", password(uri)},
        {"CNPG_APP_USER", app_user},
        {"CNPG_APP_PASSWORD", app_password},
        {"CNPG_SSL_MODE", sslmode},
        {"CNPG_TLS_SERVER_NAME",
         System.get_env("CNPG_TLS_SERVER_NAME") || uri.host || "localhost"},
        {"SERVICERADAR_TEST_DATABASE_CA_CERT_FILE", ca_file()},
        {"SERVICERADAR_TEST_DATABASE_CERT", cert_file()},
        {"SERVICERADAR_TEST_DATABASE_KEY", key_file()},
        {"SRQL_TEST_DATABASE_CA_CERT_FILE", ca_file()},
        {"SRQL_TEST_DATABASE_CERT", cert_file()},
        {"SRQL_TEST_DATABASE_KEY", key_file()},
        {"CNPG_CERT_FILE", cert_file()},
        {"CNPG_KEY_FILE", key_file()},
        {"PGSSLROOTCERT", ca_file()}
      ],
      fn {_key, value} -> value in [nil, ""] end
    )
  end

  defp ca_file do
    System.get_env("SERVICERADAR_TEST_DATABASE_CA_CERT_FILE") ||
      System.get_env("SRQL_TEST_DATABASE_CA_CERT_FILE") ||
      System.get_env("CNPG_CA_FILE") ||
      System.get_env("PGSSLROOTCERT")
  end

  defp cert_file do
    System.get_env("SERVICERADAR_TEST_DATABASE_CERT") ||
      System.get_env("SRQL_TEST_DATABASE_CERT") ||
      System.get_env("CNPG_CERT_FILE") ||
      cert_dir_file("workstation.pem")
  end

  defp key_file do
    System.get_env("SERVICERADAR_TEST_DATABASE_KEY") ||
      System.get_env("SRQL_TEST_DATABASE_KEY") ||
      System.get_env("CNPG_KEY_FILE") ||
      cert_dir_file("workstation-key.pem")
  end

  defp cert_dir_file(file) do
    case System.get_env("CNPG_CERT_DIR") do
      value when value in [nil, ""] -> nil
      dir -> Path.join(dir, file)
    end
  end

  defp database_url(url, database) do
    url
    |> URI.parse()
    |> Map.put(:path, "/" <> database)
    |> URI.to_string()
  end

  defp postgres_opts(url) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    sslmode = query["sslmode"] || System.get_env("CNPG_SSL_MODE") || "require"

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: username(uri),
      password: password(uri),
      database: database_name(uri),
      ssl: ssl_opts(sslmode, uri.host)
    ]
  end

  defp username(%URI{userinfo: nil}), do: System.get_env("CNPG_USERNAME") || "postgres"

  defp username(%URI{userinfo: userinfo}) do
    userinfo
    |> String.split(":", parts: 2)
    |> hd()
    |> URI.decode_www_form()
  end

  defp password(%URI{userinfo: nil}), do: System.get_env("CNPG_PASSWORD") || ""

  defp password(%URI{userinfo: userinfo}) do
    case String.split(userinfo, ":", parts: 2) do
      [_user, password] -> URI.decode_www_form(password)
      [_user] -> ""
    end
  end

  defp database_name(%URI{path: nil}), do: "postgres"
  defp database_name(%URI{path: ""}), do: "postgres"
  defp database_name(%URI{path: "/" <> database}), do: database

  defp ssl_opts("disable", _host), do: false
  defp ssl_opts("allow", _host), do: false
  defp ssl_opts("prefer", _host), do: false

  defp ssl_opts(mode, host) do
    verify = if mode in ["verify-ca", "verify-full"], do: :verify_peer, else: :verify_none

    []
    |> Keyword.put(:verify, verify)
    |> maybe_put(:cacertfile, ca_file())
    |> maybe_put(:certfile, cert_file())
    |> maybe_put(:keyfile, key_file())
    |> maybe_put(:server_name_indication, host && to_charlist(host))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp create_database!(admin_opts, database) do
    with_admin_connection!(admin_opts, fn conn ->
      Postgrex.query!(conn, "CREATE DATABASE #{quote_ident(database)}", [])
    end)
  end

  defp drop_database!(admin_opts, database) do
    with_admin_connection!(admin_opts, fn conn ->
      Postgrex.query!(
        conn,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1",
        [database]
      )

      Postgrex.query!(conn, "DROP DATABASE IF EXISTS #{quote_ident(database)}", [])
    end)
  end

  defp with_admin_connection!(opts, fun) do
    {:ok, conn} = Postgrex.start_link(opts)

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  defp quote_ident(value) do
    ~s("#{String.replace(value, "\"", "\"\"")}")
  end
end
