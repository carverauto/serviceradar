defmodule ServiceRadar.SweepJobs.Validations.AgentAssignment do
  @moduledoc false

  use Ash.Resource.Validation

  alias ServiceRadar.AshContext
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.SweepJobs.AgentAssignment

  require Ash.Query

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  @impl true
  def validate(changeset, _opts, _context) do
    incoming = Ash.Changeset.get_attribute(changeset, :agent_ids) || []
    stored = Map.get(changeset.data, :agent_ids) || []
    actor = AshContext.actor(changeset)

    incoming
    |> AgentAssignment.newly_added(stored)
    |> validate_new_agents(actor)
  end

  defp validate_new_agents([], _actor), do: :ok

  defp validate_new_agents(agent_ids, actor) do
    case lookup_agents(agent_ids, actor) do
      {:ok, agents} ->
        found_ids = MapSet.new(agents, & &1.uid)

        case Enum.find(agent_ids, &(not MapSet.member?(found_ids, &1))) do
          nil -> :ok
          agent_id -> {:error, field: :agent_ids, message: "agent '#{agent_id}' not found"}
        end

      {:error, _reason} ->
        {:error, field: :agent_ids, message: "agent lookup failed"}
    end
  end

  defp lookup_agents(agent_ids, actor) do
    Agent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(uid in ^agent_ids)
    |> Ash.Query.select([:uid])
    |> Ash.read(actor: actor)
  end
end
