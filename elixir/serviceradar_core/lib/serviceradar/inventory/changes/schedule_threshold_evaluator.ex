defmodule ServiceRadar.Inventory.Changes.ScheduleThresholdEvaluator do
  @moduledoc """
  Ash change that schedules the interface threshold worker when thresholds are enabled.

  When an interface setting is created or updated with `threshold_enabled: true`,
  this change ensures that the InterfaceThresholdWorker is scheduled to evaluate
  threshold conditions.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Inventory.InterfaceThresholdWorker

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      schedule_if_enabled(record)
      {:ok, record}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp schedule_if_enabled(record) do
    if record.threshold_enabled do
      schedule_threshold_evaluator(record)
    end
  end

  defp schedule_threshold_evaluator(record) do
    case InterfaceThresholdWorker.ensure_scheduled() do
      {:ok, :already_scheduled} ->
        Logger.debug("Interface threshold evaluator already scheduled")

      {:ok, _job} ->
        Logger.info("Scheduled interface threshold evaluator",
          device_id: record.device_id,
          interface_uid: record.interface_uid
        )

      {:error, :oban_unavailable} ->
        Logger.debug("Interface threshold evaluator scheduling deferred (Oban unavailable)",
          device_id: record.device_id,
          interface_uid: record.interface_uid
        )

      {:error, {:oban_unavailable, message}} ->
        Logger.debug("Interface threshold evaluator scheduling deferred (Oban unavailable)",
          device_id: record.device_id,
          interface_uid: record.interface_uid,
          reason: message
        )

      {:error, reason} ->
        Logger.error("Failed to schedule interface threshold evaluator",
          device_id: record.device_id,
          interface_uid: record.interface_uid,
          reason: inspect(reason)
        )
    end
  end
end
