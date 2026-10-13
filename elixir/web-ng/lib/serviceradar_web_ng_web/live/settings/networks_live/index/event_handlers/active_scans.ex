defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.ActiveScans do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import Ash.Expr
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Executions
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Messages

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepPubSub

  require Logger

  # Stopping a run takes the same permission as starting one. The run is closed
  # first and its agent asked to stop second: results the agent sends meanwhile
  # cannot reopen a closed run, and an agent that cannot be stopped (offline, or
  # too old to accept the command) still leaves the run closed.
  def handle_event("cancel_sweep_execution", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with :ok <- require_run_sweeps(socket),
         {:ok, execution} <- close_running_execution(scope, id) do
      SweepPubSub.broadcast_failed(execution, execution.error_message)

      stop_result = sweep_execution_canceller().(execution, actor: scope.user)
      log_unstopped_agent(execution, stop_result)

      {:noreply,
       socket
       |> refresh_running_scans(execution.id)
       |> put_flash(:info, sweep_execution_cancel_message(execution.agent_id, stop_result))}
    else
      {:error, reason} ->
        log_cancel_failure(id, reason)
        {:noreply, put_flash(socket, :error, sweep_execution_cancel_error_message(reason))}
    end
  end

  # The status filter makes the update a compare-and-set, so a run that finished
  # between the click and this write keeps its completed state.
  defp close_running_execution(scope, id) do
    with {:ok, execution} <- Ash.get(SweepGroupExecution, id, scope: scope) do
      execution
      |> Ash.Changeset.for_update(:fail, %{error_message: cancelled_by(scope)}, scope: scope)
      |> Ash.Changeset.filter(expr(status == :running))
      |> Ash.update(scope: scope)
    end
  end

  # The audit history names users by their login email, so the record does too.
  defp cancelled_by(%{user: %{email: email}}) when not is_nil(email), do: "cancelled by #{email}"
  defp cancelled_by(%{user: %{id: id}}), do: "cancelled by #{id}"

  defp refresh_running_scans(socket, execution_id) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:execution_progress, Map.delete(socket.assigns.execution_progress, execution_id))
    |> assign(:running_executions, load_running_executions(scope))
    |> assign(:recent_executions, load_recent_executions(scope))
  end

  # Overridable so LiveView tests can observe the stop request without an agent.
  defp sweep_execution_canceller do
    Application.get_env(
      :serviceradar_web_ng,
      :sweep_execution_canceller,
      &AgentCommandBus.cancel_sweep_execution/2
    )
  end

  defp log_unstopped_agent(_execution, {:ok, _command_id}), do: :ok

  defp log_unstopped_agent(execution, {:error, reason}) do
    Logger.info("Cancelled sweep execution without stopping its agent",
      sweep_group_execution_id: execution.id,
      agent_id: execution.agent_id,
      reason: inspect(reason)
    )
  end

  defp log_cancel_failure(_id, :unauthorized), do: :ok

  defp log_cancel_failure(id, reason) do
    Logger.warning("Failed to cancel sweep execution",
      sweep_group_execution_id: id,
      reason: inspect(reason)
    )
  end
end
