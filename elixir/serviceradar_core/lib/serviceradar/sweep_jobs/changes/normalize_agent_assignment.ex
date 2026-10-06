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
    stored = AgentAssignment.normalize(Map.get(changeset.data, :agent_ids) || [])

    case Ash.Changeset.fetch_change(changeset, :agent_id) do
      {:ok, agent_id} ->
        # A multi-agent list is canonical. A scalar-only write, including one
        # from an older binary, must not collapse it. A create, an empty
        # (all-agents) list, or a one-agent list still follows the scalar.
        if length(stored) > 1 do
          stored
        else
          AgentAssignment.normalize(agent_id)
        end

      :error ->
        stored
    end
  end

  defp maybe_mirror_scalar(changeset, scalar) do
    existing_scalar = Map.get(changeset.data, :agent_id)

    incoming_matches =
      case Ash.Changeset.fetch_change(changeset, :agent_id) do
        {:ok, agent_id} ->
          AgentAssignment.normalize(agent_id) == AgentAssignment.normalize(scalar)

        :error ->
          true
      end

    if changeset.action_type != :create and
         AgentAssignment.normalize(existing_scalar) == AgentAssignment.normalize(scalar) and
         incoming_matches do
      changeset
    else
      Ash.Changeset.force_change_attribute(changeset, :agent_id, scalar)
    end
  end
end
