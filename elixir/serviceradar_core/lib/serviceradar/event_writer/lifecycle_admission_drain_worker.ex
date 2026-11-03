defmodule ServiceRadar.EventWriter.LifecycleAdmissionDrainWorker do
  @moduledoc """
  Admits lifecycle occurrences left in `platform.lifecycle_pending_admissions`.

  EventWriter admits a series' pending occurrences after each batch that
  touches the series. When a source message is dead-lettered at its final
  delivery and the series receives no later message, nothing else would retry
  its pending rows. Each run pages through the pending series longest-waiting
  first, admits each in `seq` order up to its first refusal and continues with
  the next series, so a series stuck behind a saturated rule does not starve
  the ones behind it. A run stops after 1,000 admissions or 30 seconds.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    case AnalyticsSignals.drain_pending_admissions() do
      0 -> :ok
      count -> Logger.info("Admitted pending lifecycle alert evaluations", count: count)
    end

    :ok
  end
end
