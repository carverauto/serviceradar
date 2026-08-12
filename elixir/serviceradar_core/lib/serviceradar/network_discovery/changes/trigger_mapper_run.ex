defmodule ServiceRadar.NetworkDiscovery.Changes.TriggerMapperRun do
  @moduledoc """
  Dispatches an on-demand mapper run over the agent command bus.
  """

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidChanges
  alias ServiceRadar.Changes.DispatchAgentCommand
  alias ServiceRadar.Edge.AgentCommandBus

  @no_online_mapper_message "No online mapper-capable agent is available for this discovery job. Connect one in the selected partition or assign an online mapper agent, then try again."
  @assigned_mapper_offline_message "The assigned mapper agent is offline. Reconnect it or assign an online mapper agent, then try again."

  @impl true
  def change(changeset, _opts, _context) do
    DispatchAgentCommand.after_action(changeset, &dispatch_mapper_job/2)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp dispatch_mapper_job(job, opts) do
    case AgentCommandBus.run_mapper_job(job, opts) do
      {:error, :agent_offline} ->
        invalid_assignment(@no_online_mapper_message)

      {:error, {:agent_offline, _agent_id}} ->
        invalid_assignment(@assigned_mapper_offline_message)

      result ->
        result
    end
  end

  defp invalid_assignment(message) do
    {:error, InvalidChanges.exception(fields: [:agent_id], message: message)}
  end
end
