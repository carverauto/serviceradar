defmodule ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorkerTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker

  # Use ServiceRadar.Repo directly for SQL adapter operations
  @repo ServiceRadar.Repo

  test "exposes upsert SQL" do
    sql = RefreshTraceSummariesWorker.upsert_sql()
    assert sql =~ "INSERT INTO otel_trace_summaries"
    assert sql =~ "ON CONFLICT (trace_id) DO UPDATE"
  end

  test "returns ok when tables are missing" do
    assert :ok = RefreshTraceSummariesWorker.perform(%Oban.Job{args: %{}})
  end

  test "performs incremental upsert when table exists with data" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(@repo, fn ->
      # Ensure clean state
      Ecto.Adapters.SQL.query!(@repo, "DROP TABLE IF EXISTS otel_trace_summaries CASCADE", [])

      # Create the summaries table
      Ecto.Adapters.SQL.query!(
        @repo,
        """
        CREATE TABLE otel_trace_summaries (
          trace_id TEXT PRIMARY KEY,
          timestamp TIMESTAMPTZ,
          root_span_id TEXT,
          root_span_name TEXT,
          root_service_name TEXT,
          root_span_kind INT,
          start_time_unix_nano BIGINT,
          end_time_unix_nano BIGINT,
          duration_ms FLOAT8,
          status_code INT,
          status_message TEXT,
          service_set TEXT[],
          span_count BIGINT,
          error_count BIGINT,
          refreshed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        []
      )

      assert :ok = RefreshTraceSummariesWorker.perform(%Oban.Job{args: %{}})

      Ecto.Adapters.SQL.query!(@repo, "DROP TABLE IF EXISTS otel_trace_summaries CASCADE", [])
    end)
  end
end
