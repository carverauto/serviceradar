defmodule ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorkerTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker

  # Use ServiceRadar.Repo directly for SQL adapter operations
  @repo ServiceRadar.Repo

  test "exposes refresh SQL" do
    assert RefreshTraceSummariesWorker.refresh_sql() ==
             "REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries"
  end

  test "returns error when view is missing" do
    assert {:error, _} = RefreshTraceSummariesWorker.perform(%Oban.Job{args: %{}})
  end

  test "refreshes the materialized view when present" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(@repo, fn ->
      Ecto.Adapters.SQL.query!(@repo, "DROP MATERIALIZED VIEW IF EXISTS otel_trace_summaries", [])

      Ecto.Adapters.SQL.query!(
        @repo,
        "CREATE MATERIALIZED VIEW otel_trace_summaries AS SELECT 1 AS id",
        []
      )

      Ecto.Adapters.SQL.query!(
        @repo,
        "CREATE UNIQUE INDEX otel_trace_summaries_id_idx ON otel_trace_summaries (id)",
        []
      )

      assert :ok = RefreshTraceSummariesWorker.perform(%Oban.Job{args: %{}})

      Ecto.Adapters.SQL.query!(@repo, "DROP MATERIALIZED VIEW IF EXISTS otel_trace_summaries", [])
    end)
  end
end
