defmodule ServiceRadar.Analytics.StarRocks.SchemaTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Schema

  @moduletag :db_free

  test "shipped migrations are ordered, uniquely versioned and free of comments" do
    migrations = Schema.migrations()
    versions = Enum.map(migrations, & &1.version)

    assert 1 in versions
    assert versions == Enum.sort(versions)
    assert versions == Enum.uniq(versions)

    for migration <- migrations do
      assert migration.statements != [], "#{migration.name} has no statements"
      assert migration.checksum =~ ~r/^[0-9a-f]{64}$/

      for statement <- migration.statements do
        # The Frontend rejects a comment that arrives as its own statement.
        refute statement =~ ~r/^\s*--/m
        refute String.ends_with?(statement, ";")
      end
    end
  end

  test "statements drops comment lines and splits on terminators" do
    sql = """
    -- Leading header the Frontend would reject.
    CREATE DATABASE IF NOT EXISTS serviceradar;

    CREATE TABLE IF NOT EXISTS serviceradar.t (
      -- a column note
      id INT
    );
    """

    assert Schema.statements(sql) == [
             "CREATE DATABASE IF NOT EXISTS serviceradar",
             "CREATE TABLE IF NOT EXISTS serviceradar.t (\n  id INT\n)"
           ]
  end

  test "retarget rewrites the database and replication factor" do
    assert Schema.retarget("CREATE DATABASE IF NOT EXISTS serviceradar", "lab", 1) ==
             "CREATE DATABASE IF NOT EXISTS lab"

    statement = ~s|CREATE TABLE serviceradar.logs (id INT) PROPERTIES ("replication_num" = "3")|

    assert Schema.retarget(statement, "lab", 1) ==
             ~s|CREATE TABLE lab.logs (id INT) PROPERTIES ("replication_num" = "1")|

    assert Schema.retarget(statement, "serviceradar", 3) == statement
  end

  test "retarget refuses a database name that is not an identifier" do
    assert_raise ArgumentError, fn -> Schema.retarget("SELECT 1", "lab; DROP DATABASE x", 1) end
  end

  test "add_column recognises plain and backticked columns only" do
    assert Schema.add_column("ALTER TABLE serviceradar.events ADD COLUMN status_id INT NULL") ==
             {:ok, {"events", "status_id"}}

    assert Schema.add_column(
             "ALTER TABLE serviceradar.flows ADD COLUMN `partition` VARCHAR(128) NULL"
           ) ==
             {:ok, {"flows", "partition"}}

    assert Schema.add_column("DROP MATERIALIZED VIEW IF EXISTS serviceradar.flows_hourly") ==
             :error
  end

  test "build rejects misnamed files and duplicate versions" do
    assert_raise ArgumentError, fn -> Schema.build([{"notes.sql", "SELECT 1;"}]) end

    assert_raise ArgumentError, fn ->
      Schema.build([{"0001_a.sql", "SELECT 1;"}, {"0001_b.sql", "SELECT 2;"}])
    end
  end
end
