defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.TraceSummaries
  alias ServiceRadar.Jobs.RefreshTraceSummariesWorker

  setup do
    original_config = Application.get_env(:serviceradar_core, RefreshTraceSummariesWorker)

    on_exit(fn ->
      if is_nil(original_config) do
        Application.delete_env(:serviceradar_core, RefreshTraceSummariesWorker)
      else
        Application.put_env(:serviceradar_core, RefreshTraceSummariesWorker, original_config)
      end
    end)
  end

  test "uses bounded ingest chunks for high-volume trace streams" do
    assert RefreshTraceSummariesWorker.ingest_chunk_seconds() == 300
  end

  test "uses production-safe query timeout defaults" do
    Application.delete_env(:serviceradar_core, RefreshTraceSummariesWorker)

    assert RefreshTraceSummariesWorker.probe_timeout_ms() == 30_000
    assert RefreshTraceSummariesWorker.upsert_timeout_ms() == 120_000
    assert RefreshTraceSummariesWorker.watermark_timeout_ms() == 30_000
    assert RefreshTraceSummariesWorker.cleanup_timeout_ms() == 60_000
  end

  test "allows query timeouts to be overridden by runtime config" do
    Application.put_env(:serviceradar_core, RefreshTraceSummariesWorker,
      probe_timeout_ms: 45_000,
      upsert_timeout_ms: 180_000,
      watermark_timeout_ms: 40_000,
      cleanup_timeout_ms: 90_000
    )

    assert RefreshTraceSummariesWorker.probe_timeout_ms() == 45_000
    assert RefreshTraceSummariesWorker.upsert_timeout_ms() == 180_000
    assert RefreshTraceSummariesWorker.watermark_timeout_ms() == 40_000
    assert RefreshTraceSummariesWorker.cleanup_timeout_ms() == 90_000
  end

  test "backs off by real attempts, not by trailing-refresh snoozes" do
    # 40 snoozes then a first real failure: Oban has raised max_attempts to 43 and attempt to 41.
    # The default backoff would clamp that to attempt 19 and wait about six days.
    after_snoozes = %Oban.Job{attempt: 41, max_attempts: 43}
    first_failure = %Oban.Job{attempt: 1, max_attempts: 3}

    # 15s padding + 2^1, plus at most 10% jitter.
    assert RefreshTraceSummariesWorker.backoff(after_snoozes) in 17..18
    assert RefreshTraceSummariesWorker.backoff(first_failure) in 17..18
  end

  describe "upsert_sql/0" do
    test "populates root namespace and environment from the root span" do
      sql = RefreshTraceSummariesWorker.upsert_sql()

      # Insert column list carries the new summary columns
      assert sql =~ "root_service_namespace, deployment_environment"

      # Root naming flows from the chosen-root CTE; namespace/environment
      # default to '' when the root span lacks them.
      assert sql =~ "COALESCE(r.service_namespace, '')"
      assert sql =~ "COALESCE(r.deployment_environment, '')"

      # Conflict update refreshes both columns
      assert sql =~ "root_service_namespace = EXCLUDED.root_service_namespace"
      assert sql =~ "deployment_environment = EXCLUDED.deployment_environment"

      # Change detection includes both columns
      assert sql =~
               "otel_trace_summaries.root_service_namespace IS DISTINCT FROM EXCLUDED.root_service_namespace"

      assert sql =~
               "otel_trace_summaries.deployment_environment IS DISTINCT FROM EXCLUDED.deployment_environment"
    end

    test "falls back to the earliest span as root for orphan traces" do
      sql = RefreshTraceSummariesWorker.upsert_sql()

      # A roots CTE picks one representative root per trace.
      assert sql =~ "roots AS ("
      assert sql =~ "DISTINCT ON (trace_id)"

      # True root spans (parent_span_id IS NULL) win; otherwise the earliest
      # span (min start_time_unix_nano) stands in so root_* is never NULL.
      assert sql =~ "(t.parent_span_id IS NULL) AS is_root"

      # Ordering prefers true roots, then the earliest span (deterministic
      # tie-break on span_id). Whitespace-insensitive to survive reindentation.
      collapsed = String.replace(sql, ~r/\s+/, " ")

      assert collapsed =~
               "ORDER BY trace_id, is_root DESC, start_time_unix_nano ASC NULLS LAST, span_id ASC"

      # Root naming columns are sourced from the chosen root, not a
      # NULL-parent-only FILTER (which left orphan traces blank).
      assert sql =~ "r.name"
      assert sql =~ "r.service_name"
      refute sql =~ "FILTER (WHERE t.parent_span_id IS NULL)"
    end

    test "scans otel_traces once via a materialized wanted-trace CTE" do
      sql = RefreshTraceSummariesWorker.upsert_sql()

      # The wanted trace ids are collected once into a MATERIALIZED CTE so the
      # otel_traces hypertable is not re-scanned by a second IN-subquery.
      assert sql =~ "wanted AS MATERIALIZED ("
      assert sql =~ "JOIN wanted w ON w.trace_id = t.trace_id"

      # Per-trace aggregates are computed once from the shared candidates CTE.
      assert sql =~ "aggregated AS ("

      # The doubled `trace_id IN (SELECT ... FROM otel_traces ...)` scan is gone.
      refute sql =~ "t.trace_id IN ("

      # A 1-day timestamp floor enables TimescaleDB chunk exclusion without
      # dropping any span the retention window would keep.
      assert sql =~ "t.timestamp >= $2 - INTERVAL '1 day'"
    end
  end

  # With StarRocks enabled the worker runs these statements against the
  # warehouse. Their meaning was checked against a StarRocks Frontend; these
  # pin the parts that decide which rows they touch.
  describe "warehouse statements" do
    @from ~U[2026-01-15 10:00:00Z]
    @to ~U[2026-01-15 10:05:00.250000Z]
    @now ~U[2026-01-15 10:05:01Z]

    defp capture(result) do
      test = self()

      fn sql ->
        send(test, {:sql, sql})
        result
      end
    end

    test "instants are UTC microsecond literals, never the Frontend's NOW()" do
      sql = TraceSummaries.upsert_sql(@from, @to, 30, @now)

      assert sql =~ "created_at > '2026-01-15 10:00:00.000000'"
      assert sql =~ "created_at <= '2026-01-15 10:05:00.250000'"
      refute sql =~ "NOW()"
      # refreshed_at is stamped with the run's instant.
      assert sql =~ "'2026-01-15 10:05:01.000000'\nFROM aggregated a"
    end

    test "spans older than a day before the window, or outside retention, never enter a summary" do
      sql = TraceSummaries.upsert_sql(@from, @to, 30, @now)

      assert sql =~ "t.`timestamp` >= '2026-01-14 10:05:00.250000'"
      assert sql =~ "t.`timestamp` >= '2025-12-16 10:05:01.000000'"
    end

    test "the root is the true root span, else the earliest span" do
      sql = TraceSummaries.upsert_sql(@from, @to, 30, @now)

      assert sql =~
               "ORDER BY (parent_span_id IS NULL) DESC, start_time_unix_nano ASC NULLS LAST, span_id ASC"

      assert sql =~ "WHERE rn = 1"
    end

    test "probes read the window and report whether it held spans" do
      assert {:ok, true} =
               TraceSummaries.any_ingested?(@from, @to, query: capture({:ok, %{rows: [[1]]}}))

      assert_received {:sql, sql}
      assert sql =~ "LIMIT 1"
      assert sql =~ "`timestamp` >= '2026-01-14 10:05:00.250000'"

      assert {:ok, false} =
               TraceSummaries.any_ingested?(@from, @to, query: capture({:ok, %{rows: []}}))

      assert {:error, :down} =
               TraceSummaries.ingested_after?(@to, @to, query: capture({:error, :down}))
    end

    test "the trailing-refresh probe floors on the run's window end, not the watermark" do
      # A watermark far older than the window end must not loosen the floor:
      # any_ingested?/max_ingested_at, which decide whether the watermark can
      # advance, floor on `to`, so this probe has to agree with them.
      old_watermark = ~U[2026-01-10 00:00:00Z]

      assert {:ok, false} =
               TraceSummaries.ingested_after?(old_watermark, @to,
                 query: capture({:ok, %{rows: []}})
               )

      assert_received {:sql, sql}
      assert sql =~ "created_at > '2026-01-10 00:00:00.000000'"
      assert sql =~ "`timestamp` >= '2026-01-14 10:05:00.250000'"
      refute sql =~ "'2026-01-09 00:00:00.000000'"
    end

    test "the newest ingest time comes back as UTC, and an empty window as nil" do
      naive = ~N[2026-01-15 10:04:59.123456]

      assert {:ok, ~U[2026-01-15 10:04:59.123456Z]} =
               TraceSummaries.max_ingested_at(@from, @to,
                 query: capture({:ok, %{rows: [[naive]]}})
               )

      assert {:ok, ~U[2026-01-15 10:04:59.123456Z]} =
               TraceSummaries.max_ingested_at(@from, @to,
                 query: capture({:ok, %{rows: [["2026-01-15 10:04:59.123456"]]}})
               )

      assert {:ok, nil} =
               TraceSummaries.max_ingested_at(@from, @to, query: capture({:ok, %{rows: [[nil]]}}))
    end

    test "pruning deletes summaries older than the retention" do
      assert {:ok, 4} =
               TraceSummaries.prune(30,
                 now: @now,
                 query: capture({:ok, %{num_rows: 4, rows: []}})
               )

      assert_received {:sql, sql}
      assert sql =~ "DELETE FROM "
      assert sql =~ "otel_trace_summaries WHERE `timestamp` < '2025-12-16 10:05:01.000000'"
    end
  end
end
