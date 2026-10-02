defmodule ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorkerTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker

  @moduletag :web_ng_shared_fixture_db

  # Use ServiceRadar.Repo directly for SQL adapter operations
  @repo ServiceRadar.Repo

  test "returns ok when tables are missing" do
    assert :ok = RefreshTraceSummariesWorker.perform(%Oban.Job{args: %{}})
  end

  test "performs incremental upsert when table exists with data" do
    # Keep the shared fixture's table and dependent objects inside DataCase's
    # transaction so the sandbox restores them when this test exits.
    SQL.query!(@repo, "DROP TABLE IF EXISTS otel_trace_summaries CASCADE", [])

    # Create the summaries table
    SQL.query!(
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
  end
end
