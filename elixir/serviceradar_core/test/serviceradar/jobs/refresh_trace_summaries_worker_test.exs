defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorkerTest do
  use ExUnit.Case, async: false

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
end
