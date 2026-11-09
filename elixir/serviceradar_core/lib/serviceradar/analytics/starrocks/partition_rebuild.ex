defmodule ServiceRadar.Analytics.StarRocks.PartitionRebuild do
  @moduledoc """
  Moves telemetry tables onto the layout their shipped CREATE declares, while
  the warehouse keeps serving and taking writes. A table is outdated when it
  is not partitioned by day (created before daily partitioning), or when the
  shipped CREATE names a sort key (`ORDER BY`) the table does not have.

  StarRocks can neither add partitioning to a table nor change its primary key
  with ALTER, so an old table is rebuilt beside itself and swapped in. A sort
  key it can change with ALTER, but only by rewriting every tablet in one
  job, and a compute node with little headroom cancels that job for a large
  table -- as it cancelled 0039's whole-day bucket rewrites of the metrics
  table. A sort key change therefore takes the same hour-bounded path. The
  work is ordered so that the slow part disturbs nothing:

    1. For every old table, create `<table>__rebuild` from the shipped CREATE
       and copy the rows still inside retention into it, one hour a statement.
       Readers, writers and rollups all still use the old table.
    2. Then, table by table: drop its hourly rollup (a swap would leave it
       inactive), `ALTER TABLE <table> SWAP WITH <table>__rebuild`, copy across
       whatever the old table has that the new one lacks, drop the old table.

  The rollups are gone only for step 2. Once every cut-over is done, each
  retained table that has its shipped layout and no old table left beside it
  gets back a missing rollup, from the newest definition this release ships
  and the ALTERs that follow it (its refresh schedule); a rollup that exists
  but was left without that schedule gets the ALTERs alone. This is read from
  the warehouse on every run, so a run that stopped between the swap and the
  restore, or between a rollup's CREATE and its ALTER, is finished by the next
  one. On a warehouse that predates partitioning 0017 is still pending and
  replaces that rollup again, which costs a backfill and nothing else. Step 2
  runs two hour-bounded anti-join passes per held hour, so on a long retention
  it is minutes, not seconds.

  The unit of work is an hour, not the day a partition holds. A day of a
  large metrics table is more than a modest compute node can hold in memory,
  for the copy and for the anti-join alike, and a node that runs out is killed
  and takes every other query it was serving with it. An hour is a
  twenty-fourth of that, and a small table merely runs more, cheap, statements.

  Every table is copied before any old table is dropped, so peak storage is
  about twice the in-retention warehouse. That is the price of keeping the
  rollups alive through the copy, and a warehouse without the room fails its
  copies on every retry until it has some.

  A table whose copy fails is left alone, rollup included, and does not keep
  the others unpartitioned. The rollups of the others are restored all the
  same: a day-partitioned rollup is valid over a partitioned base table
  whatever state the other tables are in.

  Nothing here is recorded in the ledger. Every run reads what the warehouse
  holds and continues from there. An hour is one atomic INSERT, and what is
  done is read back by the hour too, so a copy that was interrupted keeps the
  hours it finished and resumes with the rest -- a day half copied is not
  mistaken for a day done -- rather than starting a large table again from
  nothing on every retry. A swap whose catch-up never ran gets its catch-up.

  Two things keep the result complete. Rows written to the old table after
  their hour was copied are carried by the catch-up, an anti-join on the new
  key run an hour at a time so both sides prune to one partition and read one
  hour of it. Rows that were copied and then CHANGED -- flow attribution
  rewrites recent flows in place -- are carried by copying the hours of the
  most recent days again immediately before the swap, while nothing else
  writes the new table and an upsert of whole hours is therefore safe.

  Two gaps are left, both narrow. One is an in-place update landing between
  that last copy and the swap: it reaches the old table and is not carried.
  The other is its mirror image: a flow written to the old table after its hour
  was last copied, whose attribution -- a partial update by key -- reaches the
  NEW table before the catch-up has brought the flow across. The catch-up is
  an anti-join on the key, so it would then take the key as present. The most
  recent days are therefore caught up in the very next statements after the
  swap, from the columns and hours already in hand, which leaves that gap the
  instant between the swap and the first of them rather than a scan of the old
  table. CNPG receives every write throughout, so neither is lost to the
  deployment.

  The migrator's lock can be lost while this runs: it is a PostgreSQL
  transaction, and the rebuild is hours of StarRocks work. `:still_locked` is
  called before every statement and raises once the lock is gone, so a runner
  that lost it stops before its next statement and leaves the tables to
  whoever holds the lock now. The statement in flight at that moment still
  completes; for an hour copy that is an upsert of rows the old table holds,
  which the other runner's copy of the same hour merely repeats.

  The copy is bounded to the retention window on purpose. A table that was
  never partitioned has never expired anything, and a single row with a
  nonsense timestamp would otherwise become a partition of its own. The copy
  is created with the operator's retention, not the DDL default, so StarRocks
  does not expire most of a longer window while it is being filled. The window
  spans up to two calendar days more than `partition_live_number` counts
  partitions, so StarRocks may expire the oldest one or two copied partitions
  and a retry copy them again. That is retention working, not loss.
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
  # the flow itself; two days is generous, and still one hour a statement.
  @refresh_days 2
  # How often a long copy or catch-up says how much is left, in hours done.
  @progress_every 24
  # Listing a table's hours is one statement a day, so a partitioned table
  # prunes each to one partition; an unpartitioned table whose key does not
  # prune it is scanned for its time column. A SELECT is bounded by the server's
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
          optional(:still_locked) => (-> :ok),
          optional(:retention_days) => [{String.t(), pos_integer()}]
        }

  @doc "Rebuilds every telemetry table whose layout is not the shipped one."
  @spec run(state()) :: :ok | {:error, term()}
  def run(state) do
    retention = Map.get_lazy(state, :retention_days, &Retention.days_by_table/0)

    with {:ok, layout} <- layout(state),
         {:ok, plans} <- plan(state, retention, layout) do
      {copied, copy_failures} = attempt(plans, &copy(state, &1))
      {_cut_over, cut_over_failures} = attempt(copied, &cut_over(state, &1))

      case copy_failures ++ cut_over_failures ++ restore_rollups(state, retention) do
        [] -> :ok
        failures -> {:error, {:partition_rebuild, failures}}
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
  # No such table is a fresh warehouse, which the shipped CREATE lays out.
  defp step(nil, _copy), do: :nothing
  defp step(:current, nil), do: :nothing
  defp step(:current, :current), do: {:error, :unexpected_layout}
  # Swapped, but the run that swapped it did not live to finish.
  defp step(:current, _old), do: :finish
  # Swapped by a release that shipped an older sort key, and not finished
  # either. Finished first; the next run moves it onto the shipped sort key.
  defp step(:unsorted, :unpartitioned), do: :finish
  defp step(_outdated, nil), do: :rebuild
  # A copy some earlier run began. Its finished days are kept.
  defp step(_outdated, :current), do: :rebuild
  # A copy an earlier release began from an older CREATE. The table it was
  # copying was never partitioned, so it was never swapped in and holds
  # nothing the table lacks.
  defp step(:unpartitioned, :unsorted), do: :discard_copy
  # Neither arrangement is one this module produces, so it does not guess.
  defp step(_table, _copy), do: {:error, :unexpected_layout}

  defp copy(_state, %{step: :finish}), do: :ok

  defp copy(state, %{step: :discard_copy, spec: spec} = plan) do
    with :ok <- exec(state, "DROP TABLE IF EXISTS #{qualified(state, spec.copy)} FORCE") do
      copy(state, %{plan | step: :rebuild})
    end
  end

  defp copy(state, %{spec: spec, days: days}) do
    Logger.info(
      "Copying StarRocks table #{spec.table} onto its shipped layout (#{days} days kept)"
    )

    with :ok <- exec(state, spec.create_copy),
         {:ok, columns} <- shared_columns(state, spec.table, spec.copy),
         {:ok, wanted} <- hours_in(state, spec.table, spec.time_column, days),
         {:ok, done} <- hours_in(state, spec.copy, spec.time_column, days) do
      copy_hours(state, spec, columns, wanted -- done)
    end
  end

  defp copy_hours(state, spec, columns, hours) do
    each_hour(spec, :copy, hours, &exec(state, copy_hour_sql(state, spec, columns, &1)))
  end

  # One bounded statement per hour, stopping at the first that fails. The
  # count left is logged as it goes, so a rebuild that takes hours shows its
  # progress rather than only its retries.
  defp each_hour(_spec, _phase, [], _fun), do: :ok

  defp each_hour(spec, phase, hours, fun) do
    total = length(hours)
    Logger.info("StarRocks #{phase} of #{spec.table}: #{total} hours to go")

    hours
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {hour, done}, :ok ->
      case fun.(hour) do
        :ok ->
          if rem(done, @progress_every) == 0 and done < total do
            Logger.info(
              "StarRocks #{phase} of #{spec.table}: #{total - done} of #{total} hours left"
            )
          end

          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {phase, hour, reason}}}
      end
    end)
  end

  defp cut_over(state, %{step: step, spec: spec, days: days} = plan)
       when step in [:rebuild, :discard_copy] do
    with {:ok, columns} <- shared_columns(state, spec.table, spec.copy),
         {:ok, held} <- hours_in(state, spec.table, spec.time_column, days),
         recent = newest_days(held, @refresh_days),
         :ok <- copy_hours(state, spec, columns, recent),
         {:ok, layout} <- layout(state) do
      # The plan is hours old by now, and SWAP is symmetric: issued by a runner
      # that lost the migration lock while another finished the job, it would
      # put the unpartitioned table back. What the warehouse says NOW decides.
      case {Map.get(layout, spec.table), Map.get(layout, spec.copy)} do
        {old, :current} when old != :current -> swap(state, plan, columns, recent)
        {:current, old} when old != :current -> cut_over(state, %{plan | step: :finish})
        _other -> {:error, :unexpected_layout}
      end
    end
  end

  # From here `spec.copy` names the OLD table, and `spec.table` the new one.
  defp cut_over(state, %{step: :finish, spec: spec, days: days}) do
    with {:ok, columns} <- shared_columns(state, spec.copy, spec.table),
         :ok <- catch_up(state, spec, columns, days, @catch_up_passes),
         :ok <- exec(state, "DROP TABLE IF EXISTS #{qualified(state, spec.copy)} FORCE") do
      Logger.info("StarRocks table #{spec.table} now has its shipped layout")
      :ok
    end
  end

  # Attribution reaches a recent flow minutes after the flow itself, and once
  # swapped it lands on the new table. The days it touches are caught up before
  # anything is asked of the warehouse, with what the refresh already knew.
  defp swap(state, %{spec: spec} = plan, columns, recent) do
    with :ok <-
           exec(state, "DROP MATERIALIZED VIEW IF EXISTS #{qualified(state, spec.table)}_hourly"),
         :ok <- exec(state, "ALTER TABLE #{qualified(state, spec.table)} SWAP WITH #{spec.copy}"),
         :ok <- catch_up_hours(state, spec, columns, recent) do
      cut_over(state, %{plan | step: :finish})
    end
  end

  # Every retained table that has its shipped layout and has finished with its
  # old table gets what its rollup still lacks: the whole of it when it is
  # missing, its ALTERs when it exists but never got the refresh schedule they
  # give it. A table without a shipped rollup (logs, MTR) has nothing to
  # restore, and is skipped rather than sent an empty statement.
  defp restore_rollups(state, retention) do
    retention
    |> Enum.flat_map(fn {table, _days} ->
      case rollup_statements(state, table) do
        nil -> []
        statements -> [{table, statements}]
      end
    end)
    |> restore_missing_rollups(state)
  end

  defp restore_missing_rollups([], _state), do: []

  defp restore_missing_rollups(rollups, state) do
    with {:ok, layout} <- layout(state),
         {:ok, views} <- refresh_types(state) do
      for {table, statements} <- rollups,
          Map.get(layout, table) == :current,
          not Map.has_key?(layout, table <> @suffix),
          pending = pending_rollup(statements, Map.get(views, table <> "_hourly", :missing)),
          pending != [],
          {:error, reason} <- [exec_all(state, pending)] do
        Logger.error("StarRocks rollup of #{table} could not be restored: #{inspect(reason)}")
        {table, {:rollup, reason}}
      end
    else
      {:error, reason} ->
        Logger.error("StarRocks rollups could not be restored: #{inspect(reason)}")
        [{:rollups, reason}]
    end
  end

  # A view is never created again over itself. One created REFRESH DEFERRED
  # MANUAL whose ALTER never ran reports MANUAL, and gets that ALTER.
  defp pending_rollup({create, alters}, :missing), do: [create | alters]

  defp pending_rollup({_create, alters}, "MANUAL") do
    if Enum.any?(alters, &(&1 =~ ~r/\bREFRESH\s+ASYNC\b/i)), do: alters, else: []
  end

  defp pending_rollup(_statements, _refresh_type), do: []

  defp refresh_types(state) do
    sql =
      "SELECT TABLE_NAME, REFRESH_TYPE FROM information_schema.materialized_views " <>
        "WHERE TABLE_SCHEMA = '#{state.database}'"

    case query(state, sql) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Map.new(rows, fn [view, refresh_type | _] ->
           {to_string(view), refresh_type |> to_string() |> String.trim() |> String.upcase()}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The newest CREATE of the rollup and every ALTER of it shipped after that
  # one: a view created REFRESH DEFERRED MANUAL (0040) only gets its refresh
  # schedule from the ALTER that follows, and without it would never refresh.
  defp rollup_statements(state, table) do
    view = "#{table}_hourly"
    create = ~r/^CREATE\s+MATERIALIZED\s+VIEW\s+IF\s+NOT\s+EXISTS\s+\S+\.#{view}\b/i
    alter = ~r/^ALTER\s+MATERIALIZED\s+VIEW\s+\S+\.#{view}\s/i
    statements = Enum.flat_map(state.migrations, & &1.statements)

    case statements |> Enum.with_index() |> Enum.filter(fn {sql, _} -> sql =~ create end) do
      [] ->
        nil

      creates ->
        {created, index} = List.last(creates)
        retarget = &Schema.retarget(&1, state.database, state.replication_num)
        alters = statements |> Enum.drop(index + 1) |> Enum.filter(&(&1 =~ alter))
        {retarget.(created), Enum.map(alters, retarget)}
    end
  end

  defp exec_all(state, statements) do
    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case exec(state, sql) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A load already in flight at the swap commits to the old table a moment
  # later, so one pass is not enough; the pause lets those land first.
  defp catch_up(_state, _spec, _columns, _days, 0), do: :ok

  defp catch_up(state, spec, columns, days, passes_left) do
    with {:ok, old_hours} <- hours_in(state, spec.copy, spec.time_column, days),
         :ok <- catch_up_hours(state, spec, columns, old_hours) do
      if passes_left > 1, do: state.sleep.(@catch_up_pause_ms)
      catch_up(state, spec, columns, days, passes_left - 1)
    end
  end

  defp catch_up_hours(state, spec, columns, hours) do
    each_hour(spec, :catch_up, hours, &exec(state, catch_up_hour_sql(state, spec, columns, &1)))
  end

  defp copy_hour_sql(state, spec, columns, hour) do
    list = column_list(columns)

    "INSERT INTO #{qualified(state, spec.copy)} (#{list}) SELECT #{list} FROM #{qualified(state, spec.table)} " <>
      "WHERE #{in_hour("`#{spec.time_column}`", hour)}"
  end

  # The hour bounds both sides, so each reads an hour of one partition instead
  # of joining the whole of one table to the whole of the other.
  defp catch_up_hour_sql(state, spec, columns, hour) do
    on = Enum.map_join(spec.keys, " AND ", &"o.`#{&1}` = n.`#{&1}`")

    "INSERT INTO #{qualified(state, spec.table)} (#{column_list(columns)}) " <>
      "SELECT #{column_list(columns, "o.")} FROM #{qualified(state, spec.copy)} o " <>
      "LEFT ANTI JOIN #{qualified(state, spec.table)} n ON #{on} AND #{in_hour("n.`#{spec.time_column}`", hour)} " <>
      "WHERE #{in_hour("o.`#{spec.time_column}`", hour)}"
  end

  defp in_hour(column, hour) do
    "#{column} >= '#{hour}' AND #{column} < DATE_ADD('#{hour}', INTERVAL 1 HOUR)"
  end

  # Every held hour of the newest `count` days that hold any, newest first.
  defp newest_days(hours, count) do
    days = hours |> Enum.map(&day_of/1) |> Enum.uniq() |> Enum.take(count)
    Enum.filter(hours, &(day_of(&1) in days))
  end

  defp day_of(hour), do: String.slice(hour, 0, 10)

  # The hours, newest first and as `YYYY-MM-DD HH:00:00`, in which a table
  # holds rows inside retention. One statement a day, newest day first: a
  # single statement over the whole window would read every partition of it.
  defp hours_in(state, table, time_column, days) do
    column = "`#{time_column}`"

    @future_slack_days..-days//-1
    |> Enum.reduce_while({:ok, []}, fn day, {:ok, found} ->
      sql =
        "SELECT /*+ SET_VAR(query_timeout = #{@scan_timeout_s}) */ DISTINCT " <>
          "date_trunc('hour', #{column}) FROM #{qualified(state, table)} " <>
          "WHERE #{column} >= #{day_start(day)} AND #{column} < #{day_start(day + 1)} " <>
          "AND #{window(column, days)} ORDER BY 1 DESC"

      case query(state, sql) do
        {:ok, %{rows: rows}} ->
          hours = Enum.map(rows, fn [hour | _] -> hour |> to_string() |> String.slice(0, 19) end)
          {:cont, {:ok, [hours | found]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, found |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  # Midnight UTC `offset` days from today, by the warehouse's clock.
  defp day_start(0), do: "date_trunc('day', UTC_TIMESTAMP())"

  defp day_start(offset) when offset > 0,
    do: "DATE_ADD(date_trunc('day', UTC_TIMESTAMP()), INTERVAL #{offset} DAY)"

  defp day_start(offset),
    do: "DATE_SUB(date_trunc('day', UTC_TIMESTAMP()), INTERVAL #{-offset} DAY)"

  defp window(column, days) do
    "#{column} >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL #{days} DAY) " <>
      "AND #{column} < DATE_ADD(UTC_TIMESTAMP(), INTERVAL #{@future_slack_days} DAY)"
  end

  defp column_list(columns, prefix \\ ""), do: Enum.map_join(columns, ", ", &"#{prefix}`#{&1}`")

  # The partitioned definition is whatever this release ships, read out of the
  # same migrations a fresh warehouse is built from, so the two cannot drift.
  # The catch-up is an anti-join on the key columns, which is only sound for a
  # key that identifies a row. A DUPLICATE or AGGREGATE KEY table is refused
  # rather than rebuilt: rows whose key columns collide would read as already
  # copied and be silently dropped. A table that needs no rebuild never
  # reaches here, so one created partitioned stays untouched whatever its key.
  defp spec(state, table, days) do
    pattern = ~r/^CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+\S+\.#{table}\s*\(/i

    case last_statement(state, pattern) do
      nil ->
        {:error, :no_partitioned_definition}

      statement ->
        with [_, time_column] <-
               Regex.run(
                 ~r/PARTITION\s+BY\s+date_trunc\('day',\s*`?(\w+)`?\)/i,
                 statement
               ),
             [_, keys] <-
               Regex.run(~r/(?:PRIMARY|UNIQUE)\s+KEY\s*\(([^)]+)\)/i, statement) do
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
             keys:
               keys |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.trim("`")))
           }}
        else
          _ ->
            if Regex.match?(~r/(?:DUPLICATE|AGGREGATE)\s+KEY/i, statement),
              do: {:error, :unsupported_key_model},
              else: {:error, :no_partitioned_definition}
        end
    end
  end

  defp last_statement(state, pattern) do
    state.migrations
    |> Enum.flat_map(& &1.statements)
    |> Enum.filter(&Regex.match?(pattern, &1))
    |> List.last()
  end

  # Every table and view -> :current, :unsorted (partitioned, but not on the
  # sort key its shipped CREATE names) or :unpartitioned. A `__rebuild` copy is held
  # to its base table's shipped CREATE, the one it was made from. A sort key is
  # compared only where that CREATE names one; otherwise StarRocks derives it
  # from the key, and any key it derived is the shipped one.
  defp layout(state) do
    sql =
      "SELECT TABLE_NAME, PARTITION_KEY, SORT_KEY FROM information_schema.tables_config " <>
        "WHERE TABLE_SCHEMA = '#{state.database}'"

    case query(state, sql) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Map.new(rows, fn [table, partition_key, sort_key | _] ->
           table = to_string(table)
           shipped = shipped_sort_key(state, String.replace_suffix(table, @suffix, ""))

           kind =
             cond do
               blank?(partition_key) -> :unpartitioned
               shipped == nil or sort_key_columns(sort_key) == shipped -> :current
               true -> :unsorted
             end

           {table, kind}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp shipped_sort_key(state, table) do
    pattern = ~r/^CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+\S+\.#{table}\s*\(/i

    with statement when is_binary(statement) <- last_statement(state, pattern),
         [_, columns] <- Regex.run(~r/\bORDER\s+BY\s*\(([^)]*)\)/i, statement) do
      sort_key_columns(columns)
    else
      _ -> nil
    end
  end

  # `a`, `b` as information_schema.tables_config reports it, or the column
  # list of an ORDER BY: unquoted, lower-cased names in order.
  defp sort_key_columns(columns) do
    columns
    |> to_string()
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim("`") |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
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

    case query(state, sql) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [column | _] -> to_string(column) end)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Every statement goes through here. The migration lock lives in PostgreSQL
  # and can be lost while this runs, so it is checked before each one; a runner
  # without it raises here rather than work beside the one that took over.
  defp query(state, sql) do
    Map.get(state, :still_locked, fn -> :ok end).()
    state.query.(sql)
  end

  defp exec(state, sql) do
    case query(state, sql) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp qualified(state, table), do: "#{state.database}.#{table}"

  defp blank?(nil), do: true
  defp blank?(value), do: value |> to_string() |> String.trim() == ""
end
