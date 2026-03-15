defmodule ServiceRadar.NetworkDiscovery.Changes.TriggerMapperRun do
  @moduledoc """
  Dispatches an on-demand mapper run over the agent command bus.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Changes.DispatchAgentCommand
  alias ServiceRadar.Edge.AgentCommandBus

  @impl true
  def change(changeset, _opts, _context) do
    DispatchAgentCommand.after_action(changeset, &AgentCommandBus.run_mapper_job/2)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
