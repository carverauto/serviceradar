defmodule ServiceRadar.EventWriter.LifecycleAdmissionDrainWorker do
  @moduledoc """
  Admits lifecycle occurrences left in `platform.lifecycle_pending_admissions`.

  EventWriter admits a series' pending occurrences after each batch that
  touches the series. When a source message is dead-lettered at its final
  delivery and the series receives no later message, nothing else would retry
  its pending rows. This worker drains the longest-waiting series, each in
  `seq` order, a bounded number per run.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals

  require Logger

  @series_per_run 200

  @impl Oban.Worker
  def perform(_job) do
    case AnalyticsSignals.drain_pending_admissions(@series_per_run) do
      0 -> :ok
      count -> Logger.info("Admitted pending lifecycle alert evaluations", count: count)
    end

    :ok
  end
end
