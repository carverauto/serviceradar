defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorker do
  @moduledoc """
  Oban worker that incrementally refreshes the otel_trace_summaries table.

  Instead of rescanning all traces via REFRESH MATERIALIZED VIEW, this worker:
  1. Finds trace_ids with new spans since the last refresh (5-minute lookback)
  2. Computes full aggregation for only those traces
  3. Upserts into otel_trace_summaries via ON CONFLICT
  4. Cleans up rows older than 7 days

  On first run (empty table), performs a chunked backfill in 1-hour windows
  to avoid timing out on large datasets.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 120, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

  # Upsert traces whose spans fall within a time window [$1, $2).
  # For each matching trace_id, aggregates ALL its spans within 7 days.
  @upsert_sql """
  INSERT INTO otel_trace_summaries (
    trace_id, timestamp, root_span_id, root_span_name, root_service_name,
    root_span_kind, start_time_unix_nano, end_time_unix_nano, duration_ms,
    status_code, status_message, service_set, span_count, error_count, refreshed_at
  )
  SELECT
    t.trace_id,
    max(t.timestamp),
    max(t.span_id) FILTER (WHERE t.parent_span_id IS NULL OR t.parent_span_id = ''),
    max(t.name) FILTER (WHERE t.parent_span_id IS NULL OR t.parent_span_id = ''),
    max(t.service_name) FILTER (WHERE t.parent_span_id IS NULL OR t.parent_span_id = ''),
    max(t.kind) FILTER (WHERE t.parent_span_id IS NULL OR t.parent_span_id = ''),
    min(t.start_time_unix_nano),
    max(t.end_time_unix_nano),
    (max(t.end_time_unix_nano) - min(t.start_time_unix_nano))::float8 / 1000000.0,
    max(t.status_code) FILTER (WHERE t.parent_span_id IS NULL OR t.parent_span_id = ''),
    max(t.status_message) FILTER (WHERE t.parent_span_id IS NULL OR t.parent_span_id = ''),
    array_agg(DISTINCT t.service_name) FILTER (WHERE t.service_name IS NOT NULL),
    count(*),
    count(*) FILTER (WHERE t.status_code IS NOT NULL AND t.status_code != 1),
    NOW()
  FROM otel_traces t
  WHERE t.trace_id IN (
    SELECT DISTINCT trace_id FROM otel_traces
    WHERE timestamp >= $1 AND timestamp < $2 AND trace_id IS NOT NULL
  )
  AND t.timestamp >= NOW() - INTERVAL '7 days'
  AND t.trace_id IS NOT NULL
  GROUP BY t.trace_id
  ON CONFLICT (trace_id) DO UPDATE SET
    timestamp = EXCLUDED.timestamp,
    root_span_id = EXCLUDED.root_span_id,
    root_span_name = EXCLUDED.root_span_name,
    root_service_name = EXCLUDED.root_service_name,
    root_span_kind = EXCLUDED.root_span_kind,
    start_time_unix_nano = EXCLUDED.start_time_unix_nano,
    end_time_unix_nano = EXCLUDED.end_time_unix_nano,
    duration_ms = EXCLUDED.duration_ms,
    status_code = EXCLUDED.status_code,
    status_message = EXCLUDED.status_message,
    service_set = EXCLUDED.service_set,
    span_count = EXCLUDED.span_count,
    error_count = EXCLUDED.error_count,
    refreshed_at = NOW()
  """

  @cleanup_sql "DELETE FROM otel_trace_summaries WHERE timestamp < NOW() - INTERVAL '7 days'"

  @table_has_data_sql "SELECT EXISTS(SELECT 1 FROM otel_trace_summaries LIMIT 1)"

  # Backfill in 1-hour chunks to keep each query fast
  @backfill_chunk_seconds 3600

  def upsert_sql, do: @upsert_sql

  @impl Oban.Worker
  def perform(_job) do
    case determine_mode() do
      :incremental ->
        now = DateTime.utc_now()
        cutoff = DateTime.add(now, -5, :minute)

        with :ok <- run_upsert(cutoff, now),
             :ok <- cleanup_old_summaries() do
          Logger.info("Refreshed otel_trace_summaries (incremental, 5-min lookback)")
          :ok
        end

      :backfill ->
        with :ok <- run_chunked_backfill(),
             :ok <- cleanup_old_summaries() do
          Logger.info("Refreshed otel_trace_summaries (chunked 7-day backfill complete)")
          :ok
        end
    end
  rescue
    error ->
      Logger.error("Failed to refresh otel_trace_summaries: #{Exception.message(error)}")
      {:error, error}
  end

  defp determine_mode do
    case Ecto.Adapters.SQL.query(ServiceRadar.Repo, @table_has_data_sql, [], timeout: 10_000) do
      {:ok, %{rows: [[true]]}} -> :incremental
      _ -> :backfill
    end
  end

  # Backfill 7 days in 1-hour chunks, oldest-first.
  # Each chunk is a bounded query that completes well within the 60s timeout.
  defp run_chunked_backfill do
    now = DateTime.utc_now()
    start = DateTime.add(now, -7, :day)

    build_windows(start, now)
    |> Enum.reduce_while(:ok, fn {window_start, window_end}, :ok ->
      case run_upsert(window_start, window_end) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp build_windows(start, bound) do
    Stream.unfold(start, fn cursor ->
      if DateTime.compare(cursor, bound) != :lt do
        nil
      else
        chunk_end = DateTime.add(cursor, @backfill_chunk_seconds, :second)
        chunk_end = if DateTime.compare(chunk_end, bound) == :gt, do: bound, else: chunk_end
        {{cursor, chunk_end}, chunk_end}
      end
    end)
  end

  defp run_upsert(window_start, window_end) do
    case Ecto.Adapters.SQL.query(
           ServiceRadar.Repo,
           @upsert_sql,
           [window_start, window_end],
           timeout: 60_000
         ) do
      {:ok, _result} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("otel_trace_summaries or otel_traces table missing; skipping refresh")
        :ok

      {:error, error} ->
        Logger.error("Failed to upsert otel_trace_summaries: #{Exception.message(error)}")
        {:error, error}
    end
  end

  defp cleanup_old_summaries do
    case Ecto.Adapters.SQL.query(ServiceRadar.Repo, @cleanup_sql, [], timeout: 10_000) do
      {:ok, _result} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :ok

      {:error, error} ->
        Logger.error("Failed to clean up old trace summaries: #{Exception.message(error)}")
        {:error, error}
    end
  end
end
