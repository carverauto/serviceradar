defmodule ServiceRadar.Analytics.StarRocks.SchemaMigratorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.Analytics.StarRocks.SchemaMigrator

  @moduletag :db_free

  @migrations Schema.build([
                {"0001_tables.sql",
                 ~s|CREATE TABLE IF NOT EXISTS serviceradar.flows (id INT) PROPERTIES ("replication_num" = "3");|},
                {"0002_pid.sql", "ALTER TABLE serviceradar.flows ADD COLUMN pid INT NULL;"},
                {"0003_comm.sql",
                 "ALTER TABLE serviceradar.flows ADD COLUMN comm VARCHAR(256) NULL;"}
              ])

  # A warehouse reduced to what the migrator asks of one: live nodes, a ledger,
  # a column catalog and a log of the DDL it was sent.
  defp start_warehouse(overrides \\ %{}) do
    initial =
      Map.merge(
        %{
          backends: 3,
          compute_nodes: 0,
          ledger: [],
          columns: MapSet.new(),
          ddl: [],
          fail_on: nil
        },
        overrides
      )

    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp query_fun(agent) do
    fn sql -> Agent.get_and_update(agent, &answer(&1, sql)) end
  end

  defp result(columns, rows), do: {:ok, %{columns: columns, rows: rows}}

  defp answer(state, "SHOW BACKENDS"), do: {nodes(state.backends), state}
  defp answer(state, "SHOW COMPUTE NODES"), do: {nodes(state.compute_nodes), state}

  defp answer(state, "SELECT version FROM " <> _) do
    {result(["version"], Enum.map(state.ledger, &[&1])), state}
  end

  defp answer(state, "SELECT 1 FROM information_schema.columns" <> _ = sql) do
    [_, column] = Regex.run(~r/column_name = '([a-z_]+)'/, sql)
    rows = if MapSet.member?(state.columns, column), do: [[1]], else: []
    {result(["1"], rows), state}
  end

  # No telemetry tables here, so PartitionRebuild finds nothing to rebuild;
  # partition_rebuild_test.exs covers a warehouse that needs one.
  defp answer(%{fail_on: fail_on} = state, "SELECT TABLE_NAME, PARTITION_KEY" <> _ = sql) do
    if fail_on && sql =~ fail_on,
      do: {{:error, {:starrocks_mysql, "boom"}}, state},
      else: {result(["TABLE_NAME", "PARTITION_KEY"], []), state}
  end

  defp answer(state, "SHOW ALTER TABLE COLUMN" <> _),
    do: {result(["State"], [["FINISHED"]]), state}

  defp answer(state, "INSERT INTO " <> _ = sql) do
    [_, version] = Regex.run(~r/VALUES \((\d+),/, sql)
    {result([], []), %{state | ledger: state.ledger ++ [String.to_integer(version)]}}
  end

  defp answer(state, sql) do
    cond do
      state.fail_on && sql =~ state.fail_on ->
        {{:error, {:starrocks_mysql, "boom"}}, state}

      match = Regex.run(~r/ADD COLUMN `?([a-z_]+)`?/, sql) ->
        [_, column] = match

        {result([], []),
         %{state | columns: MapSet.put(state.columns, column), ddl: state.ddl ++ [sql]}}

      true ->
        {result([], []), %{state | ddl: state.ddl ++ [sql]}}
    end
  end

  defp nodes(count), do: result(["BackendId", "Alive"], List.duplicate([1, "true"], count))

  defp migrate(agent, opts \\ []) do
    [
      query: query_fun(agent),
      with_lock: fn fun -> fun.(fn -> :ok end) end,
      migrations: @migrations,
      database: "serviceradar",
      sleep: fn _ms -> :ok end
    ]
    |> Keyword.merge(opts)
    |> SchemaMigrator.migrate()
  end

  defp state(agent), do: Agent.get(agent, & &1)

  test "a fresh warehouse gets every migration in order, then nothing on the next start" do
    agent = start_warehouse()

    assert migrate(agent) == {:ok, [1, 2, 3]}
    assert state(agent).ledger == [1, 2, 3]

    [create_db, create_ledger, create_table, add_pid, add_comm] = state(agent).ddl
    assert create_db == "CREATE DATABASE IF NOT EXISTS serviceradar"
    assert create_ledger =~ "serviceradar.schema_migrations"
    assert create_table =~ "serviceradar.flows"
    assert add_pid =~ "ADD COLUMN pid"
    assert add_comm =~ "ADD COLUMN comm"

    ddl_before = state(agent).ddl
    assert migrate(agent) == {:ok, []}
    # Only the idempotent ledger bootstrap is repeated.
    assert length(state(agent).ddl) == length(ddl_before) + 2
    refute Enum.any?(Enum.drop(state(agent).ddl, length(ddl_before)), &(&1 =~ "flows"))
  end

  test "a warehouse that predates the ledger is adopted without re-adding its columns" do
    agent = start_warehouse(%{columns: MapSet.new(["pid"])})

    assert migrate(agent) == {:ok, [1, 2, 3]}

    refute Enum.any?(state(agent).ddl, &(&1 =~ "ADD COLUMN pid"))
    assert Enum.any?(state(agent).ddl, &(&1 =~ "ADD COLUMN comm"))
    assert state(agent).ledger == [1, 2, 3]
  end

  test "only versions missing from the ledger are applied" do
    agent = start_warehouse(%{ledger: [1, 2], columns: MapSet.new(["pid"])})

    assert migrate(agent) == {:ok, [3]}
    assert state(agent).ledger == [1, 2, 3]
  end

  test "a failed migration is not recorded, stops the run, and is retried next time" do
    agent = start_warehouse(%{fail_on: ~r/ADD COLUMN comm/})

    assert {:error, {3, {:starrocks_mysql, "boom"}}} = migrate(agent)
    assert state(agent).ledger == [1, 2]

    Agent.update(agent, &%{&1 | fail_on: nil})
    assert migrate(agent) == {:ok, [3]}
  end

  test "a runner that has lost the lock stops before its next statement and records nothing more" do
    agent = start_warehouse()
    {:ok, checks} = Agent.start_link(fn -> 0 end)

    # Holds for the first migration's statement, gone by the second's.
    still_locked = fn ->
      if Agent.get_and_update(checks, &{&1, &1 + 1}) >= 1, do: raise("lock lost"), else: :ok
    end

    assert {:error, %RuntimeError{message: "lock lost"}} =
             migrate(agent, with_lock: fn fun -> fun.(still_locked) end)

    assert state(agent).ledger == [1]
    refute Enum.any?(state(agent).ddl, &(&1 =~ "ADD COLUMN"))
  end

  test "replication follows the live backends; shared-data keeps the pinned factor" do
    single = start_warehouse(%{backends: 1})
    assert {:ok, _} = migrate(single)

    assert Enum.any?(
             state(single).ddl,
             &(&1 =~ ~s|flows (id INT) PROPERTIES ("replication_num" = "1")|)
           )

    shared_data = start_warehouse(%{backends: 0, compute_nodes: 2})
    assert {:ok, _} = migrate(shared_data)
    assert Enum.any?(state(shared_data).ddl, &(&1 =~ ~s|"replication_num" = "3"|))
  end

  test "nothing is attempted until a node is alive" do
    agent = start_warehouse(%{backends: 0, compute_nodes: 0})

    assert migrate(agent) == {:error, :no_live_starrocks_node}
    assert state(agent).ddl == []
  end

  test "the database is retargeted and an unsafe name is refused" do
    agent = start_warehouse()

    assert {:ok, [1, 2, 3]} = migrate(agent, database: "lab")
    assert Enum.all?(state(agent).ddl, &(not String.contains?(&1, "serviceradar.")))
    assert Enum.any?(state(agent).ddl, &(&1 =~ "lab.flows"))

    assert migrate(agent, database: "lab; DROP") == {:error, {:invalid_database, "lab; DROP"}}
  end

  test "run gives up after its attempts without crashing the supervisor" do
    agent = start_warehouse(%{backends: 0})

    assert SchemaMigrator.run(
             query: query_fun(agent),
             with_lock: fn fun -> fun.(fn -> :ok end) end,
             migrations: @migrations,
             database: "serviceradar",
             attempts: 2,
             sleep: fn _ms -> :ok end
           ) == :ok
  end

  test "quick migrations are not held behind the rebuild; only what needs partitioned tables waits" do
    migrations =
      Schema.build([
        {"0001_tables.sql", "CREATE TABLE IF NOT EXISTS serviceradar.flows (id INT);"},
        {"0002_pid.sql", "ALTER TABLE serviceradar.flows ADD COLUMN pid INT NULL;"},
        {"0003_rollup.sql",
         "CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.flows_hourly PARTITION BY day AS SELECT 1;"},
        {"0004_comm.sql", "ALTER TABLE serviceradar.flows ADD COLUMN comm VARCHAR(256) NULL;"}
      ])

    assert Enum.map(migrations, &Schema.needs_partitioned_tables?/1) == [
             false,
             false,
             true,
             false
           ]

    # The rebuild cannot run, so everything from 0003 on waits -- in order, 0004 included.
    agent = start_warehouse(%{fail_on: ~r/tables_config/})
    assert {:error, {:starrocks_mysql, "boom"}} = migrate(agent, migrations: migrations)
    assert state(agent).ledger == [1, 2]

    Agent.update(agent, &%{&1 | fail_on: nil})
    assert migrate(agent, migrations: migrations) == {:ok, [3, 4]}
  end

  test "the shipped schema marks exactly the day-partitioned rollups as needing partitioned tables" do
    waiting =
      Schema.migrations()
      |> Enum.filter(&Schema.needs_partitioned_tables?/1)
      |> Enum.map(& &1.version)

    assert waiting == [17]
  end
end
