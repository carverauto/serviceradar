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
end
