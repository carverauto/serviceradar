defmodule ServiceRadar.Analytics.StarRocks.TraceSummaries do
  @moduledoc """
  The warehouse half of `ServiceRadar.Jobs.RefreshTraceSummariesWorker`.

  With StarRocks enabled, EventWriter writes spans to `otel_traces` in the
  warehouse only (`priv/starrocks/0022`), so trace summaries are derived there
  too, into the warehouse `otel_trace_summaries`. The worker keeps its
  ingest-time watermark and its advisory lock in CNPG, which is control-plane
  state, and calls this module for every statement that reads spans or writes
  summaries.

  `upsert/4` is the CNPG worker's `upsert_sql` in StarRocks SQL, with the same
  meaning: the traces with a span ingested in the window, each summarized over
  all of its spans from the last day and inside retention; the root is the
  true root span (NULL parent) when there is one, otherwise the earliest span;
  `timestamp` is the newest span's; `service_set` is the sorted distinct
  service names; `error_count` counts `status_code = 2`. The table's primary
  key is `trace_id`, so a re-run upserts. Unlike CNPG it rewrites every
  summary it computes, not only the changed ones, so its count is the rows
  written.

  Every span read carries a `timestamp` floor, which is what lets StarRocks
  skip old day partitions: a span older than a day before the window's end can
  never enter a summary (the CNPG worker applies the same floor to its
  candidates), so leaving it out of the probes changes nothing.

  StarRocks evaluates `NOW()` in the Frontend's time zone while the tables hold
  UTC, so every instant is passed in as a UTC literal.

  Callers may inject the transport with `:query`, the arity-1 seam the other
  warehouse readers use, and bound a statement with `:timeout` (ms).
  """

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query

  @candidate_floor_seconds 86_400

  @doc "Whether any span with a trace id was ingested in `(from, to]`."
  @spec any_ingested?(DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def any_ingested?(from, to, opts \\ []) do
    sql = """
    SELECT 1 FROM #{spans()}
    WHERE created_at > #{literal(from)} AND created_at <= #{literal(to)}
      AND `timestamp` >= #{literal(day_floor(to))}
    LIMIT 1
    """

    with {:ok, %{rows: rows}} <- run(sql, opts), do: {:ok, rows != []}
  end

  @doc """
  Whether any span was ingested after `watermark` (the trailing-refresh probe).

  The floor is anchored to `to` (the run's window end), the same anchor
  `any_ingested?/3` and `max_ingested_at/3` use to decide whether the
  watermark can advance, so this probe cannot disagree with them about a span
  that sits right at the day-old floor.
  """
  @spec ingested_after?(DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def ingested_after?(watermark, to, opts \\ []) do
    sql = """
    SELECT 1 FROM #{spans()}
    WHERE created_at > #{literal(watermark)} AND `timestamp` >= #{literal(day_floor(to))}
    LIMIT 1
    """

    with {:ok, %{rows: rows}} <- run(sql, opts), do: {:ok, rows != []}
  end

  @doc "The newest ingest time in `(from, to]`, or nil when the window holds no spans."
  @spec max_ingested_at(DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, DateTime.t() | nil} | {:error, term()}
  def max_ingested_at(from, to, opts \\ []) do
    sql = """
    SELECT MAX(created_at) FROM #{spans()}
    WHERE created_at > #{literal(from)} AND created_at <= #{literal(to)}
      AND `timestamp` >= #{literal(day_floor(to))}
    """

    with {:ok, %{rows: rows}} <- run(sql, opts), do: {:ok, rows |> single() |> to_datetime()}
  end

  @doc """
  Upserts the summaries of every trace with a span ingested in `(from, to]`.
  `now` stamps `refreshed_at` and anchors the retention floor.
  """
  @spec upsert(DateTime.t(), DateTime.t(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def upsert(from, to, retention_days, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, result} <- run(upsert_sql(from, to, retention_days, now), opts) do
      {:ok, result.num_rows || 0}
    end
  end

  @doc "Deletes summaries older than `retention_days` before `now`."
  @spec prune(pos_integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(retention_days, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cutoff = DateTime.add(now, -retention_days * 86_400, :second)
    sql = "DELETE FROM #{summaries()} WHERE `timestamp` < #{literal(cutoff)}"

    with {:ok, result} <- run(sql, opts), do: {:ok, result.num_rows || 0}
  end

  @doc false
  @spec upsert_sql(DateTime.t(), DateTime.t(), pos_integer(), DateTime.t()) :: String.t()
  def upsert_sql(from, to, retention_days, now) do
    candidate_floor = day_floor(to)
    retention_floor = DateTime.add(now, -retention_days * 86_400, :second)

    """
    INSERT INTO #{summaries()} (
      trace_id, `timestamp`, root_span_id, root_span_name, root_service_name,
      root_service_namespace, deployment_environment, root_span_kind,
      start_time_unix_nano, end_time_unix_nano, duration_ms, status_code,
      status_message, service_set, span_count, error_count, refreshed_at
    )
    WITH candidates AS (
      SELECT t.trace_id, t.span_id, t.parent_span_id, t.name, t.service_name,
             t.service_namespace, t.deployment_environment, t.kind, t.status_code,
             t.status_message, t.start_time_unix_nano, t.end_time_unix_nano, t.`timestamp`
      FROM #{spans()} t
      WHERE t.trace_id IN (
          SELECT trace_id FROM #{spans()}
          WHERE created_at > #{literal(from)} AND created_at <= #{literal(to)}
            AND `timestamp` >= #{literal(candidate_floor)}
        )
        AND t.`timestamp` >= #{literal(candidate_floor)}
        AND t.`timestamp` >= #{literal(retention_floor)}
    ),
    roots AS (
      SELECT * FROM (
        SELECT c.*, ROW_NUMBER() OVER (
          PARTITION BY trace_id
          ORDER BY (parent_span_id IS NULL) DESC, start_time_unix_nano ASC NULLS LAST, span_id ASC
        ) AS rn
        FROM candidates c
      ) ranked
      WHERE rn = 1
    ),
    aggregated AS (
      SELECT
        trace_id,
        MAX(`timestamp`) AS ts,
        MIN(start_time_unix_nano) AS start_ns,
        MAX(end_time_unix_nano) AS end_ns,
        CASE WHEN COUNT(service_name) = 0 THEN NULL
          ELSE array_sort(array_distinct(array_filter(x -> x IS NOT NULL, array_agg(service_name))))
        END AS service_set,
        COUNT(*) AS span_count,
        SUM(CASE WHEN status_code = 2 THEN 1 ELSE 0 END) AS error_count
      FROM candidates
      GROUP BY trace_id
    )
    SELECT
      a.trace_id, a.ts, r.span_id, r.name, r.service_name,
      COALESCE(r.service_namespace, ''), COALESCE(r.deployment_environment, ''), r.kind,
      a.start_ns, a.end_ns, CAST(a.end_ns - a.start_ns AS DOUBLE) / 1000000.0,
      r.status_code, r.status_message, a.service_set, a.span_count, a.error_count,
      #{literal(now)}
    FROM aggregated a
    JOIN roots r ON r.trace_id = a.trace_id
    """
  end

  defp spans, do: Env.table("otel_traces")
  defp summaries, do: Env.table("otel_trace_summaries")

  defp day_floor(%DateTime{} = instant),
    do: DateTime.add(instant, -@candidate_floor_seconds, :second)

  # A naive UTC DATETIME literal with microseconds.
  defp literal(%DateTime{} = instant) do
    naive = instant |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()
    {micros, _precision} = naive.microsecond
    fraction = micros |> Integer.to_string() |> String.pad_leading(6, "0")
    "'" <> Calendar.strftime(naive, "%Y-%m-%d %H:%M:%S") <> "." <> fraction <> "'"
  end

  defp run(sql, opts) do
    case Keyword.get(opts, :query) do
      query when is_function(query, 1) -> query.(sql)
      nil -> Query.execute(sql, Keyword.take(opts, [:timeout]))
    end
  end

  defp single([[value]]), do: value
  defp single(_rows), do: nil

  defp to_datetime(%DateTime{} = value), do: value
  defp to_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp to_datetime(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end

  defp to_datetime(_value), do: nil
end
