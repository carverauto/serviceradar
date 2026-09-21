defmodule ServiceRadar.Analytics.StarRocks.PartitionRebuild do
  @moduledoc """
  Moves a telemetry table created before daily partitioning onto the
  partitioned definition, while the warehouse keeps serving and taking writes.

  StarRocks can neither add partitioning to a table nor change its primary key
  with ALTER, so an old table is rebuilt beside itself and swapped in:

    1. drop the table's hourly rollup, which a swap would leave inactive
    2. create `<table>__rebuild` from the shipped, partitioned CREATE
    3. copy the rows still inside retention into it
    4. `ALTER TABLE <table> SWAP WITH <table>__rebuild`, which is atomic
    5. copy across whatever reached the old table after step 3 began
    6. recreate the rollup, then drop the old table

  Nothing here is recorded in the ledger. Every run reads what the warehouse
  actually holds and continues from there, so a core that dies at any step is
  resumed by the next one to start: a half-filled copy is discarded and begun
  again, and a swap whose catch-up never ran gets its catch-up.

  Readers are unaffected except for speed. Between steps 1 and 6 the rollup is
  missing, which `RollupFreshness` reads as stale and answers from the raw
  table. CNPG keeps receiving every write throughout, so the one thing the
  catch-up cannot carry -- a partial update applied to an already copied row
  in the seconds before the swap -- is not lost to the deployment.

  The copy is bounded to the retention window on purpose. A table that was
  never partitioned has never expired anything, and a single row with a
  nonsense timestamp would otherwise become a partition of its own.
  """

  alias ServiceRadar.Analytics.StarRocks.Retention
  alias ServiceRadar.Analytics.StarRocks.Schema

  require Logger

  @suffix "__rebuild"
  @catch_up_passes 2
  @catch_up_pause_ms 5_000
  @future_slack_days 1

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
  def run(%{database: database} = state) do
    retention = Map.get_lazy(state, :retention_days, &Retention.days_by_table/0)

    with {:ok, layout} <- layout(state) do
      Enum.reduce_while(retention, :ok, fn {table, days}, :ok ->
        case rebuild(
               state,
               table,
               days,
               Map.get(layout, table),
               Map.get(layout, table <> @suffix)
             ) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:partition_rebuild, "#{database}.#{table}", reason}}}
        end
      end)
    end
  end

  # No such table: a fresh warehouse, which the shipped CREATE partitions.
  defp rebuild(_state, _table, _days, nil, _old), do: :ok

  defp rebuild(_state, _table, _days, :partitioned, nil), do: :ok

  # Swapped, but the run that swapped it did not live to finish.
  defp rebuild(state, table, days, :partitioned, :unpartitioned) do
    with {:ok, spec} <- spec(state, table) do
      Logger.info("Resuming StarRocks partition rebuild of #{table} after its swap")
      finish(state, spec, days)
    end
  end

  defp rebuild(_state, table, _days, :partitioned, :partitioned) do
    Logger.warning(
      "StarRocks tables #{table} and #{table}#{@suffix} are both partitioned; leaving both alone"
    )

    :ok
  end

  defp rebuild(state, table, days, :unpartitioned, _half_built_copy) do
    with {:ok, spec} <- spec(state, table) do
      Logger.info("Rebuilding StarRocks table #{table} with daily partitions (#{days} days kept)")

      with :ok <- exec(state, "DROP MATERIALIZED VIEW IF EXISTS #{rollup(state, table)}"),
           :ok <- exec(state, "DROP TABLE IF EXISTS #{qualified(state, spec.copy)} FORCE"),
           :ok <- exec(state, spec.create_copy),
           {:ok, columns} <- shared_columns(state, table, spec.copy),
           :ok <- exec(state, copy_sql(state, spec, columns, days)),
           :ok <- exec(state, "ALTER TABLE #{qualified(state, table)} SWAP WITH #{spec.copy}") do
        finish(state, spec, days)
      end
    end
  end

  # After the swap `spec.copy` names the OLD table, and `spec.table` the new one.
  defp finish(state, spec, days) do
    with {:ok, columns} <- shared_columns(state, spec.copy, spec.table),
         :ok <- catch_up(state, spec, columns, days, @catch_up_passes),
         :ok <- recreate_rollup(state, spec.table),
         :ok <- exec(state, "DROP TABLE IF EXISTS #{qualified(state, spec.copy)} FORCE") do
      Logger.info("StarRocks table #{spec.table} is now partitioned by day")
      :ok
    end
  end

  # A load already in flight at the swap commits to the old table a moment
  # later, so one pass is not enough; the pause lets those land first.
  defp catch_up(_state, _spec, _columns, _days, 0), do: :ok

  defp catch_up(state, spec, columns, days, passes_left) do
    with :ok <- exec(state, catch_up_sql(state, spec, columns, days)) do
      if passes_left > 1, do: state.sleep.(@catch_up_pause_ms)
      catch_up(state, spec, columns, days, passes_left - 1)
    end
  end

  defp recreate_rollup(state, table) do
    name = "#{table}_hourly"
    pattern = ~r/^CREATE\s+MATERIALIZED\s+VIEW\s+IF\s+NOT\s+EXISTS\s+\S+\.#{name}\s/i

    case last_statement(state, pattern) do
      nil -> :ok
      statement -> exec(state, Schema.retarget(statement, state.database, state.replication_num))
    end
  end

  @doc false
  @spec copy_sql(state(), map(), [String.t()], pos_integer()) :: String.t()
  def copy_sql(state, spec, columns, days) do
    list = column_list(columns)

    "INSERT INTO #{qualified(state, spec.copy)} (#{list}) SELECT #{list} FROM #{qualified(state, spec.table)} " <>
      "WHERE #{window(spec.time_column, days)}"
  end

  @doc false
  @spec catch_up_sql(state(), map(), [String.t()], pos_integer()) :: String.t()
  def catch_up_sql(state, spec, columns, days) do
    on = Enum.map_join(spec.keys, " AND ", &"o.`#{&1}` = n.`#{&1}`")

    "INSERT INTO #{qualified(state, spec.table)} (#{column_list(columns)}) " <>
      "SELECT #{column_list(columns, "o.")} FROM #{qualified(state, spec.copy)} o " <>
      "LEFT ANTI JOIN #{qualified(state, spec.table)} n ON #{on} " <>
      "WHERE #{window("o.`#{spec.time_column}`", days)}"
  end

  defp window("o." <> _ = column, days), do: window_on(column, days)
  defp window(column, days), do: window_on("`#{column}`", days)

  defp window_on(column, days) do
    "#{column} >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL #{days} DAY) " <>
      "AND #{column} < DATE_ADD(UTC_TIMESTAMP(), INTERVAL #{@future_slack_days} DAY)"
  end

  defp column_list(columns, prefix \\ ""), do: Enum.map_join(columns, ", ", &"#{prefix}`#{&1}`")

  # The partitioned definition is whatever this release ships, read out of the
  # same migrations a fresh warehouse is built from, so the two cannot drift.
  defp spec(state, table) do
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
          "\\1#{copy}", global: false)

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

  # Copy by name, and only what both sides have: a warehouse that stopped
  # upgrading a few versions back lacks the newest columns, and the migrations
  # that add them run after this and find them already there.
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

  defp rollup(state, table), do: qualified(state, "#{table}_hourly")
  defp qualified(state, table), do: "#{state.database}.#{table}"

  defp blank?(nil), do: true
  defp blank?(value), do: value |> to_string() |> String.trim() == ""
end
