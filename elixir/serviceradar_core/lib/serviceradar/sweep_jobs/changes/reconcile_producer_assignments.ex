defmodule ServiceRadar.SweepJobs.Changes.ReconcileProducerAssignments do
  @moduledoc """
  Fences a sweep group's edge-record assignments when a change alters what its
  agents are authorized to sweep.

  Records signed for the old targets must not be accepted as authoritative for
  the new ones, so a change to the partition, the selected agents, the targets,
  the ports or modes, or the profile moves the authority epoch of every active
  assignment of the group. An agent that is no longer selected is revoked. This
  covers reassignment and agent replacement, which both arrive as an update of
  `agent_ids`.

  The fence runs inside the action's transaction, so the new targets are never
  live under the old epoch.
  """

  use Ash.Resource.Change

  alias ServiceRadar.SweepJobs.ProducerAssignments

  # A change to any of these alters the authorized target set.
  @target_fields [
    :partition,
    :agent_ids,
    :static_targets,
    :target_query,
    :ports,
    :sweep_modes,
    :overrides,
    :profile_id
  ]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      case plan(changeset.data, record) do
        :none ->
          {:ok, record}

        {:fence, keep} ->
          case fence(record.id, keep) do
            :ok -> {:ok, record}
            {:error, reason} -> {:error, reason}
          end
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @doc """
  What a group update requires of its assignments.

    * `:none` when no target field changed;
    * `{:fence, :all}` when the targets changed and every agent stays selected
      (an empty `agent_ids` selects every agent in the partition);
    * `{:fence, agent_ids}` when the group now selects exactly `agent_ids`, so
      the assignments of any other agent are revoked.
  """
  @spec plan(map(), map()) :: :none | {:fence, :all | [String.t()]}
  def plan(old, new) do
    if Enum.any?(@target_fields, &(Map.get(old, &1) != Map.get(new, &1))) do
      case Map.get(new, :agent_ids) || [] do
        [] -> {:fence, :all}
        agent_ids -> {:fence, agent_ids}
      end
    else
      :none
    end
  end

  defp fence(group_id, keep) do
    with :ok <- revoke_removed(group_id, keep),
         {:ok, _count} <- ProducerAssignments.bump_group(group_id) do
      :ok
    end
  end

  defp revoke_removed(_group_id, :all), do: :ok

  defp revoke_removed(group_id, agent_ids) do
    case ProducerAssignments.revoke_all_except(group_id, agent_ids) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
