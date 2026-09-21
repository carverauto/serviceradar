defmodule ServiceRadar.Analytics.StarRocks.PartitionRebuild do
  @moduledoc """
  Moves telemetry tables created before daily partitioning onto the partitioned
  definition, while the warehouse keeps serving and taking writes.

  StarRocks can neither add partitioning to a table nor change its primary key
  with ALTER, so an old table is rebuilt beside itself and swapped in. The work
  is ordered so that the slow part disturbs nothing:

    1. For every old table, create `<table>__rebuild` from the shipped CREATE
       and copy the rows still inside retention into it, one day a statement.
       Readers, writers and rollups all still use the old table.
    2. Then, table by table: drop its hourly rollup (a swap would leave it
       inactive), `ALTER TABLE <table> SWAP WITH <table>__rebuild`, copy across
       whatever the old table has that the new one lacks, drop the old table.

  The rollups are gone only for step 2, and migration 0017 recreates them as
  soon as this returns. It is necessarily still pending: its partitioned views
  cannot exist over a table this module has yet to rebuild. Step 2 runs two
  day-bounded anti-join passes per held day, so on a long retention it is
  minutes, not seconds.

  Every table is copied before any old table is dropped, so peak storage is
  about twice the in-retention warehouse. That is the price of keeping the
  rollups alive through the copy, and a warehouse without the room fails its
  copies on every retry until it has some.

  A table that fails is left alone, rollup included, and does not keep the
  others unpartitioned. It does keep 0017 pending, though, so when any table
  fails, the tables that did cut over get their hourly rollup back here, from
  the newest definition this release ships. A day-partitioned rollup is valid
  over a partitioned base table whatever state the other tables are in. With
  no failure nothing is recreated: 0017 runs next and would discard the work.

  Nothing here is recorded in the ledger. Every run reads what the warehouse
  holds and continues from there. A day is one atomic INSERT, so a copy that
  was interrupted keeps the days it finished and resumes with the rest, rather
  than starting a large table again from nothing on every retry. A swap whose
  catch-up never ran gets its catch-up.

  Two things keep the result complete. Rows written to the old table after
  their day was copied are carried by the catch-up, an anti-join on the new
  key run a day at a time so both sides prune to one partition. Rows that were
  copied and then CHANGED -- flow attribution rewrites recent flows in place --
  are carried by copying the most recent days again immediately before the
  swap, while nothing else writes the new table and an upsert of whole days is
  therefore safe. What is left is an update landing in the moments between
  that last copy and the swap, and CNPG receives every write throughout, so
  even that is not lost to the deployment.

  The copy is bounded to the retention window on purpose. A table that was
  never partitioned has never expired anything, and a single row with a
  nonsense timestamp would otherwise become a partition of its own. The copy
  is created with the operator's retention, not the DDL default, so StarRocks
  does not expire the far end of a longer window while it is being filled.
  """

  alias ServiceRadar.Analytics.StarRocks.Retention
  alias ServiceRadar.Analytics.StarRocks.Schema

  require Logger

  @suffix "__rebuild"
  @catch_up_passes 2
  @catch_up_pause_ms 5_000
  @future_slack_days 1
  # Days copied again just before the swap, for rows updated in place since
  # they were first copied. In-place updates are attribution, minutes behind
  # the flow itself; two days is generous and still one short statement each.
  @refresh_days 2
  # Listing a table's days scans the time column of an unpartitioned table
  # whose key does not prune it. A SELECT is bounded by the server's
  # query_timeout (300s by default), not insert_timeout, so without a ceiling
  # of its own a large table fails the same way on every retry. Four hours
  # matches what the copy statements are allowed.
  @scan_timeout_s 14_400

  @type state :: %{
          required(:query) => (String.t() -> {:ok, map()} | {:error, term()}),
          required(:database) => String.t(),
          required(:replication_num) => pos_integer(),
          required(:migrations) => [Schema.migration()],
          required(:sleep) => (non_neg_integer() -> term()),
          optional(:retention_days) => [{String.t(), pos_integer()}]
        }

  @doc "Rebuilds every telemetry table that is still unpartitioned."
  @spec run(state()) :: :ok | {:error, term()}
  def run(state) do
    retention = Map.get_lazy(state, :retention_days, &Retention.days_by_table/0)

    with {:ok, layout} <- layout(state),
         {:ok, plans} <- plan(state, retention, layout) do
      {copied, copy_failures} = attempt(plans, &copy(state, &1))
      {cut_over, cut_over_failures} = attempt(copied, &cut_over(state, &1))

      case copy_failures ++ cut_over_failures do
        [] ->
          :ok

        failures ->
          {_restored, rollup_failures} = attempt(cut_over, &restore_rollup(state, &1))
          {:error, {:partition_rebuild, failures ++ rollup_failures}}
      end
    end
  end

  # One table that cannot be rebuilt must not keep the others unpartitioned.
  defp attempt(plans, fun) do
    Enum.reduce(plans, {[], []}, fn plan, {done, failures} ->
      case fun.(plan) do
        :ok ->
          {done ++ [plan], failures}

        {:error, reason} ->
          Logger.error(
            "StarRocks partition rebuild of #{plan.spec.table} failed: #{inspect(reason)}"
          )

          {done, failures ++ [{plan.spec.table, reason}]}
      end
    end)
  end

  defp plan(state, retention, layout) do
    Enum.reduce_while(retention, {:ok, []}, fn {table, days}, {:ok, plans} ->
      case step(Map.get(layout, table), Map.get(layout, table <> @suffix)) do
        :nothing ->
          {:cont, {:ok, plans}}

        {:error, reason} ->
          {:halt, {:error, {:partition_rebuild, [{table, reason}]}}}

        step ->
          case spec(state, table, days) do
            {:ok, spec} -> {:cont, {:ok, plans ++ [%{step: step, spec: spec, days: days}]}}
            {:error, reason} -> {:halt, {:error, {:partition_rebuild, [{table, reason}]}}}
          end
      end
    end)
  end

  # (the table, its `__rebuild` sibling) -> what is left to do.
  # No such table is a fresh warehouse, which the shipped CREATE partitions.
  defp step(nil, _copy), do: :nothing
  defp step(:partitioned, nil), do: :nothing
  defp step(:unpartitioned, nil), do: :rebuild
  # A copy some earlier run began. Its finished days are kept.
  defp step(:unpartitioned, :partitioned), do: :rebuild
  # Swapped, but the run that swapped it did not live to finish.
  defp step(:partitioned, :unpartitioned), do: :finish
  # Neither arrangement is one this module produces, so it does not guess.
  defp step(_table, _copy), do: {:error, :unexpected_layout}

  defp copy(_state, %{step: :finish}), do: :ok

  defp copy(state, %{spec: spec, days: days}) do
    Logger.info("Copying StarRocks table #{spec.table} onto daily partitions (#{days} days kept)")

    with :ok <- exec(state, spec.create_copy),
         {:ok, columns} <- shared_columns(state, spec.table, spec.copy),
         {:ok, wanted} <- days_in(state, spec.table, spec.time_column, days),
         {:ok, done} <- days_in(state, spec.copy, spec.time_column, days) do
      copy_days(state, spec, columns, wanted -- done)
    end
  end

  defp copy_days(state, spec, columns, days) do
    Enum.reduce_while(days, :ok, fn day, :ok ->
      case exec(state, copy_day_sql(state, spec, columns, day)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:copy, day, reason}}}
      end
    end)
  end

  defp cut_over(state, %{step: :rebuild, spec: spec, days: days} = plan) do
    with {:ok, columns} <- shared_columns(state, spec.table, spec.copy),
         {:ok, recent} <- days_in(state, spec.table, spec.time_column, days),
         :ok <- copy_days(state, spec, columns, Enum.take(recent, @refresh_days)),
         {:ok, layout} <- layout(state) do
      # The plan is hours old by now, and SWAP is symmetric: issued by a runner
      # that lost the migration lock while another finished the job, it would
      # put the unpartitioned table back. What the warehouse says NOW decides.
      case {Map.get(layout, spec.table), Map.get(layout, spec.copy)} do
        {:unpartitioned, :partitioned} -> swap(state, plan)
        {:partitioned, :unpartitioned} -> cut_over(state, %{plan | step: :finish})
        _other -> {:error, :unexpected_layout}
      end
    end
  end

  defp swap(state, %{spec: spec} = plan) do
    with :ok <-
           exec(state, "DROP MATERIALIZED VIEW IF EXISTS #{qualified(state, spec.table)}_hourly"),
         :ok <- exec(state, "ALTER TABLE #{qualified(state, spec.table)} SWAP WITH #{spec.copy}") do
      cut_over(state, %{plan | step: :finish})
    end
  end

  # From here `spec.copy` names the OLD table, and `spec.table` the new one.
  defp cut_over(state, %{step: :finish, spec: spec, days: days}) do
    with {:ok, columns} <- shared_columns(state, spec.copy, spec.table),
         :ok <- catch_up(state, spec, columns, days, @catch_up_passes),
         :ok <- exec(state, "DROP TABLE IF EXISTS #{qualified(state, spec.copy)} FORCE") do
      Logger.info("StarRocks table #{spec.table} is now partitioned by day")
      :ok
    end
  end

  # Only reached when some other table failed, which keeps the migration that
  # owns the rollups pending. A table without one (logs) has nothing to restore.
  defp restore_rollup(state, %{spec: spec}) do
    pattern =
      ~r/^CREATE\s+MATERIALIZED\s+VIEW\s+IF\s+NOT\s+EXISTS\s+\S+\.#{spec.table}_hourly\b/i

    case last_statement(state, pattern) do
      nil -> :ok
      statement -> exec(state, Schema.retarget(statement, state.database, state.replication_num))
    end
  end

  # A load already in flight at the swap commits to the old table a moment
  # later, so one pass is not enough; the pause lets those land first.
  defp catch_up(_state, _spec, _columns, _days, 0), do: :ok

  defp catch_up(state, spec, columns, days, passes_left) do
    with {:ok, old_days} <- days_in(state, spec.copy, spec.time_column, days),
         :ok <- catch_up_days(state, spec, columns, old_days) do
      if passes_left > 1, do: state.sleep.(@catch_up_pause_ms)
      catch_up(state, spec, columns, days, passes_left - 1)
    end
  end

  defp catch_up_days(state, spec, columns, days) do
    Enum.reduce_while(days, :ok, fn day, :ok ->
      case exec(state, catch_up_day_sql(state, spec, columns, day)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:catch_up, day, reason}}}
      end
    end)
  end

  @doc false
  @spec copy_day_sql(state(), map(), [String.t()], String.t()) :: String.t()
  def copy_day_sql(state, spec, columns, day) do
    list = column_list(columns)

    "INSERT INTO #{qualified(state, spec.copy)} (#{list}) SELECT #{list} FROM #{qualified(state, spec.table)} " <>
      "WHERE #{on_day("`#{spec.time_column}`", day)}"
  end

  # The day bounds both sides, so each reads one partition instead of joining
  # the whole of one table to the whole of the other.
  @doc false
  @spec catch_up_day_sql(state(), map(), [String.t()], String.t()) :: String.t()
  def catch_up_day_sql(state, spec, columns, day) do
    on = Enum.map_join(spec.keys, " AND ", &"o.`#{&1}` = n.`#{&1}`")

    "INSERT INTO #{qualified(state, spec.table)} (#{column_list(columns)}) " <>
      "SELECT #{column_list(columns, "o.")} FROM #{qualified(state, spec.copy)} o " <>
      "LEFT ANTI JOIN #{qualified(state, spec.table)} n ON #{on} AND #{on_day("n.`#{spec.time_column}`", day)} " <>
      "WHERE #{on_day("o.`#{spec.time_column}`", day)}"
  end

  defp on_day(column, day) do
    "#{column} >= '#{day} 00:00:00' AND #{column} < DATE_ADD('#{day} 00:00:00', INTERVAL 1 DAY)"
  end

  # The days, newest first, on which a table holds rows inside retention.
  defp days_in(state, table, time_column, days) do
    column = "`#{time_column}`"

    sql =
      "SELECT /*+ SET_VAR(query_timeout = #{@scan_timeout_s}) */ DISTINCT " <>
        "date_trunc('day', #{column}) FROM #{qualified(state, table)} " <>
        "WHERE #{window(column, days)} ORDER BY 1 DESC"

    case state.query.(sql) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [day | _] -> day |> to_string() |> String.slice(0, 10) end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp window(column, days) do
    "#{column} >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL #{days} DAY) " <>
      "AND #{column} < DATE_ADD(UTC_TIMESTAMP(), INTERVAL #{@future_slack_days} DAY)"
  end

  defp column_list(columns, prefix \\ ""), do: Enum.map_join(columns, ", ", &"#{prefix}`#{&1}`")

  # The partitioned definition is whatever this release ships, read out of the
  # same migrations a fresh warehouse is built from, so the two cannot drift.
  defp spec(state, table, days) do
    pattern = ~r/^CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+\S+\.#{table}\s*\(/i

    with statement when is_binary(statement) <- last_statement(state, pattern),
         [_, time_column] <-
           Regex.run(~r/PARTITION\s+BY\s+date_trunc\('day',\s*`?(\w+)`?\)/i, statement),
         [_, keys] <- Regex.run(~r/PRIMARY\s+KEY\s*\(([^)]+)\)/i, statement) do
      copy = table <> @suffix

      create_copy =
        statement
        |> Schema.retarget(state.database, state.replication_num)
        |> String.replace(
          ~r/(CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+\S+\.)#{table}\b/i,
          "\\1#{copy}",
          global: false
        )
        |> String.replace(
          ~r/"partition_live_number"\s*=\s*"\d+"/,
          ~s("partition_live_number" = "#{days}")
        )

      {:ok,
       %{
         table: table,
         copy: copy,
         create_copy: create_copy,
         time_column: time_column,
         keys: keys |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.trim("`")))
       }}
    else
      _ -> {:error, :no_partitioned_definition}
    end
  end

  defp last_statement(state, pattern) do
    state.migrations
    |> Enum.flat_map(& &1.statements)
    |> Enum.filter(&Regex.match?(pattern, &1))
    |> List.last()
  end

  defp layout(state) do
    sql =
      "SELECT TABLE_NAME, PARTITION_KEY FROM information_schema.tables_config " <>
        "WHERE TABLE_SCHEMA = '#{state.database}'"

    case state.query.(sql) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Map.new(rows, fn [table, partition_key | _] ->
           {to_string(table), if(blank?(partition_key), do: :unpartitioned, else: :partitioned)}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Copy by name, and only what both sides have. Migrations ahead of the first
  # one that needs partitioned tables run BEFORE this, so an up-to-date release
  # finds the same columns on both sides. The intersection is for a warehouse
  # that is behind in some way those did not repair, and for a column a future
  # release adds to the shipped CREATE in a migration that runs after this.
  defp shared_columns(state, from, to) do
    with {:ok, from_columns} <- columns(state, from),
         {:ok, to_columns} <- columns(state, to) do
      case Enum.filter(from_columns, &(&1 in to_columns)) do
        [] -> {:error, {:no_shared_columns, from, to}}
        shared -> {:ok, shared}
      end
    end
  end

  defp columns(state, table) do
    sql =
      "SELECT COLUMN_NAME FROM information_schema.columns WHERE table_schema = '#{state.database}' " <>
        "AND table_name = '#{table}' ORDER BY ORDINAL_POSITION"

    case state.query.(sql) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [column | _] -> to_string(column) end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exec(state, sql) do
    case state.query.(sql) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp qualified(state, table), do: "#{state.database}.#{table}"

  defp blank?(nil), do: true
  defp blank?(value), do: value |> to_string() |> String.trim() == ""
end
