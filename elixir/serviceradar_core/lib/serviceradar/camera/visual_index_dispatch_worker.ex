defmodule ServiceRadar.Camera.VisualIndexDispatchWorker do
  @moduledoc """
  Relays the visual index job outbox (`platform.camera_visual_index_jobs`) onto
  NATS JetStream once per cron tick (`ServiceRadar.Jobs.CoreCrontab`).

  Each run is one bounded `ServiceRadar.Camera.VisualIndexDispatcher.relay/1`.
  The Cron plugin inserts ticks only on the Oban leader, and the uniqueness
  below covers a running tick, so replicas never relay concurrently; a relay
  that overlaps one anyway is still safe (see `relay/1`).

  The `:maintenance` queue runs only in core, whose NATS identity may publish
  the job subjects.
  """

  use Oban.Worker,
    queue: :maintenance,
    # A failed tick is not retried: the next tick relays the same outbox rows.
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  alias ServiceRadar.Camera.VisualIndexDispatcher

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    if VisualIndexDispatcher.deployment_enabled?(), do: relay(), else: :ok
  end

  defp relay do
    {:ok, summary} = VisualIndexDispatcher.relay()

    if summary.publish_error do
      Logger.warning(
        "Visual index relay stopped at a failed publish; jobs stay pending until the next tick",
        reason: inspect(summary.publish_error),
        dispatched: summary.dispatched_count,
        retried: summary.retried_count
      )
    end

    if summary.failed_count > 0, do: {:error, summary}, else: :ok
  end
end
