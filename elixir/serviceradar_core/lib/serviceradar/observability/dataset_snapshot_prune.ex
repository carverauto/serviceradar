defmodule ServiceRadar.Observability.DatasetSnapshotPrune do
  @moduledoc """
  Batch-deletes inactive netflow dataset snapshots and their child rows.

  Provider CIDR snapshots are ~410k rows each. A single `DELETE ... CASCADE`
  times out and the nightly `DataRetentionWorker` 14-day window left a dozen
  inactive copies in demo. This pruner:

  - never deletes the active snapshot
  - keeps the newest `keep_last` inactive snapshots as a rollback copy
  - deletes any other inactive snapshot (or any inactive snapshot older than
    `retention_days`)
  - removes child rows in batches before dropping the snapshot row
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  require Logger

  @default_retention_days 2
  @default_keep_last 1
  @default_entry_batch_size 10_000
  @default_snapshot_limit 8
  @query_timeout_ms 120_000

  @known_tables %{
    "netflow_provider_dataset_snapshots" => "netflow_provider_cidrs",
    "netflow_oui_dataset_snapshots" => "netflow_oui_prefixes"
  }

  @type prune_result :: %{
          snapshot_table: String.t(),
          deleted_snapshots: non_neg_integer(),
          deleted_entries: non_neg_integer(),
          remaining_doomed: non_neg_integer()
        }

  @doc "Configured prune options from `DataRetentionWorker` env."
  @spec config(keyword()) :: keyword()
  def config(overrides \\ []) do
    env =
      Application.get_env(:serviceradar_core, ServiceRadar.Observability.DataRetentionWorker, [])

    [
      retention_days:
        positive_integer(
          Keyword.get(
            overrides,
            :retention_days,
            Keyword.get(env, :dataset_snapshot_retention_days)
          ),
          @default_retention_days
        ),
      keep_last:
        non_neg_integer(
          Keyword.get(overrides, :keep_last, Keyword.get(env, :dataset_snapshot_keep_last)),
          @default_keep_last
        ),
      entry_batch_size:
        positive_integer(
          Keyword.get(overrides, :entry_batch_size, Keyword.get(env, :batch_size)),
          @default_entry_batch_size
        ),
      snapshot_limit:
        positive_integer(
          Keyword.get(overrides, :snapshot_limit),
          @default_snapshot_limit
        )
    ]
  end

  @doc "Prune one snapshot table and its child-entry table."
  @spec run(String.t(), String.t(), keyword()) :: {:ok, prune_result()} | {:error, term()}
  def run(snapshot_table, entry_table, opts \\ []) do
    with :ok <- validate_tables(snapshot_table, entry_table) do
      cfg = config(opts)

      case doomed_snapshot_ids(snapshot_table, cfg) do
        {:ok, ids} ->
          {deleted_snapshots, deleted_entries} =
            Enum.reduce(ids, {0, 0}, fn id, {snap_acc, entry_acc} ->
              case prune_snapshot(snapshot_table, entry_table, id, cfg[:entry_batch_size]) do
                {:ok, %{deleted_snapshot?: true, deleted_entries: n}} ->
                  {snap_acc + 1, entry_acc + n}

                {:ok, %{deleted_snapshot?: false, deleted_entries: n}} ->
                  {snap_acc, entry_acc + n}

                {:error, reason} ->
                  Logger.warning("Failed to prune inactive dataset snapshot",
                    table: snapshot_table,
                    snapshot_id: id,
                    reason: inspect(reason)
                  )

                  {snap_acc, entry_acc}
              end
            end)

          remaining =
            case doomed_snapshot_ids(snapshot_table, cfg) do
              {:ok, leftover} -> length(leftover)
              {:error, _} -> 0
            end

          result = %{
            snapshot_table: snapshot_table,
            deleted_snapshots: deleted_snapshots,
            deleted_entries: deleted_entries,
            remaining_doomed: remaining
          }

          if deleted_snapshots > 0 or deleted_entries > 0 do
            Logger.info("Pruned inactive dataset snapshots",
              table: snapshot_table,
              deleted_snapshots: deleted_snapshots,
              deleted_entries: deleted_entries,
              remaining_doomed: remaining,
              retention_days: cfg[:retention_days],
              keep_last: cfg[:keep_last]
            )
          end

          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  @spec doomed_snapshot_ids(String.t(), keyword()) :: {:ok, [binary()]} | {:error, term()}
  def doomed_snapshot_ids(snapshot_table, opts) do
    with :ok <- validate_snapshot_table(snapshot_table) do
      cfg = config(opts)

      sql = """
      WITH ranked AS (
        SELECT
          id,
          fetched_at,
          row_number() OVER (ORDER BY fetched_at DESC NULLS LAST) AS rn
        FROM platform.#{snapshot_table}
        WHERE is_active = FALSE
      )
      SELECT id
      FROM ranked
      WHERE rn > $1
         OR fetched_at < NOW() - ($2::int * INTERVAL '1 day')
      ORDER BY fetched_at ASC NULLS FIRST
      LIMIT $3
      """

      case SQL.query(
             Repo,
             sql,
             [cfg[:keep_last], cfg[:retention_days], cfg[:snapshot_limit]],
             timeout: @query_timeout_ms
           ) do
        {:ok, %{rows: rows}} ->
          {:ok, Enum.map(rows, fn [id] -> id end)}

        {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prune_snapshot(snapshot_table, entry_table, snapshot_id, batch_size) do
    with {:ok, deleted_entries} <- delete_entries(entry_table, snapshot_id, batch_size),
         {:ok, deleted?} <- delete_snapshot(snapshot_table, snapshot_id) do
      {:ok, %{deleted_snapshot?: deleted?, deleted_entries: deleted_entries}}
    end
  end

  defp delete_entries(entry_table, snapshot_id, batch_size) do
    sql = """
    WITH doomed AS (
      SELECT ctid
      FROM platform.#{entry_table}
      WHERE snapshot_id = $1
      LIMIT $2
    )
    DELETE FROM platform.#{entry_table} AS target
    USING doomed
    WHERE target.ctid = doomed.ctid
    """

    delete_entries_loop(sql, snapshot_id, batch_size, 0)
  end

  defp delete_entries_loop(sql, snapshot_id, batch_size, acc) do
    case SQL.query(Repo, sql, [snapshot_id, batch_size], timeout: @query_timeout_ms) do
      {:ok, %{num_rows: 0}} ->
        {:ok, acc}

      {:ok, %{num_rows: n}} when n < batch_size ->
        {:ok, acc + n}

      {:ok, %{num_rows: n}} ->
        delete_entries_loop(sql, snapshot_id, batch_size, acc + n)

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_snapshot(snapshot_table, snapshot_id) do
    sql = """
    DELETE FROM platform.#{snapshot_table}
    WHERE id = $1
      AND is_active = FALSE
    """

    case SQL.query(Repo, sql, [snapshot_id], timeout: @query_timeout_ms) do
      {:ok, %{num_rows: n}} -> {:ok, n > 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_tables(snapshot_table, entry_table) do
    case Map.fetch(@known_tables, snapshot_table) do
      {:ok, ^entry_table} -> :ok
      {:ok, expected} -> {:error, {:entry_table_mismatch, expected, entry_table}}
      :error -> {:error, {:unknown_snapshot_table, snapshot_table}}
    end
  end

  defp validate_snapshot_table(snapshot_table) do
    if Map.has_key?(@known_tables, snapshot_table) do
      :ok
    else
      {:error, {:unknown_snapshot_table, snapshot_table}}
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp non_neg_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_integer(_value, default), do: default
end
