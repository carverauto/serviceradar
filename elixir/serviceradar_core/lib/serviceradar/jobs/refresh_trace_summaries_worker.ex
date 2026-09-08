defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorker do
  @moduledoc """
  Oban worker that incrementally refreshes the otel_trace_summaries table.

  The worker uses an INGEST-TIME (`created_at`) watermark persisted in
  `observability_watermarks` (key `trace_summaries`):

  1. Reads the watermark; on first run it initializes to one hour ago.
  2. Upserts summaries for traces whose spans were INGESTED in
     `(watermark - 2 minute overlap, now]`, chunked into bounded windows.
     Late-arriving spans (event time far older than ingest time) are still
     summarized — worker downtime or NATS backlog no longer drops traces.
  3. Advances the watermark to the max `created_at` processed (or the run's
     upper bound when no spans were seen).
  4. Prunes summary rows older than retention, draining batches until none
     remain or a bounded time budget expires.

  Root spans are detected via `parent_span_id IS NULL` (the canonical id
  contract maps `''`/all-zero parents to NULL at ingest). When a trace has no
  such span — common for "orphan" traces whose real root was never exported —
  the earliest span (min `start_time_unix_nano`) stands in as the
  representative root, so `root_service_name`/`root_span_name` are populated
  rather than NULL. Error counting uses OTLP STATUS_ERROR (`status_code = 2`)
  only.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Observability.OtelPubSub

  require Logger

  @watermark_key "trace_summaries"

  # Upsert traces whose spans were ingested within (`$1`, `$2`].
  # For each matching trace_id, aggregates ALL its spans inside the configured
  # retention window.
  #
  # Root naming uses the trace's true root span (`parent_span_id IS NULL`) when
  # present. Many traces in practice are "orphans": every exported span points
  # at a parent that was never exported (the real root belongs to an
  # un-instrumented or sampled-out caller), so no span has a NULL parent. For
  # those traces we fall back to the earliest span (min start_time_unix_nano,
  # tie-broken by span_id) as the representative root so the summary — and the
  # traces list/detail UI that reads it — still shows a service + operation
  # name instead of blanks. The chosen-root attributes are computed once per
  # trace in `roots` via DISTINCT ON and joined to the per-trace aggregate.
  @upsert_sql """
  WITH wanted AS MATERIALIZED (
    SELECT DISTINCT trace_id FROM otel_traces
    WHERE created_at > $1 AND created_at <= $2 AND trace_id IS NOT NULL
  ),
  candidates AS (
    SELECT t.trace_id, t.span_id, t.parent_span_id, t.name, t.service_name,
           t.service_namespace, t.deployment_environment, t.kind,
           t.status_code, t.status_message, t.start_time_unix_nano,
           t.end_time_unix_nano, t.timestamp,
           (t.parent_span_id IS NULL) AS is_root
    FROM otel_traces t
    JOIN wanted w ON w.trace_id = t.trace_id
    -- Chunk-exclusion floor: spans of a just-ingested trace land within a day
    -- of the window (measured ingest lag <= ~2h30m), so a 1-day timestamp
    -- floor lets TimescaleDB prune older chunks while keeping every span the
    -- retention filter below would keep.
    WHERE t.timestamp >= $2 - INTERVAL '1 day'
    AND t.timestamp >= NOW() - ($3::int * INTERVAL '1 day')
    AND t.trace_id IS NOT NULL
  ),
  roots AS (
    SELECT DISTINCT ON (trace_id)
      trace_id, span_id, name, service_name, service_namespace,
      deployment_environment, kind, status_code, status_message
    FROM candidates
    -- Prefer a true root span; otherwise the earliest span stands in as root.
    ORDER BY trace_id, is_root DESC,
             start_time_unix_nano ASC NULLS LAST, span_id ASC
  ),
  aggregated AS (
    SELECT
      c.trace_id,
      max(c.timestamp) AS timestamp,
      min(c.start_time_unix_nano) AS start_time_unix_nano,
      max(c.end_time_unix_nano) AS end_time_unix_nano,
      array_agg(DISTINCT c.service_name) FILTER (WHERE c.service_name IS NOT NULL) AS service_set,
      count(*) AS span_count,
      count(*) FILTER (WHERE c.status_code = 2) AS error_count
    FROM candidates c
    GROUP BY c.trace_id
  )
  INSERT INTO otel_trace_summaries (
    trace_id, timestamp, root_span_id, root_span_name, root_service_name,
    root_service_namespace, deployment_environment,
    root_span_kind, start_time_unix_nano, end_time_unix_nano, duration_ms,
    status_code, status_message, service_set, span_count, error_count, refreshed_at
  )
  SELECT
    a.trace_id,
    a.timestamp,
    r.span_id,
    r.name,
    r.service_name,
    COALESCE(r.service_namespace, ''),
    COALESCE(r.deployment_environment, ''),
    r.kind,
    a.start_time_unix_nano,
    a.end_time_unix_nano,
    (a.end_time_unix_nano - a.start_time_unix_nano)::float8 / 1000000.0,
    r.status_code,
    r.status_message,
    a.service_set,
    a.span_count,
    a.error_count,
    NOW()
  FROM aggregated a
  JOIN roots r ON r.trace_id = a.trace_id
  ON CONFLICT (trace_id) DO UPDATE SET
    timestamp = EXCLUDED.timestamp,
    root_span_id = EXCLUDED.root_span_id,
    root_span_name = EXCLUDED.root_span_name,
    root_service_name = EXCLUDED.root_service_name,
    root_service_namespace = EXCLUDED.root_service_namespace,
    deployment_environment = EXCLUDED.deployment_environment,
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
  WHERE
    otel_trace_summaries.timestamp IS DISTINCT FROM EXCLUDED.timestamp OR
    otel_trace_summaries.root_span_id IS DISTINCT FROM EXCLUDED.root_span_id OR
    otel_trace_summaries.root_span_name IS DISTINCT FROM EXCLUDED.root_span_name OR
    otel_trace_summaries.root_service_name IS DISTINCT FROM EXCLUDED.root_service_name OR
    otel_trace_summaries.root_service_namespace IS DISTINCT FROM EXCLUDED.root_service_namespace OR
    otel_trace_summaries.deployment_environment IS DISTINCT FROM EXCLUDED.deployment_environment OR
    otel_trace_summaries.root_span_kind IS DISTINCT FROM EXCLUDED.root_span_kind OR
    otel_trace_summaries.start_time_unix_nano IS DISTINCT FROM EXCLUDED.start_time_unix_nano OR
    otel_trace_summaries.end_time_unix_nano IS DISTINCT FROM EXCLUDED.end_time_unix_nano OR
    otel_trace_summaries.duration_ms IS DISTINCT FROM EXCLUDED.duration_ms OR
    otel_trace_summaries.status_code IS DISTINCT FROM EXCLUDED.status_code OR
    otel_trace_summaries.status_message IS DISTINCT FROM EXCLUDED.status_message OR
    otel_trace_summaries.service_set IS DISTINCT FROM EXCLUDED.service_set OR
    otel_trace_summaries.span_count IS DISTINCT FROM EXCLUDED.span_count OR
    otel_trace_summaries.error_count IS DISTINCT FROM EXCLUDED.error_count
  """

  @cleanup_batch_sql """
  WITH doomed AS (
    SELECT trace_id
    FROM otel_trace_summaries
    WHERE timestamp < NOW() - ($2::int * INTERVAL '1 day')
    ORDER BY timestamp ASC
    LIMIT $1
  )
  DELETE FROM otel_trace_summaries AS summaries
  USING doomed
  WHERE summaries.trace_id = doomed.trace_id
  """

  @read_watermark_sql """
  SELECT watermark FROM observability_watermarks WHERE key = $1
  """

  @write_watermark_sql """
  INSERT INTO observability_watermarks (key, watermark, updated_at)
  VALUES ($1, $2, NOW())
  ON CONFLICT (key) DO UPDATE SET
    watermark = EXCLUDED.watermark,
    updated_at = NOW()
  """

  @max_ingested_at_sql """
  SELECT max(created_at)
  FROM otel_traces
  WHERE created_at > $1 AND created_at <= $2
  """

  @remaining_estimate_sql """
  SELECT count(*) FROM (
    SELECT 1
    FROM otel_trace_summaries
    WHERE timestamp < NOW() - ($1::int * INTERVAL '1 day')
    LIMIT $2
  ) remaining
  """

  # Process the watermark backlog in bounded windows so each query stays
  # well within the statement timeout even after worker downtime.
  @ingest_chunk_seconds 300
  # Re-scan a small overlap before the watermark to absorb writer commit
  # skew (rows whose created_at predates their commit visibility).
  @watermark_overlap_seconds 120
  # First run: initialize the watermark one hour back.
  @initial_lookback_seconds 3600
  @default_cleanup_batch_size 5_000
  @default_cleanup_time_budget_ms 10_000
  @default_retention_days 3
  @default_probe_timeout_ms 30_000
  @default_upsert_timeout_ms 120_000
  @default_watermark_timeout_ms 30_000
  @default_cleanup_timeout_ms 60_000
  @default_remaining_estimate_timeout_ms 30_000

  def upsert_sql, do: @upsert_sql
  def cleanup_batch_sql, do: @cleanup_batch_sql
  def watermark_key, do: @watermark_key
  def ingest_chunk_seconds, do: @ingest_chunk_seconds
  def probe_timeout_ms, do: config_positive_integer(:probe_timeout_ms, @default_probe_timeout_ms)

  def upsert_timeout_ms,
    do: config_positive_integer(:upsert_timeout_ms, @default_upsert_timeout_ms)

  def watermark_timeout_ms,
    do: config_positive_integer(:watermark_timeout_ms, @default_watermark_timeout_ms)

  def cleanup_timeout_ms,
    do: config_positive_integer(:cleanup_timeout_ms, @default_cleanup_timeout_ms)

  @impl Oban.Worker
  def perform(_job) do
    result =
      ServiceRadar.Repo.transact(
        fn ->
          case SQL.query!(
                 ServiceRadar.Repo,
                 "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))",
                 [@watermark_key]
               ) do
            %{rows: [[true]]} -> refresh_summaries()
            %{rows: [[false]]} -> {:error, :refresh_in_progress}
          end
        end,
        timeout: :infinity
      )

    case result do
      {:ok, changed} ->
        OtelPubSub.broadcast_trace_summaries(%{count: changed})
        :ok

      {:error, :refresh_in_progress} ->
        {:snooze, 1}

      {:error, _reason} = error ->
        error
    end
  end

  defp refresh_summaries do
    now = DateTime.utc_now()
    watermark = read_watermark(now)
    window_start = DateTime.add(watermark, -@watermark_overlap_seconds, :second)

    with {:ok, changed} <- run_chunked_upsert(window_start, now),
         :ok <- advance_watermark(window_start, now),
         :ok <- cleanup_old_summaries() do
      Logger.info(
        "Refreshed otel_trace_summaries (ingest-time watermark)",
        watermark: DateTime.to_iso8601(watermark),
        window_end: DateTime.to_iso8601(now)
      )

      {:ok, changed}
    end
  rescue
    error ->
      Logger.error("Failed to refresh otel_trace_summaries: #{Exception.message(error)}")
      {:error, error}
  end

  defp read_watermark(now) do
    case SQL.query(ServiceRadar.Repo, @read_watermark_sql, [@watermark_key],
           timeout: watermark_timeout_ms()
         ) do
      {:ok, %{rows: [[%DateTime{} = watermark]]}} ->
        watermark

      {:ok, %{rows: [[%NaiveDateTime{} = watermark]]}} ->
        DateTime.from_naive!(watermark, "Etc/UTC")

      _ ->
        DateTime.add(now, -@initial_lookback_seconds, :second)
    end
  end

  defp run_chunked_upsert(window_start, window_end) do
    window_start
    |> build_windows(window_end)
    |> Enum.reduce_while({:ok, 0}, fn {chunk_start, chunk_end}, {:ok, total} ->
      case run_upsert(chunk_start, chunk_end) do
        {:ok, changed} -> {:cont, {:ok, total + changed}}
        error -> {:halt, error}
      end
    end)
  end

  defp build_windows(start, bound) do
    Stream.unfold(start, fn cursor ->
      if DateTime.before?(cursor, bound) do
        chunk_end = clamp_end(cursor, bound)
        {{cursor, chunk_end}, chunk_end}
      end
    end)
  end

  defp clamp_end(cursor, bound) do
    candidate = DateTime.add(cursor, @ingest_chunk_seconds, :second)
    if DateTime.after?(candidate, bound), do: bound, else: candidate
  end

  defp run_upsert(window_start, window_end) do
    if window_has_ingested_spans?(window_start, window_end) do
      case SQL.query(
             ServiceRadar.Repo,
             @upsert_sql,
             [window_start, window_end, retention_days()],
             timeout: upsert_timeout_ms()
           ) do
        {:ok, %{num_rows: changed}} when is_integer(changed) ->
          {:ok, changed}

        {:ok, _result} ->
          {:ok, 0}

        {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
          Logger.debug("otel_trace_summaries or otel_traces table missing; skipping refresh")
          {:ok, 0}

        {:error, error} ->
          Logger.error("Failed to upsert otel_trace_summaries: #{Exception.message(error)}")
          {:error, error}
      end
    else
      {:ok, 0}
    end
  end

  defp window_has_ingested_spans?(window_start, window_end) do
    sql = """
    SELECT EXISTS(
      SELECT 1
      FROM otel_traces
      WHERE created_at > $1
        AND created_at <= $2
        AND trace_id IS NOT NULL
      LIMIT 1
    )
    """

    case SQL.query(ServiceRadar.Repo, sql, [window_start, window_end],
           timeout: probe_timeout_ms()
         ) do
      {:ok, %{rows: [[true]]}} -> true
      {:ok, _result} -> false
      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} -> false
      {:error, error} -> raise error
    end
  end

  # Advance the watermark to the max created_at actually processed, falling
  # back to the run's upper bound when the window held no spans.
  defp advance_watermark(window_start, window_end) do
    new_watermark =
      case SQL.query(
             ServiceRadar.Repo,
             @max_ingested_at_sql,
             [window_start, window_end],
             timeout: watermark_timeout_ms()
           ) do
        {:ok, %{rows: [[%DateTime{} = max_created_at]]}} ->
          max_created_at

        {:ok, %{rows: [[%NaiveDateTime{} = max_created_at]]}} ->
          DateTime.from_naive!(max_created_at, "Etc/UTC")

        _ ->
          window_end
      end

    case SQL.query(
           ServiceRadar.Repo,
           @write_watermark_sql,
           [@watermark_key, new_watermark],
           timeout: watermark_timeout_ms()
         ) do
      {:ok, _result} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("observability_watermarks table missing; watermark not persisted")
        :ok

      {:error, error} ->
        Logger.error("Failed to persist trace summaries watermark: #{Exception.message(error)}")
        {:error, error}
    end
  end

  # Drain expired summary rows in batches until none remain or the time
  # budget for this run is exhausted.
  defp cleanup_old_summaries do
    batch_size = cleanup_batch_size()
    retention_days = retention_days()
    deadline = System.monotonic_time(:millisecond) + cleanup_time_budget_ms()

    drain_cleanup(batch_size, retention_days, deadline, 0)
  end

  defp drain_cleanup(batch_size, retention_days, deadline, total_deleted) do
    case SQL.query(ServiceRadar.Repo, @cleanup_batch_sql, [batch_size, retention_days],
           timeout: cleanup_timeout_ms()
         ) do
      {:ok, %{num_rows: deleted_rows}} ->
        total_deleted = total_deleted + deleted_rows

        cond do
          deleted_rows < batch_size ->
            log_cleanup(total_deleted, retention_days, 0)
            :ok

          System.monotonic_time(:millisecond) < deadline ->
            drain_cleanup(batch_size, retention_days, deadline, total_deleted)

          true ->
            log_cleanup(total_deleted, retention_days, remaining_estimate(retention_days))
            :ok
        end

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :ok

      {:error, error} ->
        Logger.error("Failed to clean up old trace summaries: #{Exception.message(error)}")
        {:error, error}
    end
  end

  defp log_cleanup(0, _retention_days, _remaining), do: :ok

  defp log_cleanup(total_deleted, retention_days, remaining) do
    Logger.info(
      "Pruned stale otel_trace_summaries rows",
      deleted_rows: total_deleted,
      retention_days: retention_days,
      remaining_estimate: remaining
    )
  end

  # Bounded estimate of expired rows left behind after the time budget ran
  # out (capped so the estimate query itself stays cheap).
  defp remaining_estimate(retention_days) do
    case SQL.query(
           ServiceRadar.Repo,
           @remaining_estimate_sql,
           [retention_days, 50_000],
           timeout: remaining_estimate_timeout_ms()
         ) do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> count
      _ -> nil
    end
  end

  defp retention_days do
    config_positive_integer(:retention_days, @default_retention_days)
  end

  defp cleanup_batch_size do
    config_positive_integer(:cleanup_batch_size, @default_cleanup_batch_size)
  end

  defp cleanup_time_budget_ms do
    config_positive_integer(:cleanup_time_budget_ms, @default_cleanup_time_budget_ms)
  end

  defp remaining_estimate_timeout_ms do
    config_positive_integer(
      :remaining_estimate_timeout_ms,
      @default_remaining_estimate_timeout_ms
    )
  end

  defp config_positive_integer(key, default) do
    :serviceradar_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
    |> positive_integer(default)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
