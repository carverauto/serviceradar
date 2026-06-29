defmodule ServiceRadar.FlowAttribution.Retention do
  @moduledoc false

  @schema "platform"
  @table "flow_process_attribution_current"
  @correlation_skew_seconds 900
  @default_retention_minutes 60
  @minimum_retention_minutes div(@correlation_skew_seconds + 59, 60)

  # Prune in bounded batches. A single `DELETE WHERE observed_at < cutoff` against a large
  # backlog (e.g. a table that drifted to tens of millions of rows) is one enormous,
  # table-locking statement that times out and fails EVERY pass — so the backlog never
  # clears and keeps growing (a death spiral that bloats the table and slows every upsert).
  # Deleting in @batch_size chunks keeps each statement small and index-friendly; the
  # correlator calls prune/0 every ~2 min, so @max_batches caps one pass (a stuck multi-
  # million-row backlog is ground down across passes) while steady-state is a single batch.
  @batch_size 50_000
  @max_batches 40

  @spec prune(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(opts \\ []) do
    max_batches = Keyword.get(opts, :max_batches, @max_batches)
    # `:deleter` (a 0-arity fun returning {:ok, deleted_count} | {:error, term}) is injectable
    # for tests; production deletes one ctid-bounded batch of the oldest expired rows.
    deleter = Keyword.get(opts, :deleter, &delete_batch/0)
    prune_batches(deleter, max_batches, 0, 0)
  end

  defp prune_batches(deleter, max_batches, deleted_total, batches_done)
       when batches_done < max_batches do
    case deleter.() do
      # A full batch means there may be more to delete — continue.
      {:ok, num_rows} when num_rows >= @batch_size ->
        prune_batches(deleter, max_batches, deleted_total + num_rows, batches_done + 1)

      # A short (or empty) batch means the backlog is drained for this pass — stop.
      {:ok, num_rows} ->
        {:ok, deleted_total + num_rows}

      # If earlier batches already deleted rows, report partial progress as success so the
      # next correlator pass keeps draining; otherwise surface the error.
      {:error, reason} ->
        if deleted_total > 0, do: {:ok, deleted_total}, else: {:error, reason}
    end
  end

  defp prune_batches(_deleter, _max_batches, deleted_total, _batches_done),
    do: {:ok, deleted_total}

  defp delete_batch do
    sql = """
    WITH victims AS (
      SELECT ctid
      FROM #{@schema}.#{@table}
      WHERE observed_at < now() - ($1::integer * interval '1 minute')
      LIMIT #{@batch_size}
    )
    DELETE FROM #{@schema}.#{@table} AS t
    USING victims AS v
    WHERE t.ctid = v.ctid
    """

    case ServiceRadar.Repo.query(sql, [retention_minutes()]) do
      {:ok, %{num_rows: num_rows}} -> {:ok, num_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec retention_minutes() :: pos_integer()
  def retention_minutes do
    :serviceradar_core
    |> Application.get_env(ServiceRadar.FlowAttribution, [])
    |> Keyword.get(:retention_minutes, @default_retention_minutes)
    |> normalize_retention_minutes()
  end

  defp normalize_retention_minutes(value) when is_integer(value) do
    max(value, @minimum_retention_minutes)
  end

  defp normalize_retention_minutes(_value), do: @default_retention_minutes
end
