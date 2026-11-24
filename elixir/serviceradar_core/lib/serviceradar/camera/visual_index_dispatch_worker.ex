defmodule ServiceRadar.Camera.VisualIndexDispatchWorker do
  @moduledoc """
  Relays the visual index job outbox (`platform.camera_visual_index_jobs`) onto
  NATS JetStream immediately when live blocks seal or archive verification
  completes, with the cron tick (`ServiceRadar.Jobs.CoreCrontab`) acting as a
  reconciliation safety net.

  Each run is one bounded `ServiceRadar.Camera.VisualIndexDispatcher.relay/1`.
  Uniqueness over `:available` and `:scheduled` coalesces concurrent nudges and
  cron ticks without stalling the relay if a running tick is orphaned by a hard
  kill; an overlapping relay is safe (see `relay/1`).

  The `:maintenance` queue runs only in core, whose NATS identity may publish
  the job subjects.
  """

  use Oban.Worker,
    queue: :maintenance,
    # A failed tick is not retried: the next nudge or cron tick relays the same outbox rows.
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled]]

  alias ServiceRadar.Camera.VisualIndexDispatcher

  require Logger

  @doc """
  Enqueues an immediate `VisualIndexDispatchWorker` run when visual indexing is
  enabled for this deployment.

  Oban uniqueness (`states: [:available, :scheduled]`) coalesces concurrent
  nudges into a single pending job without blocking on an executing run.
  """
  @spec enqueue(keyword()) :: {:ok, Oban.Job.t()} | :noop | {:error, term()}
  def enqueue(opts \\ []) when is_list(opts) do
    enabled_fn = Keyword.get(opts, :enabled_fn, &VisualIndexDispatcher.deployment_enabled?/0)
    insert_fn = Keyword.get(opts, :insert_fn, &default_insert/1)

    if enabled_fn.() do
      insert_fn.(new(%{}))
    else
      :noop
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    if VisualIndexDispatcher.deployment_enabled?(), do: relay(), else: :ok
  end

  defp default_insert(changeset) do
    case Oban.Registry.whereis(Oban) do
      nil -> :noop
      _pid -> Oban.insert(changeset)
    end
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
