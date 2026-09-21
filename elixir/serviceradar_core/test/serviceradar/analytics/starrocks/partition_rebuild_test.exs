defmodule ServiceRadar.Analytics.StarRocks.PartitionRebuildTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.PartitionRebuild
  alias ServiceRadar.Analytics.StarRocks.Schema

  @moduletag :db_free

  @migrations Schema.build([
                {"0001_flows.sql",
                 """
                 CREATE TABLE IF NOT EXISTS serviceradar.flows (
                   id VARCHAR(64) NOT NULL,
                   `time` DATETIME NOT NULL,
                   bytes BIGINT,
                   app VARCHAR(64)
                 )
                 PRIMARY KEY (id, `time`)
                 PARTITION BY date_trunc('day', `time`)
                 DISTRIBUTED BY HASH(id) BUCKETS 16
                 PROPERTIES ("replication_num" = "3");
                 """},
                {"0002_rollup.sql",
                 """
                 CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.flows_hourly
                 REFRESH ASYNC AS SELECT date_trunc('hour', `time`) AS bucket FROM serviceradar.flows;
                 """},
                {"0003_rollup_by_day.sql",
                 """
                 DROP MATERIALIZED VIEW IF EXISTS serviceradar.flows_hourly;
                 CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.flows_hourly
                 PARTITION BY day REFRESH ASYNC AS SELECT date_trunc('day', `time`) AS day FROM serviceradar.flows;
                 """}
              ])

  # A warehouse reduced to what the rebuild asks of one: which tables exist and
  # whether they are partitioned, their columns, and a log of what it was sent.
  # SWAP and DROP act on the layout, so a second run sees what the first left.
  defp start_warehouse(layout, columns) do
    {:ok, agent} =
      Agent.start_link(fn -> %{layout: layout, columns: columns, sent: [], fail_on: nil} end)

    agent
  end

  defp run(agent, overrides \\ %{}) do
    %{
      query: fn sql -> Agent.get_and_update(agent, &answer(&1, sql)) end,
      database: "warehouse",
      replication_num: 1,
      migrations: @migrations,
      sleep: fn ms -> Agent.update(agent, &%{&1 | sent: &1.sent ++ ["sleep #{ms}"]}) end,
      retention_days: [{"flows", 90}]
    }
    |> Map.merge(overrides)
    |> PartitionRebuild.run()
  end

  defp sent(agent), do: Agent.get(agent, & &1.sent)
  defp layout(agent), do: Agent.get(agent, & &1.layout)

  defp ok(rows \\ []), do: {:ok, %{columns: [], rows: rows}}

  defp answer(state, "SELECT TABLE_NAME, PARTITION_KEY" <> _) do
    rows =
      Enum.map(state.layout, fn {table, kind} ->
        [table, if(kind == :partitioned, do: "`time`", else: "")]
      end)

    {ok(rows), state}
  end

  defp answer(state, "SELECT COLUMN_NAME" <> _ = sql) do
    [_, table] = Regex.run(~r/table_name = '(\w+)'/, sql)
    {ok(Enum.map(Map.get(state.columns, table, []), &[&1])), state}
  end

  defp answer(%{fail_on: pattern} = state, sql) when is_binary(pattern) do
    if String.contains?(sql, pattern),
      do: {{:error, {:starrocks_mysql, "boom"}}, log(state, sql)},
      else: apply_ddl(log(state, sql), sql)
  end

  defp answer(state, sql), do: apply_ddl(log(state, sql), sql)

  defp log(state, sql),
    do: %{state | sent: state.sent ++ [sql |> String.split("\n") |> hd() |> String.trim()]}

  defp apply_ddl(state, "CREATE TABLE IF NOT EXISTS warehouse.flows__rebuild" <> _) do
    {ok(),
     %{
       state
       | layout: Map.put(state.layout, "flows__rebuild", :partitioned),
         columns: Map.put(state.columns, "flows__rebuild", ["id", "time", "bytes", "app"])
     }}
  end

  defp apply_ddl(state, "ALTER TABLE warehouse.flows SWAP WITH flows__rebuild") do
    swap = fn map ->
      Map.merge(map, %{"flows" => map["flows__rebuild"], "flows__rebuild" => map["flows"]})
    end

    {ok(), %{state | layout: swap.(state.layout), columns: swap.(state.columns)}}
  end

  defp apply_ddl(state, "DROP TABLE IF EXISTS warehouse.flows__rebuild FORCE") do
    {ok(), %{state | layout: Map.delete(state.layout, "flows__rebuild")}}
  end

  defp apply_ddl(state, _sql), do: {ok(), state}

  test "a fresh warehouse, and one already partitioned, are left entirely alone" do
    fresh = start_warehouse(%{}, %{})
    assert run(fresh) == :ok
    assert sent(fresh) == []

    current = start_warehouse(%{"flows" => :partitioned}, %{})
    assert run(current) == :ok
    assert sent(current) == []
  end

  test "an unpartitioned table is copied, swapped, caught up and its rollup restored, in that order" do
    # The old table predates `app`, so only the columns both sides have are copied.
    agent = start_warehouse(%{"flows" => :unpartitioned}, %{"flows" => ["id", "time", "bytes"]})

    assert run(agent) == :ok
    assert layout(agent) == %{"flows" => :partitioned}

    assert [
             "DROP MATERIALIZED VIEW IF EXISTS warehouse.flows_hourly",
             "DROP TABLE IF EXISTS warehouse.flows__rebuild FORCE",
             "CREATE TABLE IF NOT EXISTS warehouse.flows__rebuild (",
             "INSERT INTO warehouse.flows__rebuild (`id`, `time`, `bytes`) SELECT `id`, `time`, `bytes` " <>
               copy,
             "ALTER TABLE warehouse.flows SWAP WITH flows__rebuild",
             "INSERT INTO warehouse.flows (`id`, `time`, `bytes`) SELECT o.`id`, o.`time`, o.`bytes` " <>
               catch_up,
             "sleep 5000",
             "INSERT INTO warehouse.flows (" <> _second_pass,
             "CREATE MATERIALIZED VIEW IF NOT EXISTS warehouse.flows_hourly",
             "DROP TABLE IF EXISTS warehouse.flows__rebuild FORCE"
           ] = sent(agent)

    # Bounded to retention on both sides, so a row dated year 0 or 2099 never becomes a partition.
    assert copy =~
             "FROM warehouse.flows WHERE `time` >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 90 DAY)"

    assert copy =~ "`time` < DATE_ADD(UTC_TIMESTAMP(), INTERVAL 1 DAY)"

    # Only rows the new table lacks, matched on the NEW primary key.
    assert catch_up =~ "FROM warehouse.flows__rebuild o LEFT ANTI JOIN warehouse.flows n"
    assert catch_up =~ "ON o.`id` = n.`id` AND o.`time` = n.`time`"
    assert catch_up =~ "o.`time` >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 90 DAY)"

    # Nothing left to do.
    Agent.update(agent, &%{&1 | sent: []})
    assert run(agent) == :ok
    assert sent(agent) == []
  end

  test "the rollup is restored from the newest shipped definition, retargeted" do
    agent = start_warehouse(%{"flows" => :unpartitioned}, %{"flows" => ["id", "time"]})
    parent = self()

    query = fn sql ->
      if sql =~ "CREATE MATERIALIZED VIEW", do: send(parent, {:rollup, sql})
      Agent.get_and_update(agent, &answer(&1, sql))
    end

    assert run(agent, %{query: query}) == :ok
    assert_received {:rollup, sql}
    assert sql =~ "PARTITION BY day"
    assert sql =~ "FROM warehouse.flows"
    refute sql =~ "serviceradar."
  end

  test "a copy that fails leaves the live table untouched, and the next run starts the copy again" do
    agent = start_warehouse(%{"flows" => :unpartitioned}, %{"flows" => ["id", "time"]})
    Agent.update(agent, &%{&1 | fail_on: "INSERT INTO warehouse.flows__rebuild"})

    assert {:error, {:partition_rebuild, "warehouse.flows", {:starrocks_mysql, "boom"}}} =
             run(agent)

    assert layout(agent) == %{"flows" => :unpartitioned, "flows__rebuild" => :partitioned}
    refute Enum.any?(sent(agent), &(&1 =~ "SWAP"))

    Agent.update(agent, &%{&1 | fail_on: nil, sent: []})
    assert run(agent) == :ok
    assert layout(agent) == %{"flows" => :partitioned}

    # The half-filled copy is discarded, never swapped in.
    assert Enum.at(sent(agent), 1) == "DROP TABLE IF EXISTS warehouse.flows__rebuild FORCE"
    assert Enum.at(sent(agent), 2) == "CREATE TABLE IF NOT EXISTS warehouse.flows__rebuild ("
  end

  test "a run that died after the swap is finished, not repeated" do
    # `flows` is already the new table; `flows__rebuild` still holds the old rows.
    agent =
      start_warehouse(
        %{"flows" => :partitioned, "flows__rebuild" => :unpartitioned},
        %{"flows" => ["id", "time", "bytes", "app"], "flows__rebuild" => ["id", "time", "bytes"]}
      )

    assert run(agent) == :ok
    assert layout(agent) == %{"flows" => :partitioned}

    statements = sent(agent)
    refute Enum.any?(statements, &(&1 =~ "SWAP"))
    refute Enum.any?(statements, &(&1 =~ "CREATE TABLE"))
    assert Enum.count(statements, &(&1 =~ "LEFT ANTI JOIN")) == 2
    assert "CREATE MATERIALIZED VIEW IF NOT EXISTS warehouse.flows_hourly" in statements
    assert List.last(statements) == "DROP TABLE IF EXISTS warehouse.flows__rebuild FORCE"
  end

  test "two partitioned tables of the same name are not guessed at" do
    agent = start_warehouse(%{"flows" => :partitioned, "flows__rebuild" => :partitioned}, %{})

    assert run(agent) == :ok
    assert sent(agent) == []
  end

  test "a table with no partitioned definition in this release is an error, not a silent skip" do
    agent = start_warehouse(%{"mystery" => :unpartitioned}, %{})

    assert {:error, {:partition_rebuild, "warehouse.mystery", :no_partitioned_definition}} =
             run(agent, %{retention_days: [{"mystery", 30}]})

    assert sent(agent) == []
  end

  test "the shipped schema gives every retained table a partitioned definition and rollups that refresh by day" do
    statements = Enum.flat_map(Schema.migrations(), & &1.statements)

    for {table, _days} <-
          ServiceRadar.Analytics.StarRocks.Retention.days_by_table(retention_days: []) do
      create =
        Enum.find(
          statements,
          &(&1 =~ ~r/^CREATE TABLE IF NOT EXISTS serviceradar\.#{table}\s*\(/)
        )

      assert create =~ "PARTITION BY date_trunc('day',", "#{table} has no partitioned CREATE"
    end

    for rollup <- ~w(ocsf_network_activity_hourly timeseries_metrics_hourly events_hourly) do
      newest =
        statements
        |> Enum.filter(&(&1 =~ "CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.#{rollup}\n"))
        |> List.last()

      assert newest =~ "PARTITION BY day", "#{rollup} would refresh in full"
      assert newest =~ "AS day,"
    end
  end
end
