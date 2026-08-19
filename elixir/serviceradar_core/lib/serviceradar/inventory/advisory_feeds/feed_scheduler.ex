defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedScheduler do
  @moduledoc """
  Boot-time scheduler GenServer that keeps the advisory feed worker and the
  staging cleanup worker enqueued, mirroring the other
  `ServiceRadar.ObanEnsureScheduled`-based schedulers.

  Staging cleanup is a real Oban job (`StagingCleanupWorker`). The scheduler
  only seeds it; leftover nist-nvd2 extracts must not depend on a successful
  load, because Oban timeouts kill `FeedWorker` with `:kill`.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [
      ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker,
      ServiceRadar.Inventory.AdvisoryFeeds.StagingCleanupWorker
    ],
    label: "Advisory feed scheduling",
    tick: :schedule,
    named_start?: true

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end
end
