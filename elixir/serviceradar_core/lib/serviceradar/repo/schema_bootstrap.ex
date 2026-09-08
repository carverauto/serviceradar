defmodule ServiceRadar.Repo.SchemaBootstrap do
  @moduledoc """
  Decides how to bring a database up to date, and applies the schema baseline.

  A proven-empty database is created from `priv/repo/baseline/platform_schema.sql` and the
  migrations that baseline contains are recorded as applied, rather than replayed. A database
  with coherent migration history runs only what is pending. A database holding platform objects
  with no migration history is refused.

  This module exists so that decision has exactly one implementation. It previously lived inside
  `ServiceRadar.Cluster.StartupMigrations` and was therefore reachable only from service
  startup, so the paths developers and CI actually run -- `mix ecto.migrate` and the Bazel
  fixture template target -- replayed the whole migration history instead. Every entry point now
  calls the functions here.

  The repository is an argument rather than a compile-time constant: nothing in bootstrap
  classification is specific to cluster startup, and taking the repo makes the module testable
  and reusable from Mix tasks.
  """

  require Logger

  @baseline_dir "priv/repo/baseline"
  @baseline_metadata_file "metadata.json"
  @default_search_path "platform, public, ag_catalog"

  @type state :: :empty | :migrated | {:ambiguous, map()}

  @doc """
  Classify a database as `:empty`, `:migrated`, or `{:ambiguous, details}`.
  """
  @spec classify(module()) :: state()
  def classify(repo) do
    classify_state(migration_ledger_versions(repo), platform_owned_object_count(repo))
  end

  @doc """
  The pure classification, so both directions are testable without a database.

  Migration history wins over object count: a database that has recorded any migration is an
  upgrade, however few platform objects it happens to hold. Only a database with no history AND
  no platform objects is a fresh install. History-less platform objects are refused rather than
  guessed at, because baselining over them would overwrite a real schema.
  """
  @spec classify_state([integer()], non_neg_integer()) :: state()
  def classify_state(migration_versions, platform_object_count)
      when is_list(migration_versions) and is_integer(platform_object_count) do
    versions = migration_versions |> Enum.uniq() |> Enum.sort()

    cond do
      versions != [] ->
        :migrated

      platform_object_count == 0 ->
        :empty

      true ->
        {:ambiguous,
         %{platform_object_count: platform_object_count, migration_versions: versions}}
    end
  end

  @doc """
  Apply the committed schema baseline and record the migrations it contains as applied.

  Only call this for a database `classify/1` returned `:empty` for.
  """
  @spec apply_baseline!(module(), Path.t()) :: :ok
  def apply_baseline!(repo, migrations_path) do
    metadata = baseline_metadata!()
    schema_file = baseline_schema_file!(metadata)
    verify_baseline_checksum!(schema_file, metadata)

    run_schema_file!(repo, schema_file)
    mark_baseline_migrations_applied!(repo, migrations_path, metadata)
    record_schema_baseline!(repo, metadata)
    :ok
  end

  @doc """
  The migration ledger table Ecto's migrator actually reads and writes.

  Ecto names its ledger from the repo's `:migration_source` (defaulting to
  `"schema_migrations"`) and resolves it in the `platform` schema here, so the baseline must
  record the migrations it contains under exactly that name. Recording them anywhere else --
  notably a hardcoded `platform.schema_migrations` -- leaves Ecto blind to them and the next
  `Ecto.Migrator.run/3` replays the whole baseline from scratch (issue #321).
  """
  @spec migration_ledger_table(module()) :: String.t()
  def migration_ledger_table(repo) do
    source = repo.config()[:migration_source] || "schema_migrations"
    "platform.#{source}"
  end

  @doc """
  Versions recorded in any of the ledgers this deployment may have used.

  Three locations are read because a database can legitimately hold more than one: the ledger's
  schema follows `search_path`, and its name follows the repo's `:migration_source`. Writers
  must use `migration_ledger_table/1`; this union exists only so classification recognises
  history however it was recorded.
  """
  @spec migration_ledger_versions(module()) :: [integer()]
  def migration_ledger_versions(repo) do
    ["platform.schema_migrations", "platform.ash_schema_migrations", "public.schema_migrations"]
    |> Enum.flat_map(&migration_versions_from_table(repo, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Count of platform objects this application owns, excluding bookkeeping and extension-owned
  relations.
  """
  @spec platform_owned_object_count(module()) :: non_neg_integer()
  def platform_owned_object_count(repo) do
    if schema_exists?(repo, "platform") do
      %{rows: [[count]]} =
        repo.query!("""
        SELECT count(*)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_depend d
          ON d.classid = 'pg_class'::regclass
         AND d.objid = c.oid
         AND d.deptype = 'e'
        WHERE n.nspname = 'platform'
        AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
        AND c.relname NOT IN (
          'schema_migrations',
          'ash_schema_migrations',
          'serviceradar_schema_baselines'
        )
        AND d.objid IS NULL
        """)

      count
    else
      0
    end
  end

  @doc """
  The migration version a migration filename encodes.
  """
  @spec migration_version_from_file(Path.t()) :: integer()
  def migration_version_from_file(path) do
    path
    |> Path.basename()
    |> String.split("_", parts: 2)
    |> hd()
    |> String.to_integer()
  end

  @doc """
  The baseline's metadata, as committed alongside the schema file.
  """
  @spec baseline_metadata!() :: map()
  def baseline_metadata! do
    path = baseline_path(@baseline_metadata_file)

    with {:ok, body} <- File.read(path),
         {:ok, metadata} <- Jason.decode(body) do
      metadata
    else
      {:error, reason} ->
        raise RuntimeError, "failed to read schema baseline metadata #{path}: #{inspect(reason)}"
    end
  end

  # -- internals ------------------------------------------------------------------------------

  defp migration_versions_from_table(repo, table) do
    if table_exists?(repo, table) do
      %{rows: rows} = repo.query!("SELECT version FROM #{table}")
      Enum.map(rows, fn [version] -> version end)
    else
      []
    end
  end

  defp table_exists?(repo, qualified_table) do
    case repo.query!("SELECT to_regclass($1)", [qualified_table]) do
      %{rows: [[nil]]} -> false
      %{rows: [[_]]} -> true
    end
  end

  defp schema_exists?(repo, schema_name) do
    case repo.query!("SELECT 1 FROM pg_namespace WHERE nspname = $1", [schema_name]) do
      %{rows: []} -> false
      _ -> true
    end
  end

  defp baseline_schema_file!(%{"schema_file" => schema_file}) do
    path = baseline_path(schema_file)

    if File.regular?(path) do
      path
    else
      raise RuntimeError, "schema baseline file not found: #{path}"
    end
  end

  defp baseline_schema_file!(_metadata) do
    raise RuntimeError, "schema baseline metadata missing schema_file"
  end

  defp verify_baseline_checksum!(schema_file, %{"schema_sha256" => expected}) do
    actual =
      schema_file
      |> File.stream!(2048, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual != expected do
      raise RuntimeError,
            "schema baseline checksum mismatch for #{schema_file}: expected #{expected}, got #{actual}"
    end
  end

  defp verify_baseline_checksum!(_schema_file, _metadata) do
    raise RuntimeError, "schema baseline metadata missing schema_sha256"
  end

  defp baseline_path(file) do
    Application.app_dir(:serviceradar_core, Path.join(@baseline_dir, file))
  end

  defp run_schema_file!(repo, schema_file) do
    statements =
      ServiceRadar.Postgres.SchemaSql.load_statements(schema_file,
        normalize_timescaledb_schema?: true,
        timescaledb_search_path: search_path(),
        # The baseline is a superuser's dump; the role applying it here is the ordinary
        # application role, which does not own the extensions underneath the schema. See
        # SchemaSql for what that reshapes and why the migrations already worked this way.
        apply_extension_privilege_discipline?: true
      )

    Logger.info(
      "[SchemaBootstrap] Applying schema baseline from #{schema_file} (#{length(statements)} statements)"
    )

    repo.transaction(
      fn ->
        Enum.each(statements, fn statement ->
          repo.query!(statement, [], timeout: :infinity)
        end)

        seed_required_baseline_data!(repo)
      end,
      timeout: :infinity
    )
  end

  # The supported baseline generator deliberately uses pg_dump --schema-only.
  # Keep required singleton data in the application-owned bootstrap transaction
  # so regenerating the baseline cannot silently discard it.
  defp seed_required_baseline_data!(repo) do
    repo.query!("""
    INSERT INTO platform.auth_settings (
      id,
      mode,
      is_enabled,
      allow_password_fallback,
      sso_auto_provision
    )
    VALUES (gen_random_uuid(), 'password_only', false, true, false)
    ON CONFLICT DO NOTHING
    """)
  end

  defp mark_baseline_migrations_applied!(repo, migrations_path, %{
         "included_through" => included_through
       }) do
    ledger = migration_ledger_table(repo)

    repo.query!("""
    CREATE TABLE IF NOT EXISTS #{ledger} (
      version bigint NOT NULL PRIMARY KEY,
      inserted_at timestamp(0) without time zone
    )
    """)

    versions =
      migrations_path
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.map(&migration_version_from_file/1)
      |> Enum.filter(&(&1 <= included_through))
      |> Enum.sort()

    Enum.each(versions, &mark_platform_migration_applied!(repo, ledger, &1))
  end

  defp mark_baseline_migrations_applied!(_repo, _migrations_path, _metadata) do
    raise RuntimeError, "schema baseline metadata missing included_through"
  end

  defp mark_platform_migration_applied!(repo, ledger, version) when is_integer(version) do
    repo.query!(
      """
      INSERT INTO #{ledger} (version, inserted_at)
      VALUES ($1, NOW())
      ON CONFLICT (version) DO NOTHING
      """,
      [version]
    )
  end

  defp record_schema_baseline!(repo, metadata) do
    repo.query!("""
      CREATE TABLE IF NOT EXISTS platform.serviceradar_schema_baselines (
      version integer NOT NULL PRIMARY KEY,
      included_through bigint NOT NULL,
      schema_sha256 text NOT NULL,
      applied_at timestamp(0) without time zone NOT NULL DEFAULT NOW()
    )
    """)

    repo.query!(
      """
      INSERT INTO platform.serviceradar_schema_baselines (version, included_through, schema_sha256)
      VALUES ($1, $2, $3)
      ON CONFLICT (version) DO UPDATE
      SET included_through = EXCLUDED.included_through,
          schema_sha256 = EXCLUDED.schema_sha256
      """,
      [metadata["version"], metadata["included_through"], metadata["schema_sha256"]]
    )
  end

  defp search_path do
    System.get_env("CNPG_SEARCH_PATH", @default_search_path)
  end
end
