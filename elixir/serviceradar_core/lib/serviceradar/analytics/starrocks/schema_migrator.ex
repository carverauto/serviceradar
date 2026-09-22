defmodule ServiceRadar.Analytics.StarRocks.SchemaMigrator do
  @moduledoc """
  Brings the StarRocks warehouse up to the schema this release ships.

  Runs at startup whenever StarRocks is enabled, so a Helm install, a Helm
  upgrade and a Compose `up` all converge without an operator applying DDL by
  hand. Applied versions are recorded in `<database>.schema_migrations`, and a
  PostgreSQL advisory lock serialises the replicas that start together.

  A warehouse that predates the ledger is adopted rather than rejected: CREATEs
  are `IF NOT EXISTS`, the rollup rebuild drops before it creates, and an
  `ADD COLUMN` whose column is already there is skipped. The same property
  makes a migration that failed half way safe to run again, which is the only
  recovery a failed migration needs. A new statement kind that cannot be
  repeated needs a guard here before it ships.

  One upgrade cannot be written as a statement at all. A table created before
  daily partitioning has to be rebuilt beside itself and swapped in, which
  `PartitionRebuild` does ahead of the first migration that needs partitioned
  tables (0017's rollups). Migrations before that one are not held up by it.

  The advisory lock is a PostgreSQL transaction, and a connection that drops
  releases it while this process carries on. So the lock is checked, with a
  query inside that transaction, before every statement sent to StarRocks: a
  runner that has lost the lock raises there, stops, and contends for the lock
  again like any other replica. What this does not cover is the one statement
  already in flight when the lock is lost. That one completes.
  """

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.PartitionRebuild
  alias ServiceRadar.Analytics.StarRocks.Retention
  alias ServiceRadar.Analytics.StarRocks.Schema

  require Logger

  @conn __MODULE__.Conn
  @ledger "schema_migrations"
  # Arbitrary, but fixed: every replica must contend for the same key.
  @lock_key 7_203_950_114
  # DDL answers in seconds. The ceiling is for the one statement that does not:
  # PartitionRebuild copying a table, which StarRocks itself allows four hours
  # (insert_timeout). A client that gives up first abandons a copy still running.
  @ddl_timeout_ms 14_400_000
  @initial_delay_ms 5_000
  @max_delay_ms 60_000
  @alter_poll_ms 1_000
  @alter_poll_attempts 600
  @max_replication 3

  @spec child_spec(term()) :: Supervisor.child_spec() | nil
  def child_spec(_opts) do
    if Env.config()[:enabled] do
      %{
        id: __MODULE__,
        start: {Task, :start_link, [__MODULE__, :run, [[]]]},
        restart: :temporary,
        type: :worker
      }
    end
  end

  @doc false
  @spec run(keyword()) :: :ok
  def run(opts) when is_list(opts) do
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    run_attempt(opts, Keyword.get(opts, :attempts, :infinity), @initial_delay_ms, sleep)
  end

  defp run_attempt(opts, attempts_left, delay, sleep) do
    case migrate(opts) do
      {:ok, []} ->
        Logger.info("StarRocks schema is current")

      {:ok, applied} ->
        Logger.info("StarRocks schema migrated: applied #{Enum.join(applied, ", ")}")

      {:error, reason} when attempts_left == :infinity or attempts_left > 1 ->
        Logger.warning(
          "StarRocks schema not migrated, retrying in #{delay}ms: #{inspect(reason)}"
        )

        sleep.(delay)
        run_attempt(opts, remaining(attempts_left), min(delay * 2, @max_delay_ms), sleep)

      {:error, reason} ->
        Logger.error("StarRocks schema could not be migrated: #{inspect(reason)}")
    end

    :ok
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(attempts), do: attempts - 1

  @doc """
  Applies every pending migration and returns the versions it applied.

  `:query`, `:with_lock`, `:migrations` and `:database` are injectable so the
  ordering, adoption and failure behaviour can be tested without a warehouse.
  """
  @spec migrate(keyword()) :: {:ok, [pos_integer()]} | {:error, term()}
  def migrate(opts \\ []) do
    database = Keyword.get_lazy(opts, :database, fn -> Env.config()[:database] end)

    if Schema.valid_database?(database) do
      with_query(opts, fn query ->
        state = %{
          query: query,
          database: database,
          migrations: Keyword.get_lazy(opts, :migrations, &Schema.migrations/0),
          sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
          retention_days: Keyword.get_lazy(opts, :retention_days, &Retention.days_by_table/0)
        }

        with {:ok, replication_num} <- replication_num(query) do
          with_lock = Keyword.get(opts, :with_lock, &with_advisory_lock/1)
          state = Map.put(state, :replication_num, replication_num)

          try do
            with_lock.(fn still_locked ->
              apply_pending(Map.put(state, :still_locked, still_locked))
            end)
          rescue
            # A connection that drops under an hours-long transaction raises,
            # from the transaction or from the lock check. Returned as an error
            # it is retried like any other; raised, it ends the migrator for
            # the life of the node.
            exception -> {:error, exception}
          end
        end
      end)
    else
      {:error, {:invalid_database, database}}
    end
  end

  # The shared pool names the database in its connection options, so it cannot
  # connect until this module has created that database. Migrations therefore
  # run on a connection of their own that names none.
  defp with_query(opts, fun) do
    case Keyword.fetch(opts, :query) do
      {:ok, query} ->
        fun.(query)

      :error ->
        conn_opts =
          Env.config()
          |> MySQL.connection_opts()
          |> Keyword.delete(:database)
          |> Keyword.merge(name: @conn, pool_size: 1)

        case MyXQL.start_link(conn_opts) do
          {:ok, pid} ->
            try do
              fun.(&MySQL.query(&1, conn: @conn, timeout: @ddl_timeout_ms))
            after
              GenServer.stop(pid)
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp with_advisory_lock(fun) do
    result =
      ServiceRadar.Repo.transaction(
        fn ->
          # Another replica may hold this for as long as a rebuild takes. The
          # default query timeout would raise here after 15s and take the
          # migrator down with it, leaving nobody to resume if that replica dies.
          ServiceRadar.Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key],
            timeout: :infinity
          )

          # The lock is this transaction, which then sits idle for as long as
          # StarRocks works -- hours, for a partition rebuild. A deployment that
          # sets idle_in_transaction_session_timeout would have it killed, the
          # lock released, and a second replica start rebuilding the same tables.
          ServiceRadar.Repo.query!("SET LOCAL idle_in_transaction_session_timeout = 0")

          # Inside this transaction, so it raises once the connection holding
          # the lock is gone.
          fun.(fn ->
            ServiceRadar.Repo.query!("SELECT 1")
            :ok
          end)
        end,
        timeout: :infinity
      )

    case result do
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
    end
  end

  # Shared-nothing warehouses place replicas on backends, so a single-node
  # install cannot satisfy the pinned factor of 3. Shared-data warehouses have
  # compute nodes and no backends; object storage owns durability there and the
  # pinned value is accepted as is. Either way nothing can be created until one
  # node is alive, so that is also the readiness check.
  defp replication_num(query) do
    backends = alive(query, "SHOW BACKENDS")
    compute_nodes = alive(query, "SHOW COMPUTE NODES")

    cond do
      backends > 0 -> {:ok, min(backends, @max_replication)}
      compute_nodes > 0 -> {:ok, @max_replication}
      true -> {:error, :no_live_starrocks_node}
    end
  end

  defp alive(query, sql) do
    with {:ok, %{columns: columns, rows: rows}} <- query.(sql),
         index when is_integer(index) <- Enum.find_index(columns, &(&1 == "Alive")) do
      Enum.count(rows, &(&1 |> Enum.at(index) |> to_string() |> String.downcase() == "true"))
    else
      _ -> 0
    end
  end

  # Migrations that only need the tables to exist go first: they take seconds,
  # and EventWriter may already be loading the columns they add. A rollup
  # partitioned by day can only be created over partitioned tables, so from the
  # first such migration on, everything waits for PartitionRebuild -- which on
  # a warehouse that needs it can take hours, and on any other does nothing.
  defp apply_pending(state) do
    with :ok <- ensure_ledger(state),
         {:ok, applied} <- applied_versions(state) do
      {early, late} =
        state.migrations
        |> Enum.reject(&MapSet.member?(applied, &1.version))
        |> Enum.split_while(&(not Schema.needs_partitioned_tables?(&1)))

      with {:ok, first} <- apply_each(state, early),
           :ok <- PartitionRebuild.run(state),
           {:ok, rest} <- apply_each(state, late) do
        {:ok, first ++ rest}
      end
    end
  end

  defp apply_each(state, migrations) do
    migrations
    |> Enum.reduce_while({:ok, []}, fn migration, {:ok, done} ->
      case apply_migration(state, migration) do
        :ok -> {:cont, {:ok, [migration.version | done]}}
        {:error, reason} -> {:halt, {:error, {migration.version, reason}}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  defp ensure_ledger(%{query: query, database: database, replication_num: replication_num}) do
    statements = [
      "CREATE DATABASE IF NOT EXISTS #{database}",
      """
      CREATE TABLE IF NOT EXISTS #{database}.#{@ledger} (
        version INT NOT NULL,
        name VARCHAR(255) NOT NULL,
        checksum VARCHAR(64) NOT NULL,
        applied_at DATETIME NOT NULL
      )
      PRIMARY KEY (version)
      DISTRIBUTED BY HASH(version) BUCKETS 1
      PROPERTIES ("replication_num" = "#{replication_num}")
      """
    ]

    Enum.reduce_while(statements, :ok, fn sql, :ok ->
      case query.(sql) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp applied_versions(%{query: query, database: database}) do
    case query.("SELECT version FROM #{database}.#{@ledger}") do
      {:ok, %{rows: rows}} -> {:ok, MapSet.new(rows, fn [version | _] -> version end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_migration(state, migration) do
    Logger.info("Applying StarRocks schema #{migration.version} (#{migration.name})")

    result =
      Enum.reduce_while(migration.statements, :ok, fn statement, :ok ->
        statement = Schema.retarget(statement, state.database, state.replication_num)
        state.still_locked.()

        case execute(state, statement) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with :ok <- result do
      record(state, migration)
    end
  end

  defp execute(state, statement) do
    case Schema.add_column(statement) do
      {:ok, {table, column}} -> add_column(state, statement, table, column)
      :error -> run_statement(state, statement)
    end
  end

  defp add_column(state, statement, table, column) do
    exists_sql =
      "SELECT 1 FROM information_schema.columns WHERE table_schema = '#{state.database}' " <>
        "AND table_name = '#{table}' AND column_name = '#{column}'"

    case state.query.(exists_sql) do
      {:ok, %{rows: [_ | _]}} ->
        :ok

      {:ok, _none} ->
        with :ok <- run_statement(state, statement) do
          await_alter(state, table, @alter_poll_attempts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_statement(state, statement) do
    case state.query.(statement) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A schema change is a background job, and StarRocks refuses a second ALTER on
  # a table while one is still running.
  defp await_alter(_state, table, 0), do: {:error, {:alter_not_finished, table}}

  defp await_alter(state, table, attempts_left) do
    sql =
      "SHOW ALTER TABLE COLUMN FROM #{state.database} WHERE TableName = '#{table}' " <>
        "ORDER BY CreateTime DESC LIMIT 1"

    case alter_state(state.query.(sql)) do
      {:ok, "CANCELLED"} ->
        {:error, {:alter_cancelled, table}}

      {:ok, "FINISHED" <> _} ->
        :ok

      {:ok, :none} ->
        :ok

      {:ok, _running} ->
        state.sleep.(@alter_poll_ms)
        await_alter(state, table, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp alter_state({:ok, %{rows: []}}), do: {:ok, :none}

  defp alter_state({:ok, %{columns: columns, rows: [row | _]}}) do
    case Enum.find_index(columns, &(&1 == "State")) do
      nil -> {:error, :alter_state_column_missing}
      index -> {:ok, row |> Enum.at(index) |> to_string()}
    end
  end

  defp alter_state({:error, reason}), do: {:error, reason}

  defp record(%{query: query, database: database}, migration) do
    sql =
      "INSERT INTO #{database}.#{@ledger} (version, name, checksum, applied_at) VALUES " <>
        "(#{migration.version}, '#{migration.name}', '#{migration.checksum}', UTC_TIMESTAMP())"

    case query.(sql) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
