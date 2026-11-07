defmodule ServiceRadar.Analytics.StarRocks.SchemaMigratorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.Analytics.StarRocks.SchemaMigrator
  alias ServiceRadar.Analytics.StarRocks.Workload

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
          fail_on: nil,
          fail_with: "boom"
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
      do: {{:error, {:starrocks_mysql, state.fail_with}}, state},
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
        {{:error, {:starrocks_mysql, state.fail_with}}, state}

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
      sleep: fn _ms -> :ok end,
      workload_groups: fn _query -> :ok end
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

  test "the migrator's connection runs DDL in default_wg while the pool's sessions are pinned" do
    assert {Workload, :pin_session, [_group]} = MySQL.connection_opts([])[:after_connect]
    refute Keyword.has_key?(SchemaMigrator.connection_opts([]), :after_connect)
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

  test "resource groups converge after the schema, and their failure does not fail it" do
    agent = start_warehouse()
    parent = self()

    groups = fn query ->
      # The versioned DDL is already recorded by the time groups converge.
      send(parent, {:ledger_at_groups, state(agent).ledger})
      query.("SHOW RESOURCE GROUPS ALL")

      {:error,
       {:starrocks_mysql, "Access denied; you need (at least one of) the GRANT privilege"}}
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert migrate(agent, workload_groups: groups) == {:ok, [1, 2, 3]}
      end)

    assert_received {:ledger_at_groups, [1, 2, 3]}
    assert log =~ "StarRocks resource groups not applied"
    assert List.last(state(agent).ddl) == "SHOW RESOURCE GROUPS ALL"

    # A failed migration stops before the groups: the retry converges them.
    failing = start_warehouse(%{fail_on: ~r/ADD COLUMN comm/})

    assert {:error, {3, _}} =
             migrate(failing,
               workload_groups: fn _ -> flunk("groups before a complete schema") end
             )
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

  test "a warehouse out of memory is given minutes to recover, not the usual short retry" do
    run_with = fn message ->
      agent = start_warehouse(%{fail_on: ~r/ADD COLUMN comm/, fail_with: message})
      {:ok, slept} = Agent.start_link(fn -> [] end)

      SchemaMigrator.run(
        query: query_fun(agent),
        with_lock: fn fun -> fun.(fn -> :ok end) end,
        migrations: @migrations,
        database: "serviceradar",
        attempts: 3,
        sleep: fn ms -> Agent.update(slept, &(&1 ++ [ms])) end
      )

      Agent.get(slept, & &1)
    end

    assert run_with.("(5609) Memory of process exceed limit. Used: 2000, Limit: 1000.") ==
             [600_000, 600_000]

    assert run_with.("boom") == [5_000, 10_000]
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

  # A warehouse that runs each schema change as a background job and, like
  # StarRocks, refuses an ALTER while one is still running. Each SHOW ALTER poll
  # advances the running job one stage of `lifecycle`, and its column changes
  # only when it reaches FINISHED; CANCELLED ends it with the column unchanged.
  # `columns` maps {table, column} to its type.
  defp start_alter_warehouse(overrides) do
    initial =
      Map.merge(
        %{
          lifecycle: ["RUNNING", "FINISHED"],
          columns: %{},
          running: nil,
          last_state: %{},
          ledger: [],
          sent: [],
          refused: []
        },
        overrides
      )

    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp alter_query(agent), do: fn sql -> Agent.get_and_update(agent, &alter_answer(&1, sql)) end

  defp alter_answer(state, sql) do
    cond do
      match = Regex.run(~r/^ALTER TABLE \S+?\.(\w+) (?:ADD|MODIFY) COLUMN `?(\w+)`? (\S+)/, sql) ->
        [_, table, column, type] = match
        start_alter(state, {table, column}, String.downcase(type))

      match = Regex.run(~r/^SHOW ALTER TABLE COLUMN .* TableName = '(\w+)'/, sql) ->
        [_, table] = match
        poll(state, table)

      match =
          Regex.run(
            ~r/^SELECT (1|COLUMN_TYPE) FROM .* table_name = '(\w+)' AND column_name = '(\w+)'/,
            sql
          ) ->
        [_, probe, table, column] = match
        {probe_result(probe, Map.get(state.columns, {table, column})), state}

      String.starts_with?(sql, "SHOW BACKENDS") ->
        {nodes(1), state}

      String.starts_with?(sql, "SELECT version FROM") ->
        {result(["version"], Enum.map(state.ledger, &[&1])), state}

      match = Regex.run(~r/^INSERT INTO .* VALUES \((\d+),/, sql) ->
        [_, version] = match
        {result([], []), %{state | ledger: state.ledger ++ [String.to_integer(version)]}}

      true ->
        {result([], []), state}
    end
  end

  defp start_alter(%{running: nil} = state, key, type) do
    {result([], []), %{state | running: {key, type, state.lifecycle}, sent: state.sent ++ [key]}}
  end

  defp start_alter(state, {table, _column} = key, _type) do
    message = "(1064) A schema change operation is in progress on the table #{table}."
    {{:error, {:starrocks_mysql, message}}, %{state | refused: state.refused ++ [key]}}
  end

  defp poll(%{running: {{table, _} = key, type, [stage | stages]}} = state, table) do
    state = %{state | last_state: Map.put(state.last_state, table, stage)}

    state =
      case stage do
        "FINISHED" -> %{state | running: nil, columns: Map.put(state.columns, key, type)}
        "CANCELLED" -> %{state | running: nil}
        _running -> %{state | running: {key, type, stages}}
      end

    {result(["State"], [[stage]]), state}
  end

  defp poll(state, table) do
    case Map.fetch(state.last_state, table) do
      {:ok, stage} -> {result(["State"], [[stage]]), state}
      :error -> {result(["State"], []), state}
    end
  end

  defp probe_result(_probe, nil), do: result(["1"], [])
  defp probe_result("1", _type), do: result(["1"], [[1]])
  defp probe_result("COLUMN_TYPE", type), do: result(["COLUMN_TYPE"], [[type]])

  # One lock for every runner, as the PostgreSQL advisory lock is one for
  # every replica.
  defp shared_lock do
    {:ok, holder} = Agent.start_link(fn -> nil end)

    fn fun ->
      acquire(holder)

      try do
        fun.(fn -> :ok end)
      after
        Agent.update(holder, fn _ -> nil end)
      end
    end
  end

  defp acquire(holder) do
    me = self()

    case Agent.get_and_update(holder, fn
           nil -> {:ok, me}
           other -> {:busy, other}
         end) do
      :ok ->
        :ok

      :busy ->
        Process.sleep(5)
        acquire(holder)
    end
  end

  defp shipped(version), do: Enum.find(Schema.migrations(), &(&1.version == version))

  defp added_columns(migration) do
    for statement <- migration.statements,
        [_, table, column] <- [
          Regex.run(~r/ALTER TABLE \S+?\.(\w+) ADD COLUMN `?(\w+)`?/, statement)
        ],
        do: {table, column}
  end

  test "each events document column is added only after the previous ALTER has finished" do
    agent = start_alter_warehouse(%{})

    assert migrate(agent, query: alter_query(agent), migrations: [shipped(18)]) == {:ok, [18]}

    result = state(agent)
    assert result.refused == []

    assert result.sent ==
             Enum.map(~w(log_level metadata unmapped device observables), &{"events", &1})

    assert result.running == nil
  end

  test "a free-text column is widened only when it is narrower, each after the previous ALTER" do
    migration = shipped(37)

    # An upgraded warehouse: events.message and logs.body still carry their
    # old widths, every other column already has the target type.
    columns =
      for statement <- migration.statements,
          [_, table, column, type] <-
            [Regex.run(~r/ALTER TABLE \S+?\.(\w+) MODIFY COLUMN (\w+) (\S+)/, statement)],
          into: %{},
          do: {{table, column}, String.downcase(type)}

    columns =
      Map.merge(columns, %{
        {"events", "message"} => "varchar(65533)",
        {"logs", "body"} => "VARCHAR(65533)"
      })

    agent = start_alter_warehouse(%{columns: columns})

    assert migrate(agent, query: alter_query(agent), migrations: [migration]) == {:ok, [37]}

    result = state(agent)
    assert result.refused == []
    assert result.sent == [{"events", "message"}, {"logs", "body"}]
    assert result.running == nil
  end

  test "OTel span, BMP, and flow-observation free-text columns are widened when narrower" do
    migration = shipped(41)

    columns =
      for statement <- migration.statements,
          [_, table, column, type] <-
            [Regex.run(~r/ALTER TABLE \S+?\.(\w+) MODIFY COLUMN (\w+) (\S+)/, statement)],
          into: %{},
          do: {{table, column}, String.downcase(type)}

    columns =
      Map.merge(columns, %{
        {"otel_traces", "name"} => "varchar(65533)",
        {"otel_traces", "service_name"} => "varchar(1024)",
        {"bmp_routing_events", "event_type"} => "varchar(256)",
        {"bmp_routing_events", "message"} => "varchar(65533)",
        {"flow_process_attribution_observations", "comm"} => "varchar(256)"
      })

    agent = start_alter_warehouse(%{columns: columns})

    assert migrate(agent, query: alter_query(agent), migrations: [migration]) == {:ok, [41]}

    result = state(agent)
    assert result.refused == []

    assert result.sent == [
             {"otel_traces", "name"},
             {"otel_traces", "service_name"},
             {"bmp_routing_events", "event_type"},
             {"bmp_routing_events", "message"},
             {"flow_process_attribution_observations", "comm"}
           ]

    assert result.running == nil
  end

  test "replicas migrating a shared-data warehouse send each ALTER once, never into a running change" do
    migration = shipped(36)

    # A shared-data table is still mid-change at FINISHED_REWRITING. The last
    # change on events was cancelled in some earlier run; that holds nothing up.
    agent =
      start_alter_warehouse(%{
        lifecycle: ["PENDING", "RUNNING", "FINISHED_REWRITING", "FINISHED_REWRITING", "FINISHED"],
        last_state: %{"events" => "CANCELLED"}
      })

    lock = shared_lock()

    results =
      [:replica_a, :replica_b]
      |> Enum.map(fn _replica ->
        Task.async(fn ->
          migrate(agent, query: alter_query(agent), migrations: [migration], with_lock: lock)
        end)
      end)
      |> Task.await_many(10_000)

    # One replica applies 36; the other takes the lock afterwards, finds it in
    # the ledger and sends nothing.
    assert Enum.sort(results) == [{:ok, []}, {:ok, [36]}]

    result = state(agent)
    assert result.refused == []
    assert result.sent == added_columns(migration)
    assert result.ledger == [36]
  end

  test "a runner that takes over mid-ALTER waits for that change, then skips its column" do
    migration = shipped(36)
    [{_table, orphaned} = first | rest] = added_columns(migration)

    # The previous holder died after sending the first ADD COLUMN; StarRocks is
    # still running it, and the column is not there yet.
    agent =
      start_alter_warehouse(%{
        lifecycle: ["RUNNING", "FINISHED_REWRITING", "FINISHED"],
        running: {first, "varchar(1048576)", ["RUNNING", "FINISHED_REWRITING", "FINISHED"]}
      })

    assert migrate(agent, query: alter_query(agent), migrations: [migration]) == {:ok, [36]}

    result = state(agent)
    assert result.refused == []
    assert result.sent == rest
    assert Map.has_key?(result.columns, {"events", orphaned})
    assert result.ledger == [36]
  end

  test "a runner that loses the lock while waiting out a change that is then cancelled sends no ALTER" do
    migration = shipped(36)
    [first | _rest] = added_columns(migration)

    # A crashed holder's ADD COLUMN is still running and ends cancelled, so the
    # column stays absent. This runner's connection drops during that wait,
    # and the replica that takes the lock over will send the ALTER itself.
    agent =
      start_alter_warehouse(%{
        running: {first, "varchar(1048576)", ["RUNNING", "CANCELLED"]}
      })

    still_locked = fn ->
      if Agent.get(agent, &(&1.last_state["events"] == "CANCELLED")),
        do: raise("lock lost"),
        else: :ok
    end

    assert {:error, %RuntimeError{message: "lock lost"}} =
             migrate(agent,
               query: alter_query(agent),
               migrations: [migration],
               with_lock: fn fun -> fun.(still_locked) end
             )

    result = state(agent)
    assert result.sent == []
    assert result.refused == []
    assert result.ledger == []
  end

  test "a column-type probe that fails stops the migration without sending the MODIFY" do
    migrations =
      Schema.build([
        {"0001_widen.sql",
         "ALTER TABLE serviceradar.flows MODIFY COLUMN comm VARCHAR(1048576) NULL;"}
      ])

    agent = start_warehouse(%{fail_on: ~r/COLUMN_TYPE/})

    assert {:error, {1, {:starrocks_mysql, "boom"}}} = migrate(agent, migrations: migrations)
    refute Enum.any?(state(agent).ddl, &(&1 =~ "MODIFY COLUMN"))
    assert state(agent).ledger == []
  end

  # A warehouse that runs optimize jobs: `buckets` maps a table to
  # %{partition => bucket count} and `sizes` a partition to its stored bytes
  # (1 MiB when absent). A rewrite of a batch of partitions is a job polled
  # through its stages (`stages` per {table, first partition}, else
  # `lifecycle`) that applies the new count only on FINISHED. `refuse` lists
  # partitions whose ALTER StarRocks rejects. Any distribution change on a
  # table with a running job is refused, as StarRocks refuses it.
  defp start_bucket_warehouse(overrides) do
    initial =
      Map.merge(
        %{
          lifecycle: ["PENDING", "RUNNING", "FINISHED"],
          stages: %{},
          sizes: %{},
          refuse: [],
          buckets: %{},
          jobs: %{},
          ledger: [],
          sent: [],
          refused: []
        },
        overrides
      )

    {:ok, agent} = Agent.start_link(fn -> initial end)
    agent
  end

  defp bucket_query(agent), do: fn sql -> Agent.get_and_update(agent, &bucket_answer(&1, sql)) end

  defp bucket_answer(state, sql) do
    cond do
      match =
          Regex.run(
            ~r/^ALTER TABLE \S+?\.(\w+) (?:PARTITIONS \(([^)]*)\) )?DISTRIBUTED BY HASH\([^)]*\) (DEFAULT )?BUCKETS (\d+)$/,
            sql
          ) ->
        [_, table, partitions, default, count] = match
        batch = partitions |> String.split(", ", trim: true) |> Enum.map(&String.trim(&1, "`"))
        distribute(state, table, batch, default != "", String.to_integer(count))

      match = Regex.run(~r/^SHOW ALTER TABLE OPTIMIZE .* TableName = '(\w+)'/, sql) ->
        [_, table] = match
        optimize_poll(state, table)

      String.starts_with?(sql, "SHOW ALTER TABLE COLUMN") ->
        {result(["State"], []), state}

      match =
          Regex.run(
            ~r/^SELECT PARTITION_NAME, BUCKETS, DATA_SIZE FROM information_schema.partitions_meta .* TABLE_NAME = '(\w+)'/,
            sql
          ) ->
        [_, table] = match

        rows =
          for {partition, count} <- state.buckets |> Map.get(table, %{}) |> Enum.sort(),
              do: [partition, count, Map.get(state.sizes, partition, 1_048_576)]

        {result(["PARTITION_NAME", "BUCKETS", "DATA_SIZE"], rows), state}

      String.starts_with?(sql, "SHOW BACKENDS") ->
        {nodes(1), state}

      String.starts_with?(sql, "SELECT version FROM") ->
        {result(["version"], Enum.map(state.ledger, &[&1])), state}

      match = Regex.run(~r/^INSERT INTO .* VALUES \((\d+),/, sql) ->
        [_, version] = match
        {result([], []), %{state | ledger: state.ledger ++ [String.to_integer(version)]}}

      true ->
        {result([], []), state}
    end
  end

  defp distribute(state, table, batch, default?, count) do
    sent = if default?, do: {:default, table}, else: {:rewrite, table, batch}

    cond do
      running?(state, table) ->
        message = "(1064) Table #{table} is in OPTIMIZE state, cannot alter it."
        {{:error, {:starrocks_mysql, message}}, %{state | refused: state.refused ++ [sent]}}

      default? ->
        {result([], []), %{state | sent: state.sent ++ [sent]}}

      Enum.any?(batch, &(&1 in state.refuse)) ->
        message = "(1064) Partitions #{inspect(batch)} cannot be optimized."
        {{:error, {:starrocks_mysql, message}}, %{state | sent: state.sent ++ [sent]}}

      true ->
        stages = Map.get(state.stages, {table, hd(batch)}, state.lifecycle)
        job = {batch, count, stages}

        {result([], []),
         %{state | jobs: Map.put(state.jobs, table, job), sent: state.sent ++ [sent]}}
    end
  end

  defp running?(state, table) do
    match?(
      {_partition, _count, [stage | _]} when stage not in ["FINISHED", "CANCELLED"],
      Map.get(state.jobs, table)
    )
  end

  defp optimize_poll(state, table) do
    case Map.get(state.jobs, table) do
      nil ->
        {result(["State"], []), state}

      {partition, count, [stage]} ->
        {result(["State"], [[stage]]), finish(state, table, partition, count, stage)}

      {partition, count, [stage | stages]} ->
        state = %{state | jobs: Map.put(state.jobs, table, {partition, count, stages})}
        {result(["State"], [[stage]]), finish(state, table, partition, count, stage)}
    end
  end

  defp finish(state, table, batch, count, "FINISHED") when is_list(batch) do
    Enum.reduce(batch, state, fn partition, state ->
      %{state | buckets: put_in(state.buckets, [table, partition], count)}
    end)
  end

  defp finish(state, _table, _partition, _count, _stage), do: state

  defp shipped_rewrites(migration) do
    for statement <- migration.statements,
        [_, table, count] <- [
          Regex.run(
            ~r/ALTER TABLE \S+?\.(\w+) DISTRIBUTED BY HASH\([^)]*\) BUCKETS (\d+)$/,
            statement
          )
        ],
        do: {table, String.to_integer(count)}
  end

  test "bucket rewrites batch a table's history, after any running optimize, skipping converged ones" do
    migration = shipped(39)
    tables = shipped_rewrites(migration)
    [{converged, target} | _] = tables
    {busy, _} = List.last(tables)

    old = %{"$shadow_automatic_partition" => 16, "p20260101" => 16, "p20260102" => 8}

    buckets =
      tables
      |> Map.new(fn {table, _count} -> {table, old} end)
      |> Map.put(converged, %{"p20260101" => target, "p20260102" => target})

    # A runner that lost the lock left a job running on the last table.
    agent =
      start_bucket_warehouse(%{
        buckets: buckets,
        jobs: %{busy => {nil, 16, ["RUNNING", "RUNNING", "FINISHED"]}}
      })

    assert migrate(agent, query: bucket_query(agent), migrations: [migration]) == {:ok, [39]}

    result = state(agent)
    assert result.refused == []

    # Small partitions share one job; the converged table and the placeholder
    # are left alone.
    assert result.sent ==
             Enum.flat_map(tables, fn
               {^converged, _} ->
                 [{:default, converged}]

               {table, _} ->
                 [{:default, table}, {:rewrite, table, ["p20260101", "p20260102"]}]
             end)

    for {table, count} <- tables do
      assert Map.delete(result.buckets[table], "$shadow_automatic_partition") ==
               %{"p20260101" => count, "p20260102" => count}
    end
  end

  test "a large table's history is rewritten a budget of data at a time, oldest first" do
    migration = shipped(39)
    [{table, count} | _] = shipped_rewrites(migration)
    mib = 1_048_576

    agent =
      start_bucket_warehouse(%{
        buckets:
          ~w(p20260101 p20260102 p20260103 p20260104 p20260105)
          |> Map.new(&{&1, 8})
          |> then(&%{table => &1}),
        # 100 + 20 MiB fit one 128 MiB job; 200 MiB goes alone, whether StarRocks
        # reports bytes (4.x) or text (3.5); an unreported size goes alone.
        sizes: %{
          "p20260101" => 100 * mib,
          "p20260102" => "20MB",
          "p20260103" => "200.5MB",
          "p20260104" => nil,
          "p20260105" => "1MB"
        }
      })

    assert migrate(agent, query: bucket_query(agent), migrations: [migration]) == {:ok, [39]}

    rewrites = Enum.filter(state(agent).sent, &match?({:rewrite, ^table, _batch}, &1))

    assert rewrites == [
             {:rewrite, table, ["p20260101", "p20260102"]},
             {:rewrite, table, ["p20260103"]},
             {:rewrite, table, ["p20260104"]},
             {:rewrite, table, ["p20260105"]}
           ]

    assert state(agent).buckets[table] |> Map.values() |> Enum.uniq() == [count]
  end

  test "partitions StarRocks will not rewrite are reported and skipped, never failing the migration" do
    migration = shipped(39)
    [{table, count} | _] = shipped_rewrites(migration)
    big = 200 * 1_048_576

    agent =
      start_bucket_warehouse(%{
        buckets: %{table => %{"p20260101" => 8, "p20260102" => 8, "p20260103" => 8}},
        sizes: %{"p20260101" => big, "p20260102" => big, "p20260103" => big},
        stages: %{{table, "p20260101"} => ["RUNNING", "CANCELLED"]},
        refuse: ["p20260102"]
      })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert migrate(agent, query: bucket_query(agent), migrations: [migration]) == {:ok, [39]}
      end)

    result = state(agent)
    assert result.ledger == [39]
    assert result.buckets[table] == %{"p20260101" => 8, "p20260102" => 8, "p20260103" => count}
    assert log =~ "StarRocks kept the old bucket count on 2 of 3 partitions of #{table}"
  end

  test "a rewrite that loses its connection fails the migration, to be resumed" do
    migration = shipped(39)
    [{table, _count} | _] = shipped_rewrites(migration)
    agent = start_bucket_warehouse(%{buckets: %{table => %{"p20260101" => 8}}})

    query = fn sql ->
      if sql =~ "PARTITIONS (", do: {:error, :connect_failed}, else: bucket_query(agent).(sql)
    end

    assert {:error, {39, :connect_failed}} =
             migrate(agent, query: query, migrations: [migration])

    assert state(agent).ledger == []
  end

  test "a rewrite that loses its connection or runs out of memory fails the migration, to be resumed" do
    migration = shipped(39)
    [{table, _count} | _] = shipped_rewrites(migration)

    for message <- [
          "(2013) Lost connection to MySQL server during query",
          "(2006) MySQL server has gone away",
          "(5609) Memory of process exceed limit. Used: 2000, Limit: 1000."
        ] do
      agent = start_bucket_warehouse(%{buckets: %{table => %{"p20260101" => 8}}})

      query = fn sql ->
        if sql =~ "PARTITIONS (",
          do: {:error, {:starrocks_mysql, message}},
          else: bucket_query(agent).(sql)
      end

      assert {:error, {39, {:starrocks_mysql, ^message}}} =
               migrate(agent, query: query, migrations: [migration])

      assert state(agent).ledger == []
    end
  end

  test "the shipped schema marks exactly the day-partitioned rollups as needing partitioned tables" do
    waiting =
      Schema.migrations()
      |> Enum.filter(&Schema.needs_partitioned_tables?/1)
      |> Enum.map(& &1.version)

    # 17 and 22 are the earlier rollups; 25 and 28 create the MTR rollups; 40
    # rebuilds all of them with one bucket per day; 41 recreates the two span
    # rollups after widening the span columns.
    assert waiting == [17, 22, 25, 28, 40, 41]
  end
end
