defmodule ServiceRadar.DB.TemplateGeneration do
  @moduledoc """
  Publishes a prepared, private schema generation after full Ecto replay.

  Rust owns allocation/recovery and the registry DDL. This builder never repairs a
  partial candidate. All coordination uses one session in postgres, including the
  final fencing update. Load this module with -r; loading it performs no I/O.
  """

  alias ServiceRadar.DB.FixtureConfig
  alias ServiceRadar.Repo

  @namespace 1_397_904_460
  @extensions ~w(age citext pg_trgm pgcrypto postgis timescaledb vector)
  @hex ~r/\A[0-9a-f]{64}\z/
  @manifest_path "../../build/schema_template/manifest.json"
  @policy_path "../../build/schema_template/policy.json"
  # Includes names passed through @tables and configured_positive_integer/2 in
  # retention migrations, not only literal arguments at System.get_env calls.
  @schema_overrides ~w(
    CNPG_SEARCH_PATH MTR_RETENTION_DAYS
    SERVICERADAR_MIGRATION_LOCK_TIMEOUT_MS SERVICERADAR_MIGRATION_CONCURRENT_INDEXES
    SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD_FILE
    SERVICERADAR_OTEL_TRACES_RETENTION_DAYS SERVICERADAR_OTEL_TRACES_CHUNK_INTERVAL_HOURS
    SERVICERADAR_LOGS_RETENTION_DAYS SERVICERADAR_LOGS_CHUNK_INTERVAL_HOURS
    SERVICERADAR_OCSF_NETWORK_ACTIVITY_RETENTION_DAYS
    SERVICERADAR_OCSF_NETWORK_ACTIVITY_CHUNK_INTERVAL_HOURS
    SERVICERADAR_OTEL_METRICS_RETENTION_DAYS
    SERVICERADAR_OTEL_METRIC_POINTS_RETENTION_DAYS
    SERVICERADAR_OTEL_METRIC_POINTS_CHUNK_INTERVAL_HOURS
    SERVICERADAR_OCSF_EVENTS_CHUNK_INTERVAL_HOURS
    SERVICERADAR_TIMESERIES_METRICS_CHUNK_INTERVAL_HOURS
  )

  def run! do
    run!(JSON.decode!(File.read!(@manifest_path)), JSON.decode!(File.read!(@policy_path)))
  end

  def run!(manifest, policy) do
    validate_manifest!(manifest)
    validate_environment!()
    validate_policy!(policy)
    timeout = policy["lock_timeout_seconds"] * 1_000
    config = normalize_repo_config!(Repo.config())

    if !(config[:database] == manifest["database"] and
           config[:migration_repo] in [nil, Repo] and is_nil(Process.whereis(Repo))) do
      raise "template builder requires a stopped Repo configured for the exact candidate"
    end

    opts = admin_options!(FixtureConfig.admin_url!("postgres"), config)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    watcher = start_disconnect_guard()

    try do
      case Postgrex.start_link(Keyword.put(opts, :connection_listeners, [watcher])) do
        {:ok, admin} ->
          try do
            generate!(admin, manifest, policy, timeout, opts)
          after
            stop_disconnect_guard(watcher)
            if Process.alive?(admin), do: GenServer.stop(admin, :normal, 5_000)
          end

        {:error, _} ->
          raise "template administrator connection failed"
      end
    after
      stop_disconnect_guard(watcher)
    end
  end

  @doc "Validates the producer's version-one identity without reading files or connecting."
  def validate_manifest!(
        %{
          "version" => 1,
          "digest" => digest,
          "database" => database,
          "inputs" => inputs,
          "migration_versions" => versions
        } = manifest
      ) do
    if !(Map.keys(manifest) --
           [
             "version",
             "digest",
             "database",
             "inputs",
             "migration_versions",
             "covered_migrations"
           ] == [] and valid_digest?(digest) and
           database == "sr_tpl_" <> binary_part(digest, 0, 48) and
           is_list(inputs) and inputs != [] and Enum.all?(inputs, &valid_input?/1) and
           is_list(versions) and versions != [] and
           Enum.all?(versions, &(is_integer(&1) and &1 > 0 and &1 <= 9_223_372_036_854_775_807))) do
      raise ArgumentError, "invalid schema template manifest"
    end

    paths = Enum.map(inputs, & &1["path"])

    if !(paths == Enum.sort(Enum.uniq(paths)) and versions == Enum.sort(Enum.uniq(versions))) do
      raise ArgumentError,
            "schema template paths and migration versions must be sorted and unique"
    end

    expected = input_digest(inputs, "serviceradar.schema-template.v1\0")

    if expected != digest,
      do: raise(ArgumentError, "schema template manifest digest mismatch")

    migrations = Enum.flat_map(inputs, &migration_input/1)

    if Enum.sort(Enum.map(migrations, &elem(&1, 0))) != versions,
      do: raise(ArgumentError, "schema template migration versions disagree with input paths")

    validate_covered!(manifest["covered_migrations"], migrations)
    manifest
  end

  def validate_manifest!(_), do: raise(ArgumentError, "invalid schema template manifest")

  @doc "Rejects ambient schema overrides without exposing their values."
  def validate_environment!(environment \\ System.get_env()) do
    if !(environment["MIX_ENV"] == "test" and
           environment["SERVICERADAR_MIGRATION_ONLY"] in [nil, "", "true"]) do
      raise ArgumentError,
            "template replay requires MIX_ENV=test and migration-only unset or true"
    end

    if Enum.any?(@schema_overrides, &(environment[&1] not in [nil, ""])) do
      raise ArgumentError, "template replay refuses ambient schema overrides"
    end

    :ok
  end

  @doc false
  def schema_override_names, do: @schema_overrides

  @doc false
  def validate_migration_role!([[false, false, true]]), do: :ok

  def validate_migration_role!(_),
    do: raise("template replay requires the application role without SUPERUSER or CREATEROLE")

  @doc "The signed second key of the generation advisory lock."
  def lock_key(digest) do
    if !valid_digest?(digest), do: raise(ArgumentError, "invalid schema template digest")
    <<key::signed-big-32, _::binary>> = Base.decode16!(digest, case: :lower)
    key
  end

  defp valid_digest?(value), do: is_binary(value) and Regex.match?(@hex, value)

  defp valid_input?(%{"path" => path, "sha256" => digest} = input) when is_binary(path) do
    map_size(input) == 2 and valid_digest?(digest) and
      Regex.match?(~r/\A[A-Za-z0-9_.\/-]+\z/, path) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp valid_input?(_), do: false

  defp input_digest(inputs, domain) do
    data = [
      domain,
      <<length(inputs)::unsigned-big-64>>,
      Enum.map(inputs, fn %{"path" => path, "sha256" => sha} ->
        [<<byte_size(path)::unsigned-big-64>>, path, Base.decode16!(sha, case: :lower)]
      end)
    ]

    :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
  end

  defp migration_input(
         %{"path" => "elixir/serviceradar_core/priv/repo/migrations/" <> name} = input
       ) do
    case Regex.run(~r/\A([0-9]+)_[a-zA-Z0-9_]+\.exs\z/, name) do
      [_, digits] -> [{String.to_integer(digits), input}]
      _ -> raise ArgumentError, "invalid schema template migration path"
    end
  end

  defp migration_input(_), do: []

  defp validate_covered!(%{"included_through" => through, "digest" => digest}, migrations)
       when is_integer(through) and through > 0 do
    inputs = for {version, input} <- migrations, version <= through, do: input

    if !(valid_digest?(digest) and
           digest ==
             input_digest(inputs, "serviceradar.schema-template.covered-migrations.v1\0")),
       do: raise(ArgumentError, "schema template covered migration digest mismatch")
  end

  defp validate_covered!(_, _),
    do: raise(ArgumentError, "invalid schema template covered migrations")

  @doc "Validates the same version-one bounds and fields as Rust Policy."
  def validate_policy!(policy) when is_map(policy) do
    fields =
      ~w(max_generations max_concurrent_builders max_total_bytes retention_seconds lease_seconds lock_timeout_seconds)

    if !(policy["version"] === 1 and policy["construction_mode"] == "full_replay" and
           Enum.sort(Map.keys(policy)) == Enum.sort(["version", "construction_mode" | fields]) and
           Enum.all?(fields, &valid_policy_bound?(policy[&1])) and
           policy["max_concurrent_builders"] <= policy["max_generations"]) do
      raise ArgumentError, "invalid schema template construction policy"
    end

    policy
  end

  def validate_policy!(_), do: raise(ArgumentError, "invalid schema template construction policy")

  defp valid_policy_bound?(value),
    do: is_integer(value) and value > 0 and value <= 2_147_483_647 * 1024

  @doc false
  # Replace parser errors and their argument-bearing stack frames: URLs contain secrets.
  def normalize_repo_config!(config) do
    case config[:url] do
      nil ->
        config

      url when is_binary(url) ->
        uri = URI.parse(url)
        pairs = (uri.query || "") |> URI.query_decoder() |> Enum.to_list()

        if !(uri.scheme in ["postgres", "postgresql"] and is_binary(uri.host) and
               uri.host != "" and is_binary(uri.path) and is_binary(uri.userinfo) and
               is_nil(uri.fragment) and Regex.match?(~r/\A\/[^\/]+\z/, uri.path) and
               Enum.all?(pairs, &(&1 in [{"sslmode", "verify-full"}, {"ssl", "true"}])) and
               length(pairs) == length(Enum.uniq_by(pairs, &elem(&1, 0)))) do
          raise ArgumentError, "invalid template Repo URL"
        end

        [user, password] = String.split(uri.userinfo, ":", parts: 2)

        Keyword.merge(config,
          hostname: uri.host,
          port: uri.port || 5432,
          database: uri.path |> String.trim_leading("/") |> URI.decode(),
          username: URI.decode(user),
          password: URI.decode(password)
        )
    end
  rescue
    # credo:disable-for-next-line Credo.Check.Warning.RaiseInsideRescue
    _ -> raise ArgumentError, "invalid template Repo connection configuration"
  end

  @doc false
  # Preserve the sanitized error boundary, not a parser stack containing a credential URL.
  def admin_options!(url, config) do
    # Do not use URL query options as Postgrex settings: they can override TLS,
    # database, or the dedicated pool. All errors deliberately omit the DSN.
    uri = URI.parse(url)
    ssl = config[:ssl]
    query = (uri.query || "") |> URI.query_decoder() |> Enum.to_list()

    if !(uri.scheme in ["postgres", "postgresql"] and uri.path == "/postgres" and
           is_binary(uri.host) and uri.host != "" and is_binary(uri.userinfo) and
           is_nil(uri.fragment) and
           Enum.all?(query, &(&1 in [{"sslmode", "verify-full"}, {"ssl", "true"}])) and
           length(query) == length(Enum.uniq_by(query, &elem(&1, 0))) and
           is_list(ssl) and Keyword.keyword?(ssl) and ssl[:verify] == :verify_peer and
           ssl[:server_name_indication] not in [nil, false, :disable, [], ""] and
           (ssl[:cacerts] not in [nil, []] or
              (is_binary(ssl[:cacertfile]) and ssl[:cacertfile] != "")) and
           uri.host == config[:hostname] and (uri.port || 5432) == (config[:port] || 5432)) do
      raise ArgumentError,
            "template admin connection requires the configured fixture endpoint and verified TLS"
    end

    case String.split(uri.userinfo, ":", parts: 2) do
      [user, password] when user != "" and password != "" ->
        [
          hostname: uri.host,
          port: uri.port || 5432,
          database: "postgres",
          username: URI.decode(user),
          password: URI.decode(password),
          ssl: ssl,
          pool_size: 1,
          backoff_type: :stop,
          max_restarts: 0,
          idle_interval: 1_000,
          show_sensitive_data_on_connection_error: false
        ]

      _ ->
        raise ArgumentError, "template admin connection requires typed credentials"
    end
  rescue
    # credo:disable-for-next-line Credo.Check.Warning.RaiseInsideRescue
    _ -> raise ArgumentError, "invalid template administrator connection configuration"
  end

  defp generate!(admin, manifest, policy, timeout, opts) do
    query!(admin, "SELECT set_config('lock_timeout', $1, false)", ["#{timeout}ms"])

    query!(
      admin,
      "SELECT pg_advisory_lock($1::integer, $2::integer)",
      [@namespace, lock_key(manifest["digest"])],
      timeout + 5_000
    )

    if query!(admin, "SELECT version FROM sr_template_registry.metadata WHERE singleton", []).rows !=
         [[1]],
       do: raise("unsupported schema template registry version")

    row =
      query!(
        admin,
        """
        SELECT manifest, database_name, builder_token, state, server_major, extensions
        FROM sr_template_registry.generations WHERE digest = $1
        """,
        [manifest["digest"]]
      )

    case row.rows do
      [[stored, database, token, state, major, extensions]] ->
        if !(JSON.decode!(stored) == manifest and database == manifest["database"] and
               is_integer(token) and token > 0),
           do: raise("template registry identity mismatch; run prepare_generation")

        [[actual_major]] =
          query!(admin, "SELECT current_setting('server_version_num')::integer / 10000", []).rows

        if actual_major != major, do: raise("template PostgreSQL major version mismatch")
        required = extension_versions!(extensions)

        available =
          query!(
            admin,
            "SELECT name, default_version FROM pg_available_extensions WHERE name = ANY($1::text[])",
            [@extensions]
          ).rows

        if Map.new(available, fn [name, version] -> {name, version} end) != required,
          do: raise("template fixture extension compatibility changed; run prepare_generation")

        case state do
          "ready" ->
            if query!(admin, "SELECT datallowconn FROM pg_database WHERE datname = $1", [
                 database
               ]).rows != [[false]],
               do: raise("ready template is missing or still allows connections")

            :ready

          "building" ->
            build!(admin, manifest, stored, token, extensions, policy, timeout, opts)

          _ ->
            raise "invalid template registry state"
        end

      _ ->
        raise "template generation is not prepared; run prepare_generation"
    end
  end

  defp build!(admin, manifest, stored, previous_token, extensions, policy, timeout, opts) do
    # A cancelled initializer can leave its server-side statement/backend alive
    # after losing the administrative session lock. Do not overlap that work.
    if query!(
         admin,
         """
         SELECT NOT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = $1)
         """,
         [manifest["database"]]
       ).rows != [[true]] do
      raise "template candidate still has active connections; wait and run prepare_generation"
    end

    params = [manifest["digest"], stored, manifest["database"], previous_token]

    result =
      query!(
        admin,
        """
        UPDATE sr_template_registry.generations
        SET builder_token = nextval('sr_template_registry.builder_tokens')
        WHERE digest = $1 AND manifest = $2 AND database_name = $3
          AND builder_token = $4 AND state = 'building'
        RETURNING builder_token
        """,
        params
      )

    token =
      case result do
        %{num_rows: 1, rows: [[token]]} -> token
        _ -> raise "template builder ownership changed"
      end

    result =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        validate_environment!()
        [[database]] = sql!(repo, "SELECT current_database()", []).rows

        if database != manifest["database"],
          do: raise("Repo connected to the wrong candidate")

        # The cold-tier export-role migration gates cluster-wide CREATE/ALTER
        # ROLE on these attributes. Never replay it with the administrator DSN.
        repo
        |> sql!(
          """
          SELECT rolsuper, rolcreaterole, current_user = session_user
          FROM pg_roles WHERE rolname = current_user
          """,
          []
        )
        |> Map.fetch!(:rows)
        |> validate_migration_role!()

        if ledger!(repo) != [],
          do: raise("partial template replay refused; run prepare_generation to rebuild")

        verify_extensions!(repo, extensions)

        Ecto.Migrator.run(repo, :up,
          all: true,
          log: false,
          log_migrations_sql: false,
          log_migrator_sql: false
        )

        if ledger!(repo) != manifest["migration_versions"],
          do: raise("template migration ledger mismatch")

        verify_extensions!(repo, extensions)
        :verified
      end)

    if !(match?({:ok, :verified, _}, result) and is_nil(Process.whereis(Repo))),
      do: raise("template migration failed or Repo did not stop")

    # The Timescale control function requires admin rights. Keep migration replay
    # on the application role; open this separate session only after Repo stops.
    # Connect before sealing the database, then stop its workers after sealing so
    # no new client can restart them. The ownership watcher still fences us.
    {:ok, candidate} = Postgrex.start_link(Keyword.put(opts, :database, manifest["database"]))

    try do
      if query!(candidate, "SELECT current_database()", []).rows != [[manifest["database"]]],
        do: raise("worker shutdown connected to wrong candidate")

      query!(
        admin,
        "ALTER DATABASE #{quote_ident(manifest["database"])} ALLOW_CONNECTIONS false",
        []
      )

      query!(candidate, "SELECT set_config('statement_timeout', $1, false)", ["#{timeout}ms"])

      candidate
      |> query!("SELECT _timescaledb_functions.stop_background_workers()", [], timeout)
      |> Map.fetch!(:rows)
      |> validate_worker_quiescence!()
    after
      if Process.alive?(candidate), do: GenServer.stop(candidate, :normal, 5_000)
    end

    drain_candidate_backends!(
      admin,
      manifest["database"],
      System.monotonic_time(:millisecond) + timeout
    )

    query!(
      admin,
      "SELECT pg_advisory_lock($1::integer, 0::integer)",
      [@namespace + 1],
      timeout + 5_000
    )

    [[within_budget]] =
      query!(
        admin,
        """
        SELECT COALESCE(sum(pg_database_size(d.oid)), 0) <= $1::bigint
        FROM sr_template_registry.generations g JOIN pg_database d ON d.datname = g.database_name
        """,
        [policy["max_total_bytes"]]
      ).rows

    if !within_budget,
      do: raise("template storage capacity exceeded; generation remains unpublished")

    # ALLOW_CONNECTIONS prevents new clients but does not drain existing clients
    # or extension workers. Check after the capacity-lock wait, immediately before
    # publication. Never terminate somebody else's work to make this check pass.
    admin
    |> query!(
      "SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
      [manifest["database"]]
    )
    |> Map.fetch!(:rows)
    |> validate_no_candidate_backends!()

    result =
      query!(
        admin,
        """
        UPDATE sr_template_registry.generations SET state = 'ready', last_used_at = clock_timestamp()
        WHERE digest = $1 AND manifest = $2 AND database_name = $3
          AND builder_token = $4 AND state = 'building'
        """,
        [manifest["digest"], stored, manifest["database"], token]
      )

    if result.num_rows != 1, do: raise("template publication rejected by ownership fence")
    :ready
  end

  @doc false
  def validate_worker_quiescence!([[true]]), do: :ok

  def validate_worker_quiescence!(_),
    do: raise("TimescaleDB worker shutdown was not acknowledged; generation remains unpublished")

  @doc false
  def validate_no_candidate_backends!([[0]]), do: :ok

  def validate_no_candidate_backends!(_) do
    raise "template publication refused: candidate backends remain or could not be verified"
  end

  defp drain_candidate_backends!(admin, database, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0,
      do: raise("template backend drain timed out; generation remains unpublished")

    rows =
      query!(
        admin,
        "SELECT count(*) FROM pg_stat_activity WHERE datname = $1",
        [database],
        min(remaining, 15_000)
      ).rows

    case backend_drain_step!(rows, deadline - System.monotonic_time(:millisecond)) do
      :drained ->
        :ok

      {:wait, milliseconds} ->
        Process.sleep(milliseconds)
        drain_candidate_backends!(admin, database, deadline)
    end
  end

  @doc false
  def backend_drain_step!([[0]], _remaining), do: :drained

  def backend_drain_step!([[count]], remaining) when is_integer(count) and count > 0 do
    if remaining > 0 do
      {:wait, min(250, remaining)}
    else
      raise "template backend drain timed out; generation remains unpublished"
    end
  end

  def backend_drain_step!(_, _remaining),
    do: raise("template backend count could not be verified")

  defp ledger!(repo) do
    schemas =
      sql!(
        repo,
        """
        SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'schema_migrations' AND c.relkind IN ('r', 'p') ORDER BY n.nspname
        """,
        []
      ).rows

    case schemas do
      [] ->
        []

      [[schema]] ->
        repo
        |> sql!(
          "SELECT version FROM #{quote_ident(schema)}.schema_migrations ORDER BY version",
          []
        )
        |> Map.fetch!(:rows)
        |> Enum.map(fn [version] -> version end)

      _ ->
        raise "ambiguous migration ledgers; run prepare_generation to rebuild"
    end
  end

  defp verify_extensions!(repo, expected) do
    actual = sql!(repo, "SELECT extname, extversion FROM pg_extension ORDER BY extname", []).rows
    installed = Map.new(actual, fn [name, version] -> {name, version} end)
    required = extension_versions!(expected)

    if !Enum.all?(required, fn {name, version} -> installed[name] == version end),
      do: raise("template extension versions mismatch")
  end

  defp extension_versions!(encoded) do
    versions = JSON.decode!(encoded)

    if !(is_map(versions) and Enum.sort(Map.keys(versions)) == @extensions and
           Enum.all?(versions, fn {_name, version} -> is_binary(version) and version != "" end)),
       do: raise("invalid template extension compatibility snapshot")

    versions
  end

  defp quote_ident(value), do: "\"" <> String.replace(value, "\"", "\"\"") <> "\""

  defp sql!(repo, sql, params),
    do: Ecto.Adapters.SQL.query!(repo, sql, params, log: false, timeout: :infinity)

  defp query!(admin, sql, params, timeout \\ 15_000) do
    case Postgrex.query(admin, sql, params, timeout: timeout) do
      {:ok, result} ->
        result

      {:error, _} ->
        raise "template registry operation failed; candidate remains unpublished unless already ready"
    end
  end

  @doc false
  def start_disconnect_guard do
    owner = self()
    spawn_link(fn -> watch_disconnect(owner, Process.monitor(owner)) end)
  end

  @doc false
  def stop_disconnect_guard(watcher) do
    ref = Process.monitor(watcher)
    send(watcher, {:stop, self()})

    receive do
      {:DOWN, ^ref, :process, ^watcher, :normal} -> :ok
      {:DOWN, ^ref, :process, ^watcher, :noproc} -> :ok
      {:DOWN, ^ref, :process, ^watcher, _} -> exit(:template_lock_lost)
    after
      5_000 -> exit(:template_guard_stop_timeout)
    end
  end

  defp watch_disconnect(owner, owner_ref) do
    receive do
      {:connected, connection} ->
        Process.monitor(connection)
        watch_disconnect(owner, owner_ref)

      {:disconnected, _connection} ->
        Process.exit(owner, :kill)

      {:DOWN, ^owner_ref, :process, ^owner, _} ->
        :ok

      {:DOWN, _ref, :process, _connection, _} ->
        Process.exit(owner, :kill)

      {:stop, ^owner} ->
        :ok
    end
  end
end
