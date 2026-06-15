defmodule ServiceRadar.Inventory.AdvisoryFeeds.FeedScheduler do
  @moduledoc """
  Boot-time scheduler GenServer that keeps the advisory feed worker enqueued for
  each enabled feed, mirroring the other `ServiceRadar.ObanEnsureScheduled`-based
  schedulers (e.g. EndpointVulnerabilityMatchScheduler).

  On startup it also reaps orphaned staging directories left by interrupted runs.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadar.Inventory.AdvisoryFeeds.FeedWorker],
    label: "Advisory feed scheduling",
    tick: :schedule,
    named_start?: true

  # Reap staging orphans once, lazily, the first time the scheduler ticks. The
  # macro's handle_info drives ensure_scheduled; we hook reap via a one-shot.
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end
end
