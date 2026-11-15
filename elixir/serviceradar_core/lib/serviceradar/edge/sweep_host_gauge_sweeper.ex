defmodule ServiceRadar.Edge.SweepHostGaugeSweeper do
  @moduledoc """
  Republishes the per-host gauges of leased sweep batches whose committed publish never
  completed (`ServiceRadar.Edge.SweepHostGauges.republish_stale/1`): a marker older than
  the grace period, up to a bounded number per pass. Scheduled every minute from
  `ServiceRadar.Jobs.CoreCrontab`; one pass runs at a time.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Edge.SweepHostGauges

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case SweepHostGauges.republish_stale() do
      0 -> :ok
      count -> Logger.info("Republished leased sweep host gauges", batches: count)
    end

    :ok
  end
end
