defmodule ServiceRadar.SweepJobs.Validations.AgentAssignment do
  @moduledoc false

  use Ash.Resource.Validation

  alias ServiceRadar.AshContext
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.SweepJobs.AgentAssignment

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    incoming = Ash.Changeset.get_attribute(changeset, :agent_ids) || []
    stored = Map.get(changeset.data, :agent_ids) || []
    actor = AshContext.actor(changeset)

    Enum.reduce_while(AgentAssignment.newly_added(incoming, stored), :ok, fn agent_id, :ok ->
      case lookup_agent(agent_id, actor) do
        {:ok, %Agent{}} ->
          {:cont, :ok}

        {:ok, nil} ->
          {:halt, {:error, field: :agent_ids, message: "agent '#{agent_id}' not found"}}

        {:error, _reason} ->
          {:halt, {:error, field: :agent_ids, message: "agent lookup failed"}}
      end
    end)
  end

  defp lookup_agent(agent_id, actor) do
    Agent
    |> Ash.Query.for_read(:by_uid, %{uid: agent_id})
    |> Ash.read_one(actor: actor)
  end
end
