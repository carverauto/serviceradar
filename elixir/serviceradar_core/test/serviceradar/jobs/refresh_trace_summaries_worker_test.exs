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

      # Values come from the root span (parent_span_id IS NULL), defaulting
      # to '' when the trace has no root span in the window
      assert sql =~
               "COALESCE(max(t.service_namespace) FILTER (WHERE t.parent_span_id IS NULL), '')"

      assert sql =~
               "COALESCE(max(t.deployment_environment) FILTER (WHERE t.parent_span_id IS NULL), '')"

      # Conflict update refreshes both columns
      assert sql =~ "root_service_namespace = EXCLUDED.root_service_namespace"
      assert sql =~ "deployment_environment = EXCLUDED.deployment_environment"

      # Change detection includes both columns
      assert sql =~
               "otel_trace_summaries.root_service_namespace IS DISTINCT FROM EXCLUDED.root_service_namespace"

      assert sql =~
               "otel_trace_summaries.deployment_environment IS DISTINCT FROM EXCLUDED.deployment_environment"
    end
  end
end
