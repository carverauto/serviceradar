defmodule ServiceRadarWebNG.Jobs.RefreshLogsSeverityStatsWorker do
  @moduledoc """
  Oban worker that refreshes the logs_severity_stats_5m continuous aggregate.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker

  @impl Oban.Worker
  def perform(job) do
    RefreshLogsSeverityStatsWorker.perform(job)
  end

  defdelegate refresh_sql, to: RefreshLogsSeverityStatsWorker
end
