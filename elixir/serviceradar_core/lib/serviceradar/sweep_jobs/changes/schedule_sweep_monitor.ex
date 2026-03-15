defmodule ServiceRadar.SweepJobs.Changes.ScheduleSweepMonitor do
  @moduledoc """
  Ash change that schedules sweep-related workers when a sweep group is created or enabled.

  When a sweep group is created with `enabled: true` or is enabled via an update,
  this change ensures that:
  - SweepMonitorWorker is scheduled to monitor for missed sweeps
  - SweepDataCleanupWorker is scheduled to clean up old sweep data
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.SweepJobs.SweepDataCleanupWorker
  alias ServiceRadar.SweepJobs.SweepMonitorWorker

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, &schedule_if_enabled/1)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp schedule_if_enabled(record) do
    if record.enabled do
      schedule_monitor(record)
      schedule_cleanup(record)
    end
  end

  defp schedule_monitor(record) do
    case SweepMonitorWorker.ensure_scheduled() do
      {:ok, :already_scheduled} ->
        Logger.debug("Sweep monitor already scheduled")

      {:ok, _job} ->
        Logger.info("Scheduled sweep monitor",
          sweep_group_id: record.id
        )

      {:error, :oban_unavailable} ->
        Logger.debug("Sweep monitor scheduling deferred (Oban unavailable)",
          sweep_group_id: record.id,
          note: "sweep schedule reconciler will enqueue when available"
        )

      {:error, {:oban_unavailable, message}} ->
        Logger.debug("Sweep monitor scheduling deferred (Oban unavailable)",
          sweep_group_id: record.id,
          reason: message,
          note: "sweep schedule reconciler will enqueue when available"
        )

      {:error, reason} ->
        Logger.error("Failed to schedule sweep monitor",
          sweep_group_id: record.id,
          reason: inspect(reason)
        )
    end
  end

  defp schedule_cleanup(record) do
    case SweepDataCleanupWorker.ensure_scheduled() do
      {:ok, :already_scheduled} ->
        Logger.debug("Sweep data cleanup already scheduled")

      {:ok, _job} ->
        Logger.info("Scheduled sweep data cleanup",
          sweep_group_id: record.id
        )

      {:error, :oban_unavailable} ->
        Logger.debug("Sweep data cleanup scheduling deferred (Oban unavailable)",
          sweep_group_id: record.id,
          note: "sweep schedule reconciler will enqueue when available"
        )

      {:error, {:oban_unavailable, message}} ->
        Logger.debug("Sweep data cleanup scheduling deferred (Oban unavailable)",
          sweep_group_id: record.id,
          reason: message,
          note: "sweep schedule reconciler will enqueue when available"
        )

      {:error, reason} ->
        Logger.error("Failed to schedule sweep data cleanup",
          sweep_group_id: record.id,
          reason: inspect(reason)
        )
    end
  end
end
