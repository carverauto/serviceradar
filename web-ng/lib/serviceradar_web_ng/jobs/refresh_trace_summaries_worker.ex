defmodule ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker do
  @moduledoc """
  Oban worker that refreshes the otel_trace_summaries materialized view.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(job) do
    ServiceRadar.Jobs.RefreshTraceSummariesWorker.perform(job)
  end

  defdelegate refresh_sql, to: ServiceRadar.Jobs.RefreshTraceSummariesWorker
end
