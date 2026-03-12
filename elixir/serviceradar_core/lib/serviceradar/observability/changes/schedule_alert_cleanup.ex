defmodule ServiceRadar.Observability.Changes.ScheduleAlertCleanup do
  @moduledoc """
  Ash change that schedules alert state cleanup when a stateful alert rule is created.

  When a stateful alert rule is created, this change ensures that the
  StatefulAlertCleanupWorker is scheduled to clean up stale alert rule
  state snapshots.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Observability.StatefulAlertCleanupWorker
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      schedule_cleanup(record)
      {:ok, record}
    end)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp schedule_cleanup(record) do
    if ObanSupport.available?() do
      case StatefulAlertCleanupWorker.ensure_scheduled() do
        {:ok, :already_scheduled} ->
          Logger.debug("Alert cleanup already scheduled")

        {:ok, _job} ->
          Logger.info("Scheduled alert cleanup",
            rule_id: record.id
          )

        {:error, reason} ->
          Logger.error("Failed to schedule alert cleanup",
            rule_id: record.id,
            reason: inspect(reason)
          )
      end
    else
      Logger.debug("Skipping alert cleanup scheduling because Oban is unavailable",
        rule_id: record.id
      )
    end
  end
end
