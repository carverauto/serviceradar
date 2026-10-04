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

  ## Warehouse

  With StarRocks enabled, EventWriter writes spans to the warehouse only, so
  the summaries are derived there: every statement that reads spans or writes
  summaries goes through `ServiceRadar.Analytics.StarRocks.TraceSummaries`
  instead, with the same meaning. The watermark and the advisory lock stay in
  CNPG, since they are control-plane state and a run is still one transaction
  there. The warehouse summary table is pruned to the StarRocks traces
  retention (`SERVICERADAR_STARROCKS_RETENTION_DAYS_TRACES`), not this worker's
  `retention_days`, which governs the CNPG table.

  ## Scheduling and the trailing refresh

  The job is enqueued by the `*/2` cron, by the EventWriter `otel_traces`
  processor after every span batch it writes, and by operators. Uniqueness
  over `:incomplete` keeps at most one job pending or running, so a burst of
  ingest enqueues coalesces into that job instead of piling up.

  A running job blocks inserts too, so a batch committed while a run is
  executing cannot enqueue a refresh of its own. The run schedules it instead:
  after committing, it looks for spans ingested after the watermark it just
  wrote and, if there are any, returns `{:snooze, 1}`. Snoozing reschedules
  this same row, so there is exactly one follow-up and later enqueues keep
  coalescing into it. The probe compares against the watermark rather than
  the run's upper bound because `created_at` is stamped before the batch
  commits, so a late commit can land inside the window the run already
  scanned. What the probe cannot see (a batch committed between the probe and
  Oban recording the run as finished, or one stamped behind rows the run
  already processed) waits for the next enqueue; the cron bounds that delay
  and the watermark overlap re-scans those rows.

  Oban counts every snooze as an attempt, so `backoff/1` discounts them;
  otherwise a failure after a long stream of follow-ups would be retried days
  later, and the retryable job would block every refresh until then.

  ## Orphaned runs

  A node that stops mid-run (rolling deploy, eviction, drain, OOMKill) leaves
  this job's row `executing`, and because uniqueness covers `:incomplete` that
  row blocks every refresh -- ingest enqueues and the cron alike -- until
  something rescues it. The generic rescuers go by age alone and wait 240
  minutes, so an ordinary deploy could leave trace summaries hours stale.

  This worker does not have to guess. `perform/1` runs the whole refresh in one
  transaction that first takes the `trace_summaries` advisory transaction lock,
  so a killed run is rolled back by Postgres: the lock is released and the
  watermark does not advance. A row that is `executing` while nobody holds that
  lock is therefore not running. `rescue_orphaned/1` makes that proof and puts
  such rows back to `available`; it is called from `enqueue/0` when an ingest
  insert collides with an executing row (throttled per node), and on every pass
  of `ServiceRadar.Jobs.ReapStalePeriodicJobsWorker` through the
  `ServiceRadar.Jobs.OrphanRescue` behaviour.

  A live run can hold the row `executing` without holding the lock at two
  points, and `orphan_grace_seconds/0` covers both:

    * before `perform/1` acquires the lock (Oban has marked the row executing,
      the run is still checking out a connection), which `attempted_at` must
      be older than the grace to rule out; and
    * after the transaction commits and before Oban records the outcome (the
      trailing-refresh probe, bounded by `probe_timeout_ms/0`), which the
      watermark's `updated_at` rules out: a run that committed within the grace
      may still be finishing, so nothing is rescued until the watermark has been
      quiet for the whole grace. The grace is never shorter than that probe's
      timeout.

  A run whose lock is held is never rescued, however old it is. A backend whose
  client vanished without closing its socket keeps the lock until Postgres
  notices, so that case still falls back to the age-based rescuers.
  """

  @behaviour ServiceRadar.Jobs.OrphanRescue

  @max_attempts 3
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: @max_attempts,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Analytics.StarRocks.Retention
  alias ServiceRadar.Analytics.StarRocks.TraceSummaries, as: WarehouseSummaries
  alias ServiceRadar.Observability.OtelPubSub
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @watermark_key "trace_summaries"
  @worker_name inspect(__MODULE__)

  # One refresh at a time. Transaction-scoped, so Postgres releases it when a
  # run commits, rolls back, or loses its connection -- which is what lets
  # rescue_orphaned/1 treat a free lock as proof that no run is in flight.
  @try_refresh_lock_sql "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))"

  # A run committed (and wrote the watermark) within the grace: it may still be
  # finishing its trailing-refresh probe with the lock already released.
  @watermark_written_within_sql """
  SELECT EXISTS(
    SELECT 1
    FROM observability_watermarks
    WHERE key = $1 AND updated_at > NOW() - ($2::int * INTERVAL '1 second')
  )
  """

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

  # Spans ingested after the watermark a run just wrote: the run missed them,
  # so it schedules a trailing refresh (see the moduledoc).
  @ingested_after_watermark_sql """
  SELECT EXISTS(
    SELECT 1
    FROM otel_traces
    WHERE created_at > $1 AND trace_id IS NOT NULL
  )
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
  # Delay before the trailing refresh, so it coalesces the batches that
  # arrive right behind a run.
  @trailing_refresh_delay_seconds 1
  @default_cleanup_batch_size 5_000
  @default_cleanup_time_budget_ms 10_000
  @default_retention_days 3
  @default_probe_timeout_ms 30_000
  @default_upsert_timeout_ms 120_000
  @default_watermark_timeout_ms 30_000
  @default_cleanup_timeout_ms 60_000
  @default_remaining_estimate_timeout_ms 30_000
  @default_orphan_grace_seconds 60
  @default_orphan_probe_interval_seconds 30
  # Slack added to the trailing-probe timeout when flooring the grace.
  @orphan_grace_probe_margin_seconds 10
  @orphan_probe_throttle_key {__MODULE__, :orphan_probe_last_ms}
  @warehouse_prune_throttle_key {__MODULE__, :warehouse_prune_last_ms}
  @warehouse_prune_interval_ms 3_600_000
  @min_signed_64 -0x8000000000000000

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

  @doc """
  How long a row must have been executing, and the watermark quiet, before
  `rescue_orphaned/1` may treat a free refresh lock as proof the run is dead.

  Configured with `:orphan_grace_seconds` (default #{@default_orphan_grace_seconds}),
  and never shorter than the trailing-refresh probe timeout plus
  #{@orphan_grace_probe_margin_seconds}s, because a live run spends up to that long
  after its commit with the lock released (see the moduledoc).
  """
  @spec orphan_grace_seconds() :: pos_integer()
  def orphan_grace_seconds do
    configured = config_positive_integer(:orphan_grace_seconds, @default_orphan_grace_seconds)
    probe_floor = div(probe_timeout_ms() + 999, 1000) + @orphan_grace_probe_margin_seconds

    max(configured, probe_floor)
  end

  @doc """
  Minimum interval between orphan probes made from `enqueue/0` on one node.

  Configured with `:orphan_probe_interval_ms`; defaults to
  #{@default_orphan_probe_interval_seconds}s. Every span batch enqueues a refresh, so
  without it a long live run would be probed once per batch.
  """
  @spec orphan_probe_interval_ms() :: pos_integer()
  def orphan_probe_interval_ms do
    config_positive_integer(
      :orphan_probe_interval_ms,
      to_timeout(second: @default_orphan_probe_interval_seconds)
    )
  end

  @doc """
  Request a refresh, as the EventWriter does after each span batch.

  Uniqueness coalesces the request into any pending or running job. When it
  collides with a row that has been executing for longer than the grace, that
  row may be an orphan blocking every refresh, so this also runs
  `rescue_orphaned/1` -- at most once per `orphan_probe_interval_ms/0` on this
  node, and never for a row the probe finds live. A rescued row is `available`
  again and is the refresh this call asked for, so nothing is re-inserted.
  """
  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue do
    with {:ok, job} <- %{} |> new() |> ObanSupport.safe_insert() do
      maybe_rescue_conflict(job)
      {:ok, job}
    end
  end

  defp maybe_rescue_conflict(%Oban.Job{conflict?: true, state: "executing"} = job) do
    if executing_past_grace?(job) and orphan_probe_permitted?() do
      case rescue_orphaned() do
        {:ok, _rescued} ->
          :ok

        {:error, reason} ->
          Logger.warning("Trace summaries orphan probe failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp maybe_rescue_conflict(_job), do: :ok

  defp executing_past_grace?(%Oban.Job{attempted_at: %DateTime{} = attempted_at}) do
    DateTime.diff(DateTime.utc_now(), attempted_at, :second) >= orphan_grace_seconds()
  end

  defp executing_past_grace?(_job), do: false

  # Lock-free per-node throttle shared by every EventWriter process: the caller
  # whose compare-and-swap advances the timestamp is the one that probes.
  defp orphan_probe_permitted? do
    ref = orphan_probe_throttle()
    now = System.monotonic_time(:millisecond)
    last = :atomics.get(ref, 1)

    now - last >= orphan_probe_interval_ms() and
      :atomics.compare_exchange(ref, 1, last, now) == :ok
  end

  defp orphan_probe_throttle do
    case :persistent_term.get(@orphan_probe_throttle_key, nil) do
      nil ->
        # Created once per node. Starts at the minimum so the first probe is
        # permitted; monotonic time can be negative, so 0 is not "never".
        ref = :atomics.new(1, signed: true)
        :atomics.put(ref, 1, @min_signed_64)
        :persistent_term.put(@orphan_probe_throttle_key, ref)
        ref

      ref ->
        ref
    end
  end

  @doc """
  Put this worker's orphaned `executing` rows back to `available`.

  A row is an orphan when it was attempted more than `orphan_grace_seconds/0`
  ago, nobody holds the refresh advisory lock, and the watermark has not been
  written within the grace. The lock is probed with the same
  `pg_try_advisory_xact_lock` the run takes, inside this function's own short
  transaction: acquiring it proves no run holds it, and it is released when that
  transaction commits. A row whose lock is held is never touched.

  Rescue is Lifeline's -- the same row goes back to `available`, so uniqueness
  keeps coalescing into it and nothing races a fresh insert -- with one change:
  `max_attempts` is raised by one, exactly as a snooze raises it. A deploy is not
  the job's failure, so the killed attempt is neither charged against
  `max_attempts` (which would strand a row on its last attempt, since Oban only
  fetches rows with `attempt < max_attempts`) nor counted by `backoff/1`, which
  already discounts every raise as a snooze. The row's `errors` records why.

  Options: `:grace_seconds` overrides the grace, `:now` the clock the row age is
  measured against. Never raises; a failure is returned as `{:error, reason}`.

  ## Races

    * A run that starts after the probe commits sees the rescued row, or its own
      row, exactly as any run would: it takes the lock or snoozes on
      `:refresh_in_progress`. The probe holds the lock only for its own
      transaction, so a run that starts during it snoozes for a second.
    * Two probes (two nodes, or the reaper and an ingest enqueue) serialize on
      the lock: the second fails to acquire it and rescues nothing. Candidate
      rows are locked `FOR UPDATE SKIP LOCKED` and the update re-checks
      `state = 'executing'`, so a row Oban finished meanwhile is left alone.
    * A run that was live after all (it outlasted the grace before reaching the
      lock) runs a redundant refresh alongside the rescued row. The lock
      serializes them, the refresh is idempotent, and they share one row, so
      the last to finish records its outcome and no second job is created.
  """
  @impl ServiceRadar.Jobs.OrphanRescue
  @spec rescue_orphaned(keyword()) ::
          {:ok, [ServiceRadar.Jobs.ReapStalePeriodicJobsWorker.job_ref()]} | {:error, term()}
  def rescue_orphaned(opts \\ []) do
    grace_seconds = Keyword.get_lazy(opts, :grace_seconds, &orphan_grace_seconds/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cutoff = DateTime.add(now, -grace_seconds, :second)

    result =
      Repo.transact(
        fn ->
          case executing_candidates(cutoff) do
            [] -> {:ok, []}
            ids -> {:ok, rescue_if_orphaned(ids, grace_seconds)}
          end
        end,
        timeout: probe_timeout_ms()
      )

    with {:ok, [_ | _] = rescued} <- result do
      Logger.warning(
        "Rescued orphaned trace summaries refresh: executing with the refresh lock free",
        rescued_jobs: rescued,
        orphan_grace_seconds: grace_seconds
      )
    end

    result
  rescue
    error -> {:error, error}
  end

  defp executing_candidates(cutoff) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^@worker_name,
        where: j.state == "executing",
        where: not is_nil(j.attempted_at) and j.attempted_at < ^cutoff,
        lock: "FOR UPDATE SKIP LOCKED",
        select: j.id
      ),
      prefix: ObanSupport.prefix()
    )
  end

  defp rescue_if_orphaned(ids, grace_seconds) do
    if refresh_lock_free?() and not watermark_written_within?(grace_seconds) do
      mark_available(ids)
    else
      []
    end
  end

  defp refresh_lock_free? do
    %{rows: [[acquired]]} =
      SQL.query!(Repo, @try_refresh_lock_sql, [@watermark_key], timeout: probe_timeout_ms())

    acquired == true
  end

  defp watermark_written_within?(grace_seconds) do
    %{rows: [[written]]} =
      SQL.query!(Repo, @watermark_written_within_sql, [@watermark_key, grace_seconds],
        timeout: probe_timeout_ms()
      )

    written == true
  end

  defp mark_available(ids) do
    reason =
      "orphaned: executing with the #{@watermark_key} refresh lock free; " <>
        "rescued to available without charging the attempt"

    {_count, rescued} =
      Repo.update_all(
        from(j in Oban.Job,
          where: j.id in ^ids and j.state == "executing",
          update: [
            set: [
              state: "available",
              max_attempts: fragment("GREATEST(?, ?) + 1", j.max_attempts, j.attempt),
              errors:
                fragment(
                  "? || jsonb_build_object('attempt', ?, 'at', now(), 'error', ?::text)",
                  j.errors,
                  j.attempt,
                  ^reason
                )
            ]
          ],
          select: %{
            id: j.id,
            worker: j.worker,
            queue: j.queue,
            attempt: j.attempt,
            max_attempts: j.max_attempts
          }
        ),
        [],
        prefix: ObanSupport.prefix()
      )

    rescued
  end

  @impl Oban.Worker
  def perform(_job) do
    result =
      Repo.transact(
        fn ->
          case SQL.query!(Repo, @try_refresh_lock_sql, [@watermark_key]) do
            %{rows: [[true]]} -> refresh_summaries()
            %{rows: [[false]]} -> {:error, :refresh_in_progress}
          end
        end,
        timeout: :infinity
      )

    case result do
      {:ok, %{changed: changed, watermark: watermark, window_end: window_end}} ->
        OtelPubSub.broadcast_trace_summaries(%{count: changed})

        if spans_ingested_after?(watermark, window_end) do
          {:snooze, @trailing_refresh_delay_seconds}
        else
          :ok
        end

      {:error, :refresh_in_progress} ->
        {:snooze, 1}

      {:error, _reason} = error ->
        error
    end
  end

  # Oban's documented snooze compensation: each snooze raised `max_attempts`
  # by one, so subtract them to back off by the real attempt count.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt, max_attempts: max_attempts} = job) do
    snoozes = max(max_attempts - @max_attempts, 0)

    Oban.Worker.backoff(%{job | attempt: max(attempt - snoozes, 1), max_attempts: @max_attempts})
  end

  defp refresh_summaries do
    now = DateTime.utc_now()
    watermark = read_watermark(now)
    window_start = DateTime.add(watermark, -@watermark_overlap_seconds, :second)

    with {:ok, changed} <- run_chunked_upsert(window_start, now),
         {:ok, new_watermark} <- advance_watermark(window_start, now),
         :ok <- cleanup_old_summaries() do
      Logger.info(
        "Refreshed otel_trace_summaries (ingest-time watermark)",
        watermark: DateTime.to_iso8601(watermark),
        window_end: DateTime.to_iso8601(now)
      )

      {:ok, %{changed: changed, watermark: new_watermark, window_end: now}}
    end
  rescue
    error ->
      Logger.error("Failed to refresh otel_trace_summaries: #{Exception.message(error)}")
      {:error, error}
  end

  defp read_watermark(now) do
    case SQL.query(Repo, @read_watermark_sql, [@watermark_key], timeout: watermark_timeout_ms()) do
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
    if warehouse?() do
      run_warehouse_upsert(window_start, window_end)
    else
      run_cnpg_upsert(window_start, window_end)
    end
  end

  # Spans live in the warehouse only when StarRocks is enabled, so their
  # summaries are derived there; see ServiceRadar.Analytics.StarRocks.TraceSummaries.
  defp run_warehouse_upsert(window_start, window_end) do
    with {:ok, true} <-
           WarehouseSummaries.any_ingested?(window_start, window_end, timeout: probe_timeout_ms()),
         {:ok, written} <-
           WarehouseSummaries.upsert(window_start, window_end, warehouse_retention_days(),
             timeout: upsert_timeout_ms()
           ) do
      {:ok, written}
    else
      {:ok, false} ->
        {:ok, 0}

      {:error, reason} = error ->
        Logger.error("Failed to upsert warehouse otel_trace_summaries: #{inspect(reason)}")
        error
    end
  end

  defp run_cnpg_upsert(window_start, window_end) do
    if window_has_ingested_spans?(window_start, window_end) do
      case SQL.query(
             Repo,
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

    case SQL.query(Repo, sql, [window_start, window_end], timeout: probe_timeout_ms()) do
      {:ok, %{rows: [[true]]}} -> true
      {:ok, _result} -> false
      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} -> false
      {:error, error} -> raise error
    end
  end

  defp spans_ingested_after?(watermark, window_end) do
    if warehouse?(),
      do: warehouse_spans_ingested_after?(watermark, window_end),
      else: cnpg_spans_ingested_after?(watermark)
  end

  defp warehouse_spans_ingested_after?(watermark, window_end) do
    case WarehouseSummaries.ingested_after?(watermark, window_end, timeout: probe_timeout_ms()) do
      {:ok, ingested?} ->
        ingested?

      {:error, reason} ->
        Logger.warning(
          "Trace summaries trailing-refresh probe failed; the cron will catch up: " <>
            inspect(reason)
        )

        false
    end
  end

  defp cnpg_spans_ingested_after?(watermark) do
    case SQL.query(Repo, @ingested_after_watermark_sql, [watermark], timeout: probe_timeout_ms()) do
      {:ok, %{rows: [[true]]}} ->
        true

      {:ok, _result} ->
        false

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        false

      {:error, error} ->
        Logger.warning(
          "Trace summaries trailing-refresh probe failed; the cron will catch up: " <>
            Exception.message(error)
        )

        false
    end
  end

  # Advance the watermark to the max created_at actually processed, falling
  # back to the run's upper bound when the window held no spans.
  defp advance_watermark(window_start, window_end) do
    new_watermark = max_ingested_at(window_start, window_end) || window_end

    case SQL.query(
           Repo,
           @write_watermark_sql,
           [@watermark_key, new_watermark],
           timeout: watermark_timeout_ms()
         ) do
      {:ok, _result} ->
        {:ok, new_watermark}

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        Logger.debug("observability_watermarks table missing; watermark not persisted")
        {:ok, new_watermark}

      {:error, error} ->
        Logger.error("Failed to persist trace summaries watermark: #{Exception.message(error)}")
        {:error, error}
    end
  end

  defp max_ingested_at(window_start, window_end) do
    if warehouse?() do
      case WarehouseSummaries.max_ingested_at(window_start, window_end,
             timeout: watermark_timeout_ms()
           ) do
        {:ok, max_created_at} -> max_created_at
        {:error, _reason} -> nil
      end
    else
      case SQL.query(
             Repo,
             @max_ingested_at_sql,
             [window_start, window_end],
             timeout: watermark_timeout_ms()
           ) do
        {:ok, %{rows: [[%DateTime{} = max_created_at]]}} ->
          max_created_at

        {:ok, %{rows: [[%NaiveDateTime{} = max_created_at]]}} ->
          DateTime.from_naive!(max_created_at, "Etc/UTC")

        _ ->
          nil
      end
    end
  end

  defp cleanup_old_summaries do
    if warehouse?(), do: prune_warehouse_summaries(), else: cleanup_cnpg_summaries()
  end

  # The warehouse summary table is not partitioned (a trace's timestamp moves
  # as late spans arrive), so its DELETE scans the whole table unlike the
  # CNPG path's bounded/batched cleanup below; throttled to at most once per
  # hour per node, and a failure here does not fail the refresh or block the
  # watermark from advancing since the upsert already committed independently.
  defp prune_warehouse_summaries do
    if warehouse_prune_permitted?() do
      retention_days = warehouse_retention_days()

      case WarehouseSummaries.prune(retention_days, timeout: cleanup_timeout_ms()) do
        {:ok, deleted} ->
          log_cleanup(deleted, retention_days, 0)

        {:error, reason} ->
          Logger.warning("Failed to prune warehouse otel_trace_summaries: #{inspect(reason)}")
      end
    end

    :ok
  end

  # Lock-free per-node throttle: the caller whose compare-and-swap advances
  # the timestamp is the one that prunes.
  defp warehouse_prune_permitted? do
    ref = warehouse_prune_throttle()
    now = System.monotonic_time(:millisecond)
    last = :atomics.get(ref, 1)

    now - last >= @warehouse_prune_interval_ms and
      :atomics.compare_exchange(ref, 1, last, now) == :ok
  end

  defp warehouse_prune_throttle do
    case :persistent_term.get(@warehouse_prune_throttle_key, nil) do
      nil ->
        ref = :atomics.new(1, signed: true)
        :atomics.put(ref, 1, @min_signed_64)
        :persistent_term.put(@warehouse_prune_throttle_key, ref)
        ref

      ref ->
        ref
    end
  end

  # Drain expired summary rows in batches until none remain or the time
  # budget for this run is exhausted.
  defp cleanup_cnpg_summaries do
    batch_size = cleanup_batch_size()
    retention_days = retention_days()
    deadline = System.monotonic_time(:millisecond) + cleanup_time_budget_ms()

    drain_cleanup(batch_size, retention_days, deadline, 0)
  end

  defp drain_cleanup(batch_size, retention_days, deadline, total_deleted) do
    case SQL.query(Repo, @cleanup_batch_sql, [batch_size, retention_days],
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
           Repo,
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

  defp warehouse?, do: Destination.enabled?()

  # The traces dataset's effective retention (Settings -> Data retention), so
  # summaries are pruned to the window the spans themselves are kept for.
  defp warehouse_retention_days, do: Retention.dataset_days(:traces)

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
