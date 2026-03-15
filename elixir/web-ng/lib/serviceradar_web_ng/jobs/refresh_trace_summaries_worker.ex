defmodule ServiceRadarWebNG.Jobs.RefreshTraceSummariesWorker do
  @moduledoc """
  Oban worker that incrementally refreshes the otel_trace_summaries table.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Jobs.RefreshTraceSummariesWorker

  @impl Oban.Worker
  def perform(job) do
    RefreshTraceSummariesWorker.perform(job)
  end

  defdelegate upsert_sql, to: RefreshTraceSummariesWorker
  defdelegate cleanup_batch_sql, to: RefreshTraceSummariesWorker
end
