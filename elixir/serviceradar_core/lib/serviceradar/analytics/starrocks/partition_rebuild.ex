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

  The rollups are gone only for step 2, which is short, and migration 0017
  recreates them as soon as this returns. It is necessarily still pending: its
  partitioned views cannot exist over a table this module has yet to rebuild.

  Nothing here is recorded in the ledger. Every run reads what the warehouse
  holds and continues from there. A day is one atomic INSERT, so a copy that
  was interrupted keeps the days it finished and resumes with the rest, rather
  than starting a large table again from nothing on every retry. A swap whose
  catch-up never ran gets its catch-up.

  The anti-joined catch-up is what makes the result complete; skipping days
  already copied is only an economy. It carries anything written to the old
  table at any point before the swap, whatever its timestamp. CNPG receives
  every write throughout, so the one thing it cannot carry -- a partial update
  to an already copied row in the moments before the swap -- is not lost to
  the deployment.

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
         {:ok, plans} <- plan(state, retention, layout),
         :ok <- each(plans, &copy(state, &1)) do
      each(plans, &cut_over(state, &1))
    end
  end

  defp each(plans, fun) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      case fun.(plan) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:partition_rebuild, plan.spec.table, reason}}}
      end
    end)
  end

  defp plan(state, retention, layout) do
    Enum.reduce_while(retention, {:ok, []}, fn {table, days}, {:ok, plans} ->
      case step(Map.get(layout, table), Map.get(layout, table <> @suffix)) do
        :nothing ->
          {:cont, {:ok, plans}}

        {:error, reason} ->
          {:halt, {:error, {:partition_rebuild, table, reason}}}

        step ->
          case spec(state, table, days) do
            {:ok, spec} -> {:cont, {:ok, plans ++ [%{step: step, spec: spec, days: days}]}}
            {:error, reason} -> {:halt, {:error, {:partition_rebuild, table, reason}}}
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
      Enum.reduce_while(wanted -- done, :ok, fn day, :ok ->
        case exec(state, copy_day_sql(state, spec, columns, day)) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:copy, day, reason}}}
        end
      end)
    end
  end

  defp cut_over(state, %{step: :rebuild, spec: spec} = plan) do
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

  # A load already in flight at the swap commits to the old table a moment
  # later, so one pass is not enough; the pause lets those land first.
  defp catch_up(_state, _spec, _columns, _days, 0), do: :ok

  defp catch_up(state, spec, columns, days, passes_left) do
    with :ok <- exec(state, catch_up_sql(state, spec, columns, days)) do
      if passes_left > 1, do: state.sleep.(@catch_up_pause_ms)
      catch_up(state, spec, columns, days, passes_left - 1)
    end
  end

  @doc false
  @spec copy_day_sql(state(), map(), [String.t()], String.t()) :: String.t()
  def copy_day_sql(state, spec, columns, day) do
    list = column_list(columns)
    column = "`#{spec.time_column}`"

    "INSERT INTO #{qualified(state, spec.copy)} (#{list}) SELECT #{list} FROM #{qualified(state, spec.table)} " <>
      "WHERE #{column} >= '#{day} 00:00:00' AND #{column} < DATE_ADD('#{day} 00:00:00', INTERVAL 1 DAY)"
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

  # The days, newest first, on which a table holds rows inside retention.
  defp days_in(state, table, time_column, days) do
    column = "`#{time_column}`"

    sql =
      "SELECT DISTINCT date_trunc('day', #{column}) FROM #{qualified(state, table)} " <>
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

  defp qualified(state, table), do: "#{state.database}.#{table}"

  defp blank?(nil), do: true
  defp blank?(value), do: value |> to_string() |> String.trim() == ""
end
