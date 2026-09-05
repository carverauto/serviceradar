defmodule ServiceRadar.Postgres.SchemaSqlTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Postgres.SchemaSql

  test "splits simple statements" do
    assert ["SELECT 1", "SELECT 2"] = SchemaSql.split("SELECT 1; SELECT 2;")
  end

  test "keeps semicolons inside dollar-quoted function bodies" do
    sql = """
    CREATE FUNCTION platform.example() RETURNS void
    LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM ';';
    END;
    $$;
    SELECT 1;
    """

    assert [function, "SELECT 1"] = SchemaSql.split(sql)
    assert function =~ "PERFORM ';';"
    assert function =~ "END;"
  end

  test "keeps semicolons inside tagged dollar-quoted function bodies" do
    sql = """
    CREATE FUNCTION platform.example() RETURNS text
    LANGUAGE sql
    AS $function$ SELECT 'a;b' $function$;
    SELECT 1;
    """

    assert [function, "SELECT 1"] = SchemaSql.split(sql)
    assert function =~ "$function$ SELECT 'a;b' $function$"
  end

  test "ignores comments and pg_dump psql meta commands" do
    sql = """
    \\restrict abc
    -- comment with ;
    SELECT 1; /* comment; */ SELECT 'x; y';
    \\unrestrict abc
    """

    assert ["SELECT 1", "SELECT 'x; y'"] = SchemaSql.split(sql)
  end

  test "keeps semicolons inside quoted identifiers" do
    assert ["CREATE TABLE \"weird;name\" (id integer)"] =
             SchemaSql.split("CREATE TABLE \"weird;name\" (id integer);")
  end

  test "normalizes TimescaleDB function schema in loaded baseline SQL" do
    path = Path.join(System.tmp_dir!(), "schema_sql_#{System.unique_integer([:positive])}.sql")

    try do
      File.write!(path, """
      SELECT pg_catalog.set_config('search_path', '', false);

      CREATE VIEW platform.example AS
      SELECT platform.time_bucket('1 hour', observed_at) AS bucket
      FROM platform.samples;
      """)

      assert [
               "SELECT pg_catalog.set_config('search_path', 'platform, public, ag_catalog', false)",
               "CREATE VIEW platform.example AS\nSELECT time_bucket('1 hour', observed_at) AS bucket\nFROM platform.samples"
             ] =
               SchemaSql.load_statements(path, normalize_timescaledb_schema?: true)
    after
      File.rm(path)
    end
  end

  describe "extension privilege discipline" do
    # The baseline is produced by `pg_dump --schema-only` as the cluster SUPERUSER, and the role
    # that applies it is the ordinary application role. On 2026-09-05 that difference closed the
    # whole fleet: sr_core_template was empty, every run fell through to the baseline, and every
    # one died on `42501 must be owner of extension timescaledb`.

    test "drops COMMENT ON EXTENSION, which requires ownership and restates a stock description" do
      sql = """
      CREATE EXTENSION IF NOT EXISTS timescaledb WITH SCHEMA platform;
      COMMENT ON EXTENSION timescaledb IS 'Enables scalable inserts and complex queries for time-series data (Community Edition)';
      CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA platform;
      COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';
      CREATE TABLE platform.samples (id integer);
      COMMENT ON TABLE platform.samples IS 'kept: the applying role owns its own tables';
      """

      statements = load(sql)

      refute Enum.any?(statements, &(&1 =~ "COMMENT ON EXTENSION"))
      assert Enum.any?(statements, &(&1 =~ "COMMENT ON TABLE platform.samples"))
      assert Enum.any?(statements, &(&1 =~ "CREATE EXTENSION IF NOT EXISTS timescaledb"))
    end

    test "leaves a REQUIRED extension's CREATE unguarded so a missing one fails here" do
      # Swallowing this would move the failure 700 statements later, to
      # `type "vector" does not exist`, which names neither the extension nor the cause.
      statements = load("CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA platform;")

      assert ["CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA platform"] = statements
    end

    test "guards the optional extension exactly as its migration does" do
      statements = load("CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA platform;")

      assert [guarded] = statements
      assert guarded =~ "DO $serviceradar_optional_extension$"
      assert guarded =~ "CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA platform;"
      assert guarded =~ "WHEN insufficient_privilege THEN"
      assert guarded =~ "RAISE NOTICE 'Skipping pg_stat_statements extension creation"
    end

    test "is opt-in, so nothing else that loads schema SQL changes shape" do
      sql = """
      COMMENT ON EXTENSION timescaledb IS 'stock description';
      CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
      """

      assert [comment, create] = load(sql, apply_extension_privilege_discipline?: false)
      assert comment =~ "COMMENT ON EXTENSION timescaledb"
      assert create == "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
    end

    test "the committed baseline carries no statement the application role may not run" do
      # Against the REAL baseline, not a fixture of one: the incident was a mismatch between
      # what pg_dump emits and what the applying role may do, so a hand-written sample cannot
      # detect it recurring. If a future regeneration introduces another owner-only statement
      # -- an ALTER EXTENSION, an OWNER TO, a COMMENT ON EXTENSION that slipped past -- this
      # fails on the file rather than on the fixture at 03:00.
      statements =
        SchemaSql.load_statements(baseline_path(),
          normalize_timescaledb_schema?: true,
          apply_extension_privilege_discipline?: true
        )

      assert statements != []

      owner_only =
        Enum.filter(statements, fn statement ->
          Regex.match?(~r/\A\s*COMMENT\s+ON\s+EXTENSION\b/i, statement) or
            Regex.match?(~r/\A\s*ALTER\s+EXTENSION\b/i, statement) or
            Regex.match?(~r/\bOWNER\s+TO\b/i, statement)
        end)

      assert owner_only == [],
             "baseline holds statements only the extension/object owner may run: #{inspect(owner_only)}"
    end

    test "the baseline guards exactly the extensions the migrations guard" do
      # The baseline runs INSTEAD of the migration history, so it has to make the same
      # privilege judgments. The migrations are the authority and they are right here, so this
      # derives the answer rather than restating it: an extension a migration creates plainly is
      # one the application role is expected to be able to create, and must fail loudly if it
      # cannot; an extension a migration wraps in an `insufficient_privilege` handler is
      # optional, and the baseline must wrap it too.
      #
      # Today that is `pg_stat_statements` alone. The point of deriving it is the next one: an
      # untrusted extension added to a migration WITH a handler, and to the baseline WITHOUT
      # one, reproduces the 2026-09-05 outage for every deployment whose app role cannot
      # install it.
      guarded_by_migrations = migration_extensions(:guarded)
      plain_in_migrations = migration_extensions(:plain)

      assert guarded_by_migrations != [],
             "expected at least pg_stat_statements to be guarded in the migrations"

      statements =
        SchemaSql.load_statements(baseline_path(),
          normalize_timescaledb_schema?: true,
          apply_extension_privilege_discipline?: true
        )

      creates = Enum.filter(statements, &(&1 =~ ~r/CREATE\s+EXTENSION\b/i))
      refute creates == []

      for extension <- guarded_by_migrations,
          statement <- creates,
          statement =~ ~r/\b#{Regex.escape(extension)}\b/i do
        assert statement =~ "WHEN insufficient_privilege THEN",
               "#{extension} is guarded in the migrations and must be guarded in the baseline"
      end

      for extension <- plain_in_migrations,
          statement <- creates,
          statement =~ ~r/\b#{Regex.escape(extension)}\b/i do
        refute statement =~ "WHEN insufficient_privilege THEN",
               "#{extension} is required by the migrations; swallowing its failure here would " <>
                 "surface much later as a missing type or function"
      end
    end
  end

  test "normalizes extension-owned PostGIS and pgvector references in loaded baseline SQL" do
    path = Path.join(System.tmp_dir!(), "schema_sql_#{System.unique_integer([:positive])}.sql")

    try do
      File.write!(path, """
      CREATE TABLE platform.survey_samples (
        "position" platform.geometry(PointZ) GENERATED ALWAYS AS (
          platform.st_setsrid(platform.st_makepoint(x, y, z), 0)
        ) STORED,
        location platform.geography(Point,4326) GENERATED ALWAYS AS (
          platform.st_setsrid(platform.st_makepoint(longitude, latitude), 4326)::platform.geography
        ) STORED,
        rf_vector platform.vector(64)
      );

      CREATE INDEX survey_samples_rf_vector_idx
      ON platform.survey_samples USING hnsw (rf_vector platform.vector_cosine_ops);
      """)

      assert [table, index] =
               SchemaSql.load_statements(path, normalize_timescaledb_schema?: true)

      assert table =~ "\"position\" geometry(PointZ)"
      assert table =~ "st_setsrid(st_makepoint(x, y, z), 0)"
      assert table =~ "location geography(Point,4326)"
      assert table =~ "4326)::geography"
      assert table =~ "rf_vector vector(64)"
      assert index =~ "USING hnsw (rf_vector vector_cosine_ops)"
      refute table =~ "platform.geometry"
      refute table =~ "platform.geography"
      refute table =~ "platform.st_"
      refute table =~ "platform.vector"
      refute index =~ "platform.vector_cosine_ops"
    after
      File.rm(path)
    end
  end

  # Same accessor SchemaBootstrap uses, so the test reads the file the runtime would -- a
  # __DIR__-relative path would resolve in the source tree and not in the staged one.
  defp baseline_path do
    Application.app_dir(:serviceradar_core, "priv/repo/baseline/platform_schema.sql")
  end

  # Every extension the migration history creates, split by whether that migration tolerates
  # `insufficient_privilege`. Read from the migrations themselves so this cannot drift from
  # them, which is the whole reason the assertion above is worth having.
  defp migration_extensions(kind) do
    :serviceradar_core
    |> Application.app_dir("priv/repo/migrations")
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      source = File.read!(file)
      guarded? = source =~ "insufficient_privilege"

      ~r/CREATE\s+EXTENSION\s+IF\s+NOT\s+EXISTS\s+\\?"?([a-zA-Z0-9_-]+)/
      |> Regex.scan(source, capture: :all_but_first)
      |> Enum.map(fn [name] -> {name, guarded?} end)
    end)
    |> Enum.group_by(fn {_name, guarded?} -> guarded? end, fn {name, _} -> name end)
    |> Map.get(kind == :guarded, [])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp load(sql, opts \\ [apply_extension_privilege_discipline?: true]) do
    path = Path.join(System.tmp_dir!(), "schema_sql_#{System.unique_integer([:positive])}.sql")

    try do
      File.write!(path, sql)
      SchemaSql.load_statements(path, opts)
    after
      File.rm(path)
    end
  end
end
