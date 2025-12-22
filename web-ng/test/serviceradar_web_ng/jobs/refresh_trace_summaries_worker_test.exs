defmodule ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorkerTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker

  test "exposes refresh SQL" do
    assert RefreshTraceSummariesWorker.refresh_sql() ==
             "REFRESH MATERIALIZED VIEW CONCURRENTLY otel_trace_summaries"
  end

  test "returns error when view is missing" do
    assert {:error, _} = RefreshTraceSummariesWorker.perform(%Oban.Job{args: %{}})
  end
end
