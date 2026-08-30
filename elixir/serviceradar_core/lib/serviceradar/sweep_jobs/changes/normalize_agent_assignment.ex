defmodule ServiceRadar.SweepJobs.Changes.NormalizeAgentAssignment do
  @moduledoc false

  use Ash.Resource.Change

  alias ServiceRadar.SweepJobs.AgentAssignment

  @impl true
  def change(changeset, _opts, _context) do
    agent_ids = incoming_agent_ids(changeset)
    scalar = AgentAssignment.scalar_mirror(agent_ids)

    changeset
    |> Ash.Changeset.force_change_attribute(:agent_ids, agent_ids)
    |> maybe_mirror_scalar(scalar)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp incoming_agent_ids(changeset) do
    case Ash.Changeset.fetch_change(changeset, :agent_ids) do
      {:ok, agent_ids} ->
        if Enum.member?(changeset.defaults, :agent_ids) do
          legacy_scalar_or_stored_assignment(changeset)
        else
          AgentAssignment.normalize(agent_ids)
        end

      :error ->
        legacy_scalar_or_stored_assignment(changeset)
    end
  end

  defp legacy_scalar_or_stored_assignment(changeset) do
    case Ash.Changeset.fetch_change(changeset, :agent_id) do
      {:ok, agent_id} -> AgentAssignment.normalize(agent_id)
      :error -> AgentAssignment.normalize(Map.get(changeset.data, :agent_ids) || [])
    end
  end

  defp maybe_mirror_scalar(changeset, scalar) do
    existing_scalar = Map.get(changeset.data, :agent_id)

    if changeset.action_type != :create and
         AgentAssignment.normalize(existing_scalar) == AgentAssignment.normalize(scalar) do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :agent_id, scalar)
    end
  end
end
