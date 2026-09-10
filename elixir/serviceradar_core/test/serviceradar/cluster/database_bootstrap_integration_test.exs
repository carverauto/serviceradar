defmodule ServiceRadar.Cluster.DatabaseBootstrapIntegrationTest do
  @moduledoc """
  Startup migrations against a scratch database, run TWICE on purpose.

  `ServiceRadar.Cluster.StartupMigrations.run!/1` branches on `database_bootstrap_state/0`:

    * `:empty`    -> apply the schema baseline, then the migration history. First boot.
    * `:migrated` -> skip the baseline, apply only what is pending. EVERY pod restart.

  The second invocation is not a repeat, it is the only coverage of the `:migrated` branch --
  the one production actually takes on every restart. Its assertions (baseline still applied
  exactly once, migration count unchanged, platform object count unchanged) are what catch a
  regression that would re-baseline a live database. Collapsing this to a single run would
  leave only the rare first-boot path covered.

  Deliberately NOT `use ServiceRadar.DataCase`. This test drives its own scratch database
  through raw Postgrex and runs the migrations in a subprocess; the test process never
  touches `ServiceRadar.Repo`. DataCase checked out a sandbox connection and held it idle for
  the several minutes the test spends blocked in `System.cmd/3`, which exhausted the pool for
  everything else:

      ** (DBConnection.ConnectionError) connection not available and request was dropped from
         queue after 4000ms
  """
  use ExUnit.Case, async: false

  import ExUnit.Assertions

  alias ServiceRadar.DB.FixtureConfig
  alias ServiceRadar.Repo.SchemaBootstrap

  @moduletag :integration
  @moduletag :requires_app
  # 180s was enough for two bootstrap runs on a quiet fixture and left
  # almost nothing for on_exit DROP. Under eight shards that leftover
  # budget was the 57014 cancel. Give cleanup a real window.
  @moduletag timeout: 300_000

  # Admin DDL (CREATE/DROP DATABASE) runs on its own Postgrex connection, where
  # DBConnection's default :timeout is 15s. That default is sized for queries,
  # not for dropping a database on a shared fixture under eight parallel shards.
  @admin_query_timeout 120_000

  @result_prefix "BOOTSTRAP_RESULT:"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    # This target is part of the guarded fixture lifecycle. Resolve its DDL connection from the
    # same typed SERVICERADAR_ENV instance as provisioning and the suite; never accept a legacy
    # ambient admin DSN that could point the scratch CREATE/DROP at another server. Keep the secret
    # in setup state rather than compiling it into the test module as an attribute.
    admin_url = FixtureConfig.admin_url!("postgres")
    assert_usable_admin_password!(admin_url)

    {subprocess_ca_file, remove_subprocess_ca_file?} = subprocess_ca_file()

    if remove_subprocess_ca_file? do
      on_exit(fn ->
        case File.rm(subprocess_ca_file) do
          :ok -> :ok
          {:error, reason} -> raise "failed to remove bootstrap CA file: #{inspect(reason)}"
        end
      end)
    end

    {:ok,
     admin_url: admin_url,
     admin_opts: postgres_opts(admin_url),
     subprocess_ca_file: subprocess_ca_file}
  end

  # A missing admin password is a partially configured guarded fixture and fails while the typed
  # URL above is resolved rather than silently skipping the release qualification.
  #
  # StartupMigrations reaches PostgreSQL as an administrator through
  # `admin_connection_attempts/0`, which drops every candidate whose password is empty. Hand
  # it CNPG_ADMIN_PASSWORD="" and the superuser entry it just built is discarded, leaving only
  # the application role -- the subprocess then runs the whole bootstrap unprivileged and dies
  # deep inside ownership repair with
  #
  #   ** (Postgrex.Error) ERROR 42501 (insufficient_privilege) must be owner of schema platform
  #
  # which names neither the credentials nor this test. A trust-authenticated developer
  # fixture is the usual way to end up here; CI is unaffected because its admin DSN carries a
  # password. Any password satisfies the check -- under `trust` PostgreSQL ignores the value,
  # and it exists only to keep the credential from being discarded.
  defp assert_usable_admin_password!(url) do
    if password(URI.parse(url)) in [nil, ""] do
      flunk("""
      The admin DSN has no password, so this test cannot run the bootstrap with administrator
      privileges: StartupMigrations discards passwordless admin credentials and would fall
      back to the unprivileged application role.

      Configure database.admin_password for the selected SERVICERADAR_ENV identity. The guarded
      CI lifecycle selects the srql-fixtures `ci` instance and resolves that secret before this
      module can issue any DDL.
      """)
    end
  end

  setup %{admin_opts: admin_opts} do
    # Integration shards and retries use independent BEAM VMs against the same CNPG fixture,
    # so System.unique_integer/1 alone cannot make the database name globally unique.
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    # The `sr_core_test_` prefix lets a later stale sweep recover residue after infrastructure
    # failure. The current heavy action still fails unless its own on_exit DROP succeeds.
    scratch_db = "sr_core_test_bootstrap_#{suffix}"

    create_database!(admin_opts, scratch_db)
    install_required_extensions!(admin_opts, scratch_db)

    on_exit(fn ->
      drop_database!(admin_opts, scratch_db)
    end)

    {:ok, scratch_db: scratch_db}
  end

  test "startup applies baseline once and reruns through migration history", %{
    admin_url: admin_url,
    scratch_db: scratch_db,
    subprocess_ca_file: subprocess_ca_file
  } do
    first = run_startup_migrations!(admin_url, scratch_db, subprocess_ca_file)

    assert first["baseline_count"] == 1
    assert first["migration_count"] > 0
    assert first["platform_object_count"] > 0
    assert first["logs_hypertable_present"] == true
    assert first["logs_severity_rollup_present"] == true

    assert first["logs_severity_rollup_columns"] == [
             "bucket",
             "service_name",
             "total_count",
             "fatal_count",
             "error_count",
             "warning_count",
             "info_count",
             "debug_count"
           ]

    assert first["auth_settings"] == %{
             "count" => 1,
             "mode" => "password_only",
             "is_enabled" => false,
             "allow_password_fallback" => true,
             "sso_auto_provision" => false
           }

    second = run_startup_migrations!(admin_url, scratch_db, subprocess_ca_file)

    assert second["baseline_count"] == 1
    assert second["migration_count"] == first["migration_count"]
    assert second["platform_object_count"] == first["platform_object_count"]
    assert second["logs_hypertable_present"] == true
    assert second["logs_severity_rollup_present"] == true
    assert second["logs_severity_rollup_columns"] == first["logs_severity_rollup_columns"]
    assert second["auth_settings"] == first["auth_settings"]
  end

  test "the migrator path baselines instead of replaying the whole history", %{
    admin_url: admin_url,
    scratch_db: scratch_db,
    subprocess_ca_file: subprocess_ca_file
  } do
    # Regression cover for issue #4151. `mix ecto.migrate` and the fixture template target used
    # to replay every migration on an empty database, including the 318 the committed baseline
    # already contains -- which is what put `20260126120000` on the path at all.
    #
    # The decisive number is how many migrations Ecto ACTUALLY applied. Counting recorded
    # versions cannot distinguish the two paths: a baselined bootstrap and a full replay both
    # end with every version in `schema_migrations`. If the wiring is reverted, applied_count
    # becomes the full on-disk count and this fails.
    metadata = SchemaBootstrap.baseline_metadata!()
    included_through = metadata["included_through"]

    on_disk =
      :serviceradar_core
      |> Application.app_dir("priv/repo/migrations")
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&SchemaBootstrap.migration_version_from_file/1)

    expected_applied = Enum.count(on_disk, &(&1 > included_through))

    # Guard the guard: if the baseline ever covered nothing, the assertion below would pass
    # trivially against a full replay.
    assert expected_applied < length(on_disk),
           "baseline covers no migrations; this test could not detect a full replay"

    result = run_migrator_bootstrap!(admin_url, scratch_db, subprocess_ca_file)

    assert result["applied_count"] == expected_applied,
           """
           the migrator path applied #{result["applied_count"]} migrations, expected \
           #{expected_applied}.

           #{length(on_disk)} migrations exist on disk and the baseline covers through \
           #{included_through}. Applying all of them means the baseline bootstrap was skipped \
           and every fresh database is back to a full replay -- see issue #4151.
           """

    assert result["baseline_count"] == 1
    assert result["recorded_count"] == length(on_disk)
  end

  test "the migrator path records the baseline in the repo's configured ledger", %{
    admin_url: admin_url,
    scratch_db: scratch_db,
    subprocess_ca_file: subprocess_ca_file
  } do
    # Regression cover for issue #321. `mix serviceradar.db.migrate` runs under web-ng's
    # config, where `:migration_source` is `"ash_schema_migrations"`, but the baseline used
    # to record every covered version in `platform.schema_migrations` -- a table Ecto never
    # reads there. The migrator then saw zero applied versions and replayed the whole
    # baseline, dying on duplicate-table errors.
    #
    # Like the test above, the decisive number is how many migrations Ecto ACTUALLY applied:
    # with the marks in the table it reads, only the post-baseline migrations run. Counting
    # recorded versions in the wrong table could not tell the two paths apart -- which is
    # exactly how this bug hid.
    metadata = SchemaBootstrap.baseline_metadata!()
    included_through = metadata["included_through"]

    on_disk =
      :serviceradar_core
      |> Application.app_dir("priv/repo/migrations")
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&SchemaBootstrap.migration_version_from_file/1)

    expected_applied = Enum.count(on_disk, &(&1 > included_through))

    # Guard the guard: if the baseline ever covered nothing, the assertion below would pass
    # trivially against a full replay.
    assert expected_applied < length(on_disk),
           "baseline covers no migrations; this test could not detect a full replay"

    result =
      run_migrator_bootstrap_with_source!(
        admin_url,
        scratch_db,
        subprocess_ca_file,
        "ash_schema_migrations"
      )

    assert result["applied_count"] == expected_applied,
           """
           the migrator path applied #{result["applied_count"]} migrations, expected \
           #{expected_applied}.

           #{length(on_disk)} migrations exist on disk and the baseline covers through \
           #{included_through}. Applying all of them means the baseline marks landed in a \
           ledger the migrator does not read and every fresh database is back to a full \
           replay -- see issue #321.
           """

    assert result["baseline_count"] == 1
    assert result["recorded_count"] == length(on_disk)
  end

  defp run_migrator_bootstrap!(admin_url, database, subprocess_ca_file) do
    run_subprocess!(admin_url, database, subprocess_ca_file, migrator_code())
  end

  defp run_migrator_bootstrap_with_source!(admin_url, database, subprocess_ca_file, source) do
    run_subprocess!(
      admin_url,
      database,
      subprocess_ca_file,
      migrator_code("platform.#{source}"),
      [{"SERVICERADAR_TEST_MIGRATION_SOURCE", source}]
    )
  end

  defp run_startup_migrations!(admin_url, database, subprocess_ca_file) do
    run_subprocess!(admin_url, database, subprocess_ca_file, startup_code())
  end

  defp run_subprocess!(admin_url, database, subprocess_ca_file, code, extra_env \\ []) do
    env = subprocess_env(admin_url, database, subprocess_ca_file, extra_env)

    # `elixir -e`, not `mix run -e`.
    #
    # Mix needs a project: under Bazel the test runs in a sandbox that has the compiled
    # application on its code path but no mix.exs, and `mix run` aborts with
    #
    #   ** (Mix) Cannot execute "mix run" without a Mix.Project
    #
    # before it evaluates anything. Handing the parent's own code path to a plain `elixir`
    # gives the child exactly the applications this test already has loaded, which is what
    # `mix run --no-start` was being used for in the first place, and works the same under
    # `mix test` and under Bazel.
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    elixir =
      System.find_executable("elixir") ||
        flunk("elixir executable not found on PATH; cannot run the bootstrap subprocess")

    {output, status} =
      System.cmd(elixir, code_paths ++ ["-e", code],
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
    subprocess_preamble() <>
      ~S'''
      :ok = ServiceRadar.Cluster.StartupMigrations.run!()
      ''' <> startup_tail()
  end

  # Everything up to and including `ServiceRadar.Repo.start_link()`. Shared by the startup path
  # above and the migrator path below so the two cannot drift in how they boot the Repo -- the
  # comments here were all earned by a specific failure and are worth having in one place.
  defp subprocess_preamble do
    ~S'''
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    Logger.configure(level: :warning)

    # Load the project config the way `mix run` used to.
    #
    # `mix run` evaluated config/config.exs and config/runtime.exs before running the given
    # code; plain `elixir -e` evaluates neither. Without them ServiceRadar.Repo starts with no
    # connection settings at all -- config/runtime.exs is what turns
    # SERVICERADAR_TEST_DATABASE_URL (handed to this process in subprocess_env/2) into the
    # Repo's url/ssl/pool options. The Repo then retries a connection it can never make and
    # the parent blocks in System.cmd until ExUnit's timeout kills the whole test, with no
    # error to show for it.
    #
    # Loaded persistently for the same reason //build:elixir_test_config_loader.exs does:
    # Application.load/1 on an app configured earlier resets its env from its .app file.
    for file <- ["config/config.exs", "config/runtime.exs"], File.exists?(file) do
      file
      |> Config.Reader.read!(env: :test, target: :host)
      |> Application.put_all_env(persistent: true)
    end

    Application.put_env(:serviceradar_core, :run_startup_migrations, true)
    Application.put_env(:serviceradar_core, :repo_enabled, true)

    # config/test.exs gives the Repo an SQL Sandbox pool. That is right for ordinary tests and
    # wrong for this production-startup subprocess: a long migration holds the sandbox-owned
    # connection until its 120-second ownership timeout kills the child midway through the
    # baseline. The subprocess owns a unique scratch database, so use the normal pool exactly
    # as the standalone migration lifecycle target does.
    repo_opts =
      :serviceradar_core
      |> Application.get_env(ServiceRadar.Repo, [])
      |> Keyword.drop([:pool, :ownership_timeout, :pool_size])
      |> Keyword.put(:timeout, :infinity)
      |> Keyword.put(:pool_size, 2)

    # Test-only hook so one test can boot the Repo the way web-ng configures it
    # (`migration_source: "ash_schema_migrations"`). Unset everywhere else, where this
    # changes nothing.
    repo_opts =
      case System.get_env("SERVICERADAR_TEST_MIGRATION_SOURCE") do
        nil -> repo_opts
        "" -> repo_opts
        source -> Keyword.put(repo_opts, :migration_source, source)
      end

    Application.put_env(:serviceradar_core, ServiceRadar.Repo, repo_opts)
    {:ok, _pid} = ServiceRadar.Repo.start_link()
    '''
  end

  # The migrator path: what `mix serviceradar.db.migrate` and
  # //elixir/serviceradar_core:migrate_db do. Reports how many migrations `Ecto.Migrator`
  # ACTUALLY applied, which is the number that distinguishes a baselined bootstrap from a full
  # replay -- both end with every version recorded, so counting recorded versions cannot tell
  # them apart.
  defp migrator_code(ledger_table \\ "platform.schema_migrations") do
    subprocess_preamble() <>
      ~S'''
      migrations_path = Application.app_dir(:serviceradar_core, "priv/repo/migrations")

      :empty = ServiceRadar.Repo.SchemaBootstrap.classify(ServiceRadar.Repo)
      :ok = ServiceRadar.Repo.SchemaBootstrap.apply_baseline!(ServiceRadar.Repo, migrations_path)

      applied = Ecto.Migrator.run(ServiceRadar.Repo, :up, all: true)

      ''' <>
      """
      %{rows: [[recorded_count]]} =
        ServiceRadar.Repo.query!("SELECT count(*) FROM #{ledger_table}")
      """ <>
      ~S'''
      %{rows: [[baseline_count]]} =
        ServiceRadar.Repo.query!("SELECT count(*) FROM platform.serviceradar_schema_baselines")

      IO.puts("BOOTSTRAP_RESULT:" <> Jason.encode!(%{
        applied_count: length(applied),
        recorded_count: recorded_count,
        baseline_count: baseline_count
      }))
      '''
  end

  defp startup_tail do
    ~S'''
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

    %{rows: [[logs_hypertable_present]]} =
      ServiceRadar.Repo.query!("""
      SELECT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform'
          AND hypertable_name = 'logs'
      )
      """)

    %{rows: [[logs_severity_rollup_present]]} =
      ServiceRadar.Repo.query!("""
      SELECT EXISTS (
        SELECT 1
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'platform'
          AND view_name = 'logs_severity_stats_5m'
      )
      """)

    %{rows: [[logs_severity_rollup_columns]]} =
      ServiceRadar.Repo.query!("""
      SELECT array_agg(column_name::text ORDER BY ordinal_position)
      FROM information_schema.columns
      WHERE table_schema = 'platform'
        AND table_name = 'logs_severity_stats_5m'
      """)

    %{rows: auth_rows} =
      ServiceRadar.Repo.query!("""
      SELECT mode, is_enabled, allow_password_fallback, sso_auto_provision
      FROM platform.auth_settings
      ORDER BY inserted_at
      """)

    auth_settings =
      case auth_rows do
        [[mode, is_enabled, allow_password_fallback, sso_auto_provision]] ->
          %{
            count: 1,
            mode: mode,
            is_enabled: is_enabled,
            allow_password_fallback: allow_password_fallback,
            sso_auto_provision: sso_auto_provision
          }

        rows ->
          %{count: length(rows)}
      end

    IO.puts("BOOTSTRAP_RESULT:" <> Jason.encode!(%{
      migration_count: migration_count,
      baseline_count: baseline_count,
      platform_object_count: platform_object_count,
      logs_hypertable_present: logs_hypertable_present,
      logs_severity_rollup_present: logs_severity_rollup_present,
      logs_severity_rollup_columns: logs_severity_rollup_columns,
      auth_settings: auth_settings
    }))
    '''
  end

  defp subprocess_env(admin_url, database, subprocess_ca_file, extra_env \\ []) do
    uri = URI.parse(admin_url)
    # Same resolution as the parent's connection, and as ServiceRadar.Repo's. The subprocess
    # boots the real Repo, so handing it a mode the parent did not use would have it fail the
    # handshake against a fixture the parent just connected to.
    sslmode = sslmode(uri)
    tls_server_name = tls_server_name(uri)
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
        {"SERVICERADAR_TEST_DATABASE_SERVER_NAME", tls_server_name},
        {"SRQL_TEST_DATABASE_SERVER_NAME", tls_server_name},
        {"CNPG_TLS_SERVER_NAME", tls_server_name},
        # The CONTENT form, alongside the paths below. System.cmd merges `env:` with the
        # parent environment so this would be inherited anyway, but every other credential
        # here is passed explicitly and the child must not depend on implicit inheritance or
        # on a caller-owned path. Leaving the child's only CA implicit is how it can end up
        # with CNPG_SSL_MODE=verify-full and nothing to verify against.
        {"SERVICERADAR_TEST_DATABASE_CA_CERT", ca_pem()},
        {"SERVICERADAR_TEST_DATABASE_CA_CERT_FILE", subprocess_ca_file},
        {"SERVICERADAR_TEST_DATABASE_CERT", cert_file()},
        {"SERVICERADAR_TEST_DATABASE_KEY", key_file()},
        {"SRQL_TEST_DATABASE_CA_CERT", ca_pem()},
        {"SRQL_TEST_DATABASE_CA_CERT_FILE", subprocess_ca_file},
        {"SRQL_TEST_DATABASE_CERT", cert_file()},
        {"SRQL_TEST_DATABASE_KEY", key_file()},
        {"CNPG_CERT_FILE", cert_file()},
        {"CNPG_KEY_FILE", key_file()},
        {"CNPG_CA_FILE", subprocess_ca_file},
        {"PGSSLROOTCERT", subprocess_ca_file}
      ] ++ extra_env,
      fn {_key, value} -> value in [nil, ""] end
    )
  end

  # The guarded Bazel lifecycle transports the fixture CA as PEM content because paths on the
  # workflow runner are not portable action inputs. The bootstrap child is intentionally a
  # plain `elixir` process, however, and production StartupMigrations accepts its admin CA via
  # CNPG_CA_FILE. Materialize the public CA once inside this test's private process sandbox so
  # both contracts remain honest; setup_all removes the file even when the assertion fails.
  defp subprocess_ca_file do
    case ca_file() do
      path when is_binary(path) and path != "" ->
        {path, false}

      _ ->
        case ca_pem() do
          pem when is_binary(pem) and pem != "" ->
            path =
              Path.join(
                System.tmp_dir!(),
                "serviceradar-bootstrap-ca-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}.pem"
              )

            try do
              File.open!(path, [:write, :exclusive, :binary], fn file ->
                # Create an empty file first and restrict it before any certificate bytes are
                # written. If chmod or writing fails, the rescue below removes any residue.
                File.chmod!(path, 0o600)
                :ok = IO.binwrite(file, pem)
              end)
            rescue
              error ->
                _ = File.rm(path)
                reraise error, __STACKTRACE__
            end

            {path, true}

          _ ->
            {nil, false}
        end
    end
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

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: username(uri),
      password: password(uri),
      database: database_name(uri),
      ssl: ssl_opts(sslmode(uri), tls_server_name(uri))
    ]
  end

  defp tls_server_name(uri) do
    System.get_env("SERVICERADAR_TEST_DATABASE_SERVER_NAME") ||
      System.get_env("SRQL_TEST_DATABASE_SERVER_NAME") ||
      System.get_env("CNPG_TLS_SERVER_NAME") ||
      uri.host ||
      "localhost"
  end

  # Resolved exactly the way config/test.exs resolves it for ServiceRadar.Repo, which is what
  # every other database-backed test in this suite connects through.
  #
  # This used to read `query["sslmode"] || CNPG_SSL_MODE || "require"`, which differed from the
  # Repo in two ways: it ignored SERVICERADAR_TEST_DATABASE_SSLMODE and
  # SRQL_TEST_DATABASE_SSLMODE, and it defaulted to "require" where the Repo defaults to no
  # TLS at all. Against a plaintext fixture that made this one test demand TLS while every
  # other test connected happily, and the failure surfaced as
  #
  #   ** (DBConnection.ConnectionError) connection not available and request was dropped from
  #      queue after 4000ms
  #
  # which reads like pool exhaustion rather than a handshake that never completes.
  #
  # Checked-in Forgejo and BuildBuddy setup is unaffected: it normalizes both fixture DSNs and
  # CNPG_SSL_MODE to "verify-full" and supplies the certificate server name. This compatibility
  # fallback is only reached by an unnormalized local caller that sets no explicit mode.
  defp sslmode(%URI{} = uri) do
    from_url =
      uri.query
      |> Kernel.||("")
      |> URI.decode_query()
      |> Map.get("sslmode")

    mode =
      from_url ||
        System.get_env("SERVICERADAR_TEST_DATABASE_SSLMODE") ||
        System.get_env("SRQL_TEST_DATABASE_SSLMODE") ||
        System.get_env("CNPG_SSL_MODE")

    case mode do
      nil -> default_sslmode()
      value -> String.downcase(value)
    end
  end

  # Nothing named a mode. If a CA was supplied then TLS was intended, and defaulting to
  # "disable" here connects in plaintext to a fixture that refuses it:
  #
  #   FATAL 28000 no pg_hba.conf entry for host "...", user "srql_hydra", ..., no encryption
  #
  # which surfaces as `connection not available ... dropped from queue after 4000ms`, because
  # Postgrex retries the failed connect behind the scenes and the first query dies on the pool
  # queue rather than on the connect. Reproduced against a TLS-only local fixture.
  #
  # This mirrors config/test.exs, where the presence of a CA enables `:ssl` on its own. An
  # explicit sslmode still wins: the case above only reaches here when nothing set one.
  #
  # "require" rather than an inferred verifying mode also matches the Repo: with no mode named,
  # it turns TLS on without inventing a hostname contract. Canonical fixture callers explicitly
  # use verify-full and pass the service DNS name separately, including for NodePort addresses.
  defp default_sslmode do
    if present?(ca_pem()) or present?(ca_file()), do: "require", else: "disable"
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

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
    |> put_ca()
    |> maybe_put(:certfile, cert_file())
    |> maybe_put(:keyfile, key_file())
    |> maybe_put(:server_name_indication, host && to_charlist(host))
  end

  # `:cacerts` (the decoded certificate) wins over `:cacertfile` (a path), mirroring
  # config/test.exs. Never both -- :ssl rejects the combination.
  #
  # The content form survives process and Bazel sandbox boundaries without depending on a
  # caller-owned path. //:buildbuddy_setup_fixture_env exports the fixture CA as PEM CONTENT
  # in SRQL_TEST_DATABASE_CA_CERT; the child also receives a private materialized file for
  # consumers that require a path.
  #
  # Without this, a DSN carrying sslmode=verify-full produced `verify: :verify_peer` with NO
  # certificate to verify against. The handshake then never completes, Postgrex keeps retrying
  # behind the scenes, and the first query dies on the pool queue instead:
  #
  #   ** (DBConnection.ConnectionError) connection not available and request was dropped
  #      from queue after 4000ms
  #
  # which is exactly the misleading shape the sslmode/0 comment above warns about. The note
  # there that "CI is unaffected either way" was true only of the Forgejo tier, which runs
  # scripts/ci/configure-srql-fixture.sh and does export the file paths.
  defp put_ca(opts) do
    case ca_certs() do
      [_ | _] = certs -> Keyword.put(opts, :cacerts, certs)
      _ -> maybe_put(opts, :cacertfile, ca_file())
    end
  end

  defp ca_pem do
    System.get_env("SERVICERADAR_TEST_DATABASE_CA_CERT") ||
      System.get_env("SRQL_TEST_DATABASE_CA_CERT")
  end

  defp ca_certs do
    pem = ca_pem()

    if is_binary(pem) and String.trim(pem) != "" do
      pem
      |> :public_key.pem_decode()
      |> Enum.filter(&match?({:Certificate, _der, _cipher}, &1))
      |> Enum.map(fn {:Certificate, der, _cipher} -> der end)
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp create_database!(admin_opts, database) do
    with_admin_connection!(admin_opts, fn conn ->
      Postgrex.query!(conn, "CREATE DATABASE #{quote_ident(database)}", [],
        timeout: @admin_query_timeout
      )
    end)
  end

  # `bootstrap_app_role!/2` (`ServiceRadar.Cluster.StartupMigrations`) hands this database's
  # ownership to an ordinary, non-superuser application role before the baseline or any
  # migration runs (`ALTER DATABASE ... OWNER TO`). `age`/`postgis`/`vector` (and, in some
  # Postgres installs, `timescaledb` itself) genuinely require superuser to CREATE from
  # scratch -- confirmed by reproducing this directly: a fresh database owned by a plain
  # `CREATE ROLE ... LOGIN` role gets `permission denied to create extension "age"` (etc.) on
  # `CREATE EXTENSION`, even though `CREATE EXTENSION IF NOT EXISTS` on an ALREADY-installed
  # extension is a permission-free no-op for any role. Every other consumer of a scratch
  # database in this repo (`//rust/integration-db`'s `install_extensions`, and real deployments
  # via CNPG/Helm's extension-update job) pre-installs these as an admin/superuser before
  # anything runs as the unprivileged app role; this test's own `create_database!/2` never did,
  # so its ordinary-role baseline application could hit that same permission wall, or a
  # confusing downstream error far from the real cause once some object an extension created
  # (e.g. `_timescaledb_internal`) turns out not to be reachable by the app role that inherited
  # this database only after those objects already existed. Installing every required extension
  # here, as the same admin role `create_database!/2` already uses, and pre-creating (or
  # updating) the exact app role `ServiceRadar.Cluster.StartupMigrations.bootstrap_app_role!/2`
  # will use (`subprocess_env/4` pins it to a fixed name/password for this test) so ownership of
  # the schemas the extensions and later migrations live in is right from the start, matches
  # `//rust/integration-db`'s `install_extensions` instead of assuming a fresh database
  # inherited any of this from `template1`.
  @required_extensions ~w(pgcrypto pg_trgm citext timescaledb age postgis vector)
  @bootstrap_app_user "serviceradar_bootstrap_test"
  @bootstrap_app_password "serviceradar_bootstrap_test"

  defp install_required_extensions!(admin_opts, database) do
    ensure_app_role!(admin_opts)

    opts = Keyword.put(admin_opts, :database, database)

    with_admin_connection!(opts, fn conn ->
      for schema <- ["platform", "ag_catalog"] do
        Postgrex.query!(
          conn,
          "CREATE SCHEMA IF NOT EXISTS #{schema} AUTHORIZATION #{quote_ident(@bootstrap_app_user)}",
          [],
          timeout: @admin_query_timeout
        )
      end

      Enum.each(@required_extensions, fn extension ->
        target_schema = if extension == "age", do: "ag_catalog", else: "platform"

        Postgrex.query!(
          conn,
          "CREATE EXTENSION IF NOT EXISTS #{quote_ident(extension)} WITH SCHEMA #{target_schema}",
          [],
          timeout: @admin_query_timeout
        )
      end)

      # Mirrors //rust/integration-db's install_extensions: AGE keeps its catalogue in
      # ag_catalog and the application role reaches it as a non-superuser, so these grants are
      # what make graphs usable at all.
      for statement <- [
            "GRANT USAGE ON SCHEMA ag_catalog TO #{quote_ident(@bootstrap_app_user)}",
            "GRANT ALL ON ALL TABLES IN SCHEMA ag_catalog TO #{quote_ident(@bootstrap_app_user)}",
            "GRANT ALL ON ALL SEQUENCES IN SCHEMA ag_catalog TO #{quote_ident(@bootstrap_app_user)}",
            "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO #{quote_ident(@bootstrap_app_user)}"
          ] do
        Postgrex.query!(conn, statement, [], timeout: @admin_query_timeout)
      end
    end)
  end

  defp ensure_app_role!(admin_opts) do
    with_admin_connection!(admin_opts, fn conn ->
      case Postgrex.query(
             conn,
             "SELECT 1 FROM pg_roles WHERE rolname = $1",
             [@bootstrap_app_user],
             timeout: @admin_query_timeout
           ) do
        {:ok, %{num_rows: 0}} ->
          Postgrex.query!(
            conn,
            "CREATE ROLE #{quote_ident(@bootstrap_app_user)} LOGIN PASSWORD #{quote_literal(@bootstrap_app_password)}",
            [],
            timeout: @admin_query_timeout
          )

        {:ok, _} ->
          :ok
      end
    end)
  end

  defp quote_literal(value) do
    "'#{String.replace(value, "'", "''")}'"
  end

  defp drop_database!(admin_opts, database) do
    case drop_database(admin_opts, database) do
      :ok ->
        :ok

      {:error, reason} ->
        raise "failed to drop bootstrap scratch database #{database}: #{inspect(reason)}"
    end
  end

  defp drop_database(admin_opts, database) do
    Enum.reduce_while(1..5, {:error, :not_attempted}, fn attempt, _acc ->
      case drop_database_once(admin_opts, database) do
        :ok ->
          {:halt, :ok}

        {:error, reason} ->
          if attempt == 5 do
            {:halt, {:error, reason}}
          else
            Process.sleep(1_000 * attempt)
            {:cont, {:error, reason}}
          end
      end
    end)
  end

  defp drop_database_once(admin_opts, database) do
    with_admin_connection!(admin_opts, fn conn ->
      # Runs from on_exit. A loaded eight-shard fixture used to take the
      # whole shard down with `57014 query_canceled`.
      #
      # pg_terminate_backend/1 only REQUESTS termination. DROP DATABASE then
      # waits for remaining sessions, so a backend still dying -- or one that
      # reconnected in the gap -- blocked until the client cancelled.
      #
      # WITH (FORCE) folds terminate into the drop (PG13+; the fixture is
      # PG18). There are TWO timeouts: server statement_timeout and the
      # Postgrex/DBConnection client timeout (default 15s). The 15s client
      # cancel is what produced 57014 on ExUnit.OnExitHandler. Pass the
      # admin timeout on the connection AND each query.
      Postgrex.query!(conn, "SET statement_timeout = 0", [], timeout: @admin_query_timeout)

      Postgrex.query!(
        conn,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
        [database],
        timeout: @admin_query_timeout
      )

      Postgrex.query!(
        conn,
        "DROP DATABASE IF EXISTS #{quote_ident(database)} WITH (FORCE)",
        [],
        timeout: @admin_query_timeout
      )

      :ok
    end)
  rescue
    e ->
      {:error, e}
  end

  defp with_admin_connection!(opts, fun) do
    {:ok, conn} =
      opts
      |> Keyword.put(:timeout, @admin_query_timeout)
      |> Postgrex.start_link()

    try do
      fun.(conn)
    after
      GenServer.stop(conn, :normal, @admin_query_timeout)
    end
  end

  defp quote_ident(value) do
    ~s("#{String.replace(value, "\"", "\"\"")}")
  end
end
