defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Messages do
  @moduledoc false

  alias Ash.Error.Changes.StaleRecord
  alias Ash.Error.Forbidden
  alias Ash.Error.Invalid
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarWebNGWeb.Settings.NetworksLive.Index.CommandStatus

  @sweep_group_delete_fallback_message "Failed to delete sweep group. See the server log for details."
  @sweep_execution_cancel_fallback_message "Failed to cancel the scan. See the server log for details."

  def sweep_group_save_message(true) do
    if ObanSupport.available?() do
      "Sweep group saved"
    else
      "Sweep group saved. Scheduling is deferred until the scheduler is available."
    end
  end

  def sweep_group_save_message(false), do: "Sweep group saved"

  @doc """
  The delete confirmation for a sweep group, sized to what the delete discards.

  Deleting a group takes its executions and their per-host results with it, so
  the operator is told how much history that is while they can still decline.
  A group that has never run loses nothing and says so.
  """
  def sweep_group_delete_confirm_message(execution_count) when is_integer(execution_count) and execution_count > 0 do
    "Delete this sweep group? This also discards #{execution_count} #{pluralize(execution_count, "execution")} and the per-host results recorded for #{pluralize(execution_count, "it", "them")}. Long-term coverage rollups are kept."
  end

  def sweep_group_delete_confirm_message(_execution_count), do: "Delete this sweep group? It has no recorded executions."

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural
  defp pluralize(count, singular), do: pluralize(count, singular, singular <> "s")

  @doc """
  Why a sweep group delete was refused, in terms the operator can act on.

  The delete path used to collapse every failure into one sentence, so an
  operator who lacked the role, raced another session, or hit a database
  constraint saw the same words and had no next step. Each clause below names
  the class it can actually distinguish; the fallback deliberately does not
  invent a cause, and points at the log line the handler writes alongside it.
  """
  def sweep_group_delete_error_message(%Forbidden{}), do: "You are not authorized to delete sweep groups"

  def sweep_group_delete_error_message(%Invalid{errors: errors}) do
    if Enum.any?(errors, &match?(%StaleRecord{}, &1)) do
      "That sweep group no longer exists"
    else
      @sweep_group_delete_fallback_message
    end
  end

  def sweep_group_delete_error_message(_reason), do: @sweep_group_delete_fallback_message

  @doc """
  What the operator is told once a running scan is cancelled.

  The run is closed before its agent is asked to stop, so every clause reports
  the cancellation. Each also says whether the agent itself stopped, because one
  that did not (offline, or too old to accept the stop) may keep scanning until
  it finishes on its own.
  """
  def sweep_execution_cancel_message(_agent_id, {:ok, _command_id}), do: "Scan cancelled. Its agent was asked to stop."

  def sweep_execution_cancel_message(_agent_id, {:error, :invalid_agent_id}),
    do: "Scan cancelled. No agent is recorded for it, so none was asked to stop."

  def sweep_execution_cancel_message(agent_id, {:error, {:agent_capability_missing, _agent_id, _capability}}),
    do: agent_not_stopped(agent_id, "It does not support cancelling scans.")

  def sweep_execution_cancel_message(agent_id, {:error, {:agent_offline, _agent_id}}),
    do: agent_not_stopped(agent_id, "It is offline.")

  def sweep_execution_cancel_message(agent_id, {:error, reason}),
    do: agent_not_stopped(agent_id, "#{CommandStatus.format_sweep_failure_reason(reason)}.")

  defp agent_not_stopped(agent_id, why), do: "Scan cancelled, but agent #{agent_id} was not stopped. #{why}"

  @doc """
  Why a scan could not be cancelled. The run stays as it was in every case.
  """
  def sweep_execution_cancel_error_message(:unauthorized), do: "You are not authorized to cancel scans"
  def sweep_execution_cancel_error_message(%Forbidden{}), do: "You are not authorized to cancel scans"

  def sweep_execution_cancel_error_message(%Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &match?(%StaleRecord{}, &1)) -> "That scan is no longer running"
      Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) -> "That scan no longer exists"
      true -> @sweep_execution_cancel_fallback_message
    end
  end

  def sweep_execution_cancel_error_message(_reason), do: @sweep_execution_cancel_fallback_message

  def sweep_group_toggle_message(:enable) do
    if ObanSupport.available?() do
      "Sweep group enabled"
    else
      "Sweep group enabled. Scheduling is deferred until the scheduler is available."
    end
  end

  def sweep_group_toggle_message(:disable), do: "Sweep group disabled"
end
