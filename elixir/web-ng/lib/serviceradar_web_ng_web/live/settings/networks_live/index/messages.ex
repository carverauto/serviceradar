defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Messages do
  @moduledoc false

  alias ServiceRadar.SweepJobs.ObanSupport

  @sweep_group_delete_fallback_message "Failed to delete sweep group. See the server log for details."

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
  def sweep_group_delete_error_message(%Ash.Error.Forbidden{}), do: "You are not authorized to delete sweep groups"

  def sweep_group_delete_error_message(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) do
      "That sweep group no longer exists"
    else
      @sweep_group_delete_fallback_message
    end
  end

  def sweep_group_delete_error_message(_reason), do: @sweep_group_delete_fallback_message

  def sweep_group_toggle_message(:enable) do
    if ObanSupport.available?() do
      "Sweep group enabled"
    else
      "Sweep group enabled. Scheduling is deferred until the scheduler is available."
    end
  end

  def sweep_group_toggle_message(:disable), do: "Sweep group disabled"
end
