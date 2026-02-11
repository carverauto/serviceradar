defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorker do
  @moduledoc """
  Oban worker that incrementally refreshes the otel_trace_summaries table.

  Instead of rescanning all traces via REFRESH MATERIALIZED VIEW, this worker:
  1. Finds trace_ids with new spans since the last refresh (5-minute lookback)
  2. Computes full aggregation for only those traces
  3. Upserts into otel_trace_summaries via ON CONFLICT
  4. Cleans up rows older than 7 days

  On first run (empty table), performs a full 7-day backfill.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 120, states: [:available, :scheduled, :executing, :retryable]]

  require Logger

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
    WHERE timestamp >= $1 AND trace_id IS NOT NULL
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

  @table_exists_sql "SELECT EXISTS(SELECT 1 FROM otel_trace_summaries LIMIT 1)"

  def upsert_sql, do: @upsert_sql

  @impl Oban.Worker
  def perform(_job) do
    lookback = determine_lookback()

    with :ok <- upsert_summaries(lookback),
         :ok <- cleanup_old_summaries() do
      Logger.info("Refreshed otel_trace_summaries (#{lookback_label(lookback)})")
      :ok
    end
  rescue
    error ->
      Logger.error("Failed to refresh otel_trace_summaries: #{Exception.message(error)}")
      {:error, error}
  end

  defp determine_lookback do
    case Ecto.Adapters.SQL.query(ServiceRadar.Repo, @table_exists_sql, [], timeout: 10_000) do
      {:ok, %{rows: [[true]]}} ->
        # Table has data — incremental 5-minute lookback
        :incremental

      _ ->
        # Table is empty or missing — full 7-day backfill
        :full
    end
  end

  defp upsert_summaries(lookback) do
    cutoff = lookback_cutoff(lookback)

    case Ecto.Adapters.SQL.query(ServiceRadar.Repo, @upsert_sql, [cutoff], timeout: 60_000) do
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

  defp lookback_cutoff(:incremental) do
    DateTime.utc_now() |> DateTime.add(-5, :minute)
  end

  defp lookback_cutoff(:full) do
    DateTime.utc_now() |> DateTime.add(-7, :day)
  end

  defp lookback_label(:incremental), do: "incremental, 5-min lookback"
  defp lookback_label(:full), do: "full 7-day backfill"
end
