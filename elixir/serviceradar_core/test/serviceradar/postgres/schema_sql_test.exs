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
end
