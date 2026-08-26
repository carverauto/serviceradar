defmodule ServiceRadar.SweepJobs.Changes.BlankAgentId do
  @moduledoc """
  Treats a blank `agent_id` as unassigned (all agents in the partition).

  The Networks UI "All agents" option submits `""`. That is not nil, so
  `for_agent_partition`'s `is_nil(agent_id)` clause would never match and the
  group would compile onto nobody.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :agent_id) do
      {:ok, value} when value in [nil, ""] ->
        Ash.Changeset.force_change_attribute(changeset, :agent_id, nil)

      _ ->
        changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
