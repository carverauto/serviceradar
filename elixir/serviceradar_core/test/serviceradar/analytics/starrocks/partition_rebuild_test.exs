defmodule ServiceRadar.Analytics.StarRocks.PartitionRebuildTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.PartitionRebuild
  alias ServiceRadar.Analytics.StarRocks.Retention
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
                 PROPERTIES ("replication_num" = "3", "partition_live_number" = "90");
                 """},
                {"0002_metrics.sql",
                 """
                 CREATE TABLE IF NOT EXISTS serviceradar.metrics (
                   `timestamp` DATETIME NOT NULL,
                   series VARCHAR(64) NOT NULL,
                   value DOUBLE
                 )
                 PRIMARY KEY (`timestamp`, series)
                 PARTITION BY date_trunc('day', `timestamp`)
                 DISTRIBUTED BY HASH(series) BUCKETS 16
                 PROPERTIES ("replication_num" = "3", "partition_live_number" = "90");
                 """}
              ])

  # A warehouse reduced to what the rebuild asks of one: which tables exist and
  # whether they are partitioned, their columns, the days they hold, and a log
  # of what it was sent. CREATE, SWAP, the per-day copy and DROP all act on that
  # state, so a second run sees what the first one left behind.
  defp start_warehouse(tables) do
    {:ok, agent} = Agent.start_link(fn -> %{tables: tables, sent: [], fail_on: nil} end)
    agent
  end

  defp old(columns, days), do: %{kind: :unpartitioned, columns: columns, days: days}
  defp new(columns, days), do: %{kind: :partitioned, columns: columns, days: days}

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
  defp clear(agent), do: Agent.update(agent, &%{&1 | sent: []})
  defp tables(agent), do: Agent.get(agent, & &1.tables)
  defp kinds(agent), do: Map.new(tables(agent), fn {name, table} -> {name, table.kind} end)

  defp ok(rows \\ []), do: {:ok, %{columns: [], rows: rows}}

  defp answer(state, "SELECT TABLE_NAME, PARTITION_KEY" <> _) do
    rows =
      Enum.map(state.tables, fn {name, table} ->
        [name, if(table.kind == :partitioned, do: "`time`", else: "")]
      end)

    {ok(rows), state}
  end

  defp answer(state, "SELECT COLUMN_NAME" <> _ = sql) do
    [_, table] = Regex.run(~r/table_name = '(\w+)'/, sql)
    {ok(Enum.map(state.tables[table].columns, &[&1])), state}
  end

  defp answer(state, "SELECT DISTINCT date_trunc" <> _ = sql) do
    [_, table] = Regex.run(~r/FROM warehouse\.(\w+) /, sql)
    days = state.tables[table].days |> Enum.sort(:desc) |> Enum.map(&["#{&1} 00:00:00"])
    {ok(days), state}
  end

  defp answer(state, sql) do
    state = %{state | sent: state.sent ++ [sql |> String.split("\n") |> hd() |> String.trim()]}

    if state.fail_on && String.contains?(sql, state.fail_on),
      do: {{:error, {:starrocks_mysql, "boom"}}, state},
      else: {ok(), apply_ddl(state, sql)}
  end

  defp apply_ddl(state, sql) do
    cond do
      match = Regex.run(~r/^CREATE TABLE IF NOT EXISTS warehouse\.(\w+__rebuild) \(/, sql) ->
        [_, copy] = match
        columns = ~r/^\s+`?(\w+)`? [A-Z]/m |> Regex.scan(sql) |> Enum.map(&List.last/1)
        put_in(state.tables, Map.put_new(state.tables, copy, new(columns, [])))

      match =
          Regex.run(
            ~r/^INSERT INTO warehouse\.(\w+__rebuild) .* >= '(\d{4}-\d\d-\d\d) 00:00:00'/,
            sql
          ) ->
        [_, copy, day] = match
        update_in(state.tables[copy].days, &[day | &1])

      match = Regex.run(~r/^ALTER TABLE warehouse\.(\w+) SWAP WITH (\w+)$/, sql) ->
        [_, table, copy] = match
        swapped = %{table => state.tables[copy], copy => state.tables[table]}
        %{state | tables: Map.merge(state.tables, swapped)}

      match = Regex.run(~r/^DROP TABLE IF EXISTS warehouse\.(\w+) FORCE$/, sql) ->
        [_, table] = match
        %{state | tables: Map.delete(state.tables, table)}

      true ->
        state
    end
  end

  test "a fresh warehouse, and one already partitioned, are left entirely alone" do
    fresh = start_warehouse(%{})
    assert run(fresh) == :ok
    assert sent(fresh) == []

    current = start_warehouse(%{"flows" => new(["id", "time"], ["2025-01-02"])})
    assert run(current) == :ok
    assert sent(current) == []
  end

  test "a table is copied a day at a time, refreshed, swapped, caught up a day at a time, and dropped" do
    # The old table predates `app`, so only the columns both sides have are copied.
    agent =
      start_warehouse(%{
        "flows" => old(["id", "time", "bytes"], ["2025-01-01", "2025-01-02", "2025-01-03"])
      })

    assert run(agent) == :ok
    assert kinds(agent) == %{"flows" => :partitioned}

    copy =
      "INSERT INTO warehouse.flows__rebuild (`id`, `time`, `bytes`) SELECT `id`, `time`, `bytes` FROM warehouse.flows WHERE "

    catch_up =
      "INSERT INTO warehouse.flows (`id`, `time`, `bytes`) SELECT o.`id`, o.`time`, o.`bytes` FROM warehouse.flows__rebuild o "

    day = fn column, date ->
      "#{column} >= '#{date} 00:00:00' AND #{column} < DATE_ADD('#{date} 00:00:00', INTERVAL 1 DAY)"
    end

    caught_up = fn date ->
      catch_up <>
        "LEFT ANTI JOIN warehouse.flows n ON o.`id` = n.`id` AND o.`time` = n.`time` AND #{day.("n.`time`", date)} " <>
        "WHERE #{day.("o.`time`", date)}"
    end

    pass = Enum.map(["2025-01-03", "2025-01-02", "2025-01-01"], caught_up)

    assert sent(agent) ==
             [
               "CREATE TABLE IF NOT EXISTS warehouse.flows__rebuild (",
               # Newest first, so the days people look at are ready soonest.
               copy <> day.("`time`", "2025-01-03"),
               copy <> day.("`time`", "2025-01-02"),
               copy <> day.("`time`", "2025-01-01"),
               # Rows changed in place since their day was copied: the two most
               # recent days again, while nothing else writes the new table.
               copy <> day.("`time`", "2025-01-03"),
               copy <> day.("`time`", "2025-01-02"),
               "DROP MATERIALIZED VIEW IF EXISTS warehouse.flows_hourly",
               "ALTER TABLE warehouse.flows SWAP WITH flows__rebuild"
             ] ++
               pass ++
               ["sleep 5000"] ++
               pass ++
               ["DROP TABLE IF EXISTS warehouse.flows__rebuild FORCE"]

    clear(agent)
    assert run(agent) == :ok
    assert sent(agent) == []
  end

  test "the rollups stay until every copy is done, so the slow part costs readers nothing" do
    agent =
      start_warehouse(%{
        "flows" => old(["id", "time"], ["2025-01-02"]),
        "metrics" => old(["timestamp", "series", "value"], ["2025-01-02"])
      })

    assert run(agent, %{retention_days: [{"flows", 90}, {"metrics", 90}]}) == :ok
    assert kinds(agent) == %{"flows" => :partitioned, "metrics" => :partitioned}

    statements = sent(agent)
    last_copy = Enum.find_index(statements, &(&1 =~ "INSERT INTO warehouse.metrics__rebuild"))
    first_drop = Enum.find_index(statements, &(&1 =~ "DROP MATERIALIZED VIEW"))
    assert last_copy < first_drop

    # The catch-up joins on each table's own key.
    assert Enum.any?(
             statements,
             &(&1 =~ "ON o.`timestamp` = n.`timestamp` AND o.`series` = n.`series`")
           )
  end

  test "one table that cannot be rebuilt does not keep the others unpartitioned" do
    agent =
      start_warehouse(%{
        "flows" => old(["id", "time"], ["2025-01-02"]),
        "metrics" => old(["timestamp", "series", "value"], ["2025-01-02"])
      })

    Agent.update(agent, &%{&1 | fail_on: "INSERT INTO warehouse.flows__rebuild"})

    assert {:error, {:partition_rebuild, [{"flows", {:copy, "2025-01-02", _}}]}} =
             run(agent, %{retention_days: [{"flows", 90}, {"metrics", 90}]})

    assert kinds(agent)["metrics"] == :partitioned
    assert kinds(agent)["flows"] == :unpartitioned
    # The table that failed kept its rollup: nothing of it was cut over.
    refute "DROP MATERIALIZED VIEW IF EXISTS warehouse.flows_hourly" in sent(agent)
  end

  test "the copy is created with the operator's retention, not the DDL default" do
    agent = start_warehouse(%{"flows" => old(["id", "time"], [])})
    parent = self()

    query = fn sql ->
      if sql =~ "CREATE TABLE", do: send(parent, {:create, sql})
      Agent.get_and_update(agent, &answer(&1, sql))
    end

    assert run(agent, %{query: query, retention_days: [{"flows", 180}]}) == :ok
    assert_received {:create, sql}
    assert sql =~ ~s("partition_live_number" = "180")
    refute sql =~ ~s("partition_live_number" = "90")
    assert sql =~ ~s("replication_num" = "1")
    refute sql =~ "serviceradar."
  end

  test "a copy that fails keeps the days it finished, and the next run copies only the rest" do
    agent =
      start_warehouse(%{
        "flows" => old(["id", "time"], ["2025-01-01", "2025-01-02", "2025-01-03"])
      })

    Agent.update(agent, &%{&1 | fail_on: ">= '2025-01-02 00:00:00'"})

    assert {:error,
            {:partition_rebuild, [{"flows", {:copy, "2025-01-02", {:starrocks_mysql, "boom"}}}]}} =
             run(agent)

    # The live table and its rollup were never touched.
    assert kinds(agent) == %{"flows" => :unpartitioned, "flows__rebuild" => :partitioned}
    refute Enum.any?(sent(agent), &(&1 =~ ~r/SWAP|MATERIALIZED VIEW/))
    assert tables(agent)["flows__rebuild"].days == ["2025-01-03"]

    Agent.update(agent, &%{&1 | fail_on: nil, sent: []})
    assert run(agent) == :ok
    assert kinds(agent) == %{"flows" => :partitioned}

    # Before the swap: the two unfinished days, then the refresh of the two newest.
    copies =
      agent
      |> sent()
      |> Enum.take_while(&(not (&1 =~ "SWAP")))
      |> Enum.filter(&(&1 =~ "INSERT INTO warehouse.flows__rebuild"))
      |> Enum.map(&(~r/>= '(\S+) / |> Regex.run(&1) |> List.last()))

    assert copies == ["2025-01-02", "2025-01-01", "2025-01-03", "2025-01-02"]
  end

  test "a run that died after the swap is finished, not repeated" do
    # `flows` is already the new table; `flows__rebuild` still holds the old rows.
    agent =
      start_warehouse(%{
        "flows" => new(["id", "time", "bytes", "app"], ["2025-01-02"]),
        "flows__rebuild" => old(["id", "time", "bytes"], ["2025-01-02"])
      })

    assert run(agent) == :ok
    assert kinds(agent) == %{"flows" => :partitioned}

    statements = sent(agent)
    refute Enum.any?(statements, &(&1 =~ ~r/SWAP|CREATE TABLE|MATERIALIZED VIEW/))
    # One day held, two passes.
    assert Enum.count(statements, &(&1 =~ "LEFT ANTI JOIN")) == 2
    assert List.last(statements) == "DROP TABLE IF EXISTS warehouse.flows__rebuild FORCE"
  end

  test "an arrangement this module never produces is an error, not a guess" do
    both_new = start_warehouse(%{"flows" => new(["id"], []), "flows__rebuild" => new(["id"], [])})
    assert {:error, {:partition_rebuild, [{"flows", :unexpected_layout}]}} = run(both_new)
    assert sent(both_new) == []

    both_old = start_warehouse(%{"flows" => old(["id"], []), "flows__rebuild" => old(["id"], [])})
    assert {:error, {:partition_rebuild, [{"flows", :unexpected_layout}]}} = run(both_old)
    assert sent(both_old) == []
  end

  test "a table with no partitioned definition in this release is an error, not a silent skip" do
    agent = start_warehouse(%{"mystery" => old(["id"], [])})

    assert {:error, {:partition_rebuild, [{"mystery", :no_partitioned_definition}]}} =
             run(agent, %{retention_days: [{"mystery", 30}]})

    assert sent(agent) == []
  end

  test "every table this release retains can be rebuilt from the schema it ships" do
    retention = Retention.days_by_table(retention_days: [])

    statements = Enum.flat_map(Schema.migrations(), & &1.statements)

    shipped_columns = fn table ->
      create =
        Enum.find(statements, &(&1 =~ ~r/^CREATE TABLE IF NOT EXISTS serviceradar\.#{table} \(/))

      ~r/^\s+`?(\w+)`? [A-Z]/m |> Regex.scan(create) |> Enum.map(&List.last/1)
    end

    agent =
      start_warehouse(
        Map.new(retention, fn {table, _days} ->
          {table, old(shipped_columns.(table), ["2025-01-02"])}
        end)
      )

    # The real parser, over the real files: a CREATE it cannot read fails here.
    assert run(agent, %{migrations: Schema.migrations(), retention_days: retention}) == :ok
    assert kinds(agent) == Map.new(retention, fn {table, _days} -> {table, :partitioned} end)

    swaps = Enum.filter(sent(agent), &(&1 =~ "SWAP WITH"))
    assert length(swaps) == length(retention)
  end
end
