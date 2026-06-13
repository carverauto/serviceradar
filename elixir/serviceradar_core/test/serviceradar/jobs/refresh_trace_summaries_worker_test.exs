defmodule ServiceRadar.Jobs.RefreshTraceSummariesWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Jobs.RefreshTraceSummariesWorker

  test "uses bounded ingest chunks for high-volume trace streams" do
    assert RefreshTraceSummariesWorker.ingest_chunk_seconds() == 300
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
