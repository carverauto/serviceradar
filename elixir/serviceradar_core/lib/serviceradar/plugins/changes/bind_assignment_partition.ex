defmodule ServiceRadar.Plugins.Changes.BindAssignmentPartition do
  @moduledoc """
  Binds a new plugin assignment to the agent's server-owned partition.

  The partition is copied from the agent's current authenticated control
  session and is deliberately not accepted from API, policy, persisted agent
  metadata, or plugin input.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Edge.AgentCommandBus

  @impl true
  def change(changeset, _opts, _context) do
    agent_uid = Ash.Changeset.get_attribute(changeset, :agent_uid)

    case AgentCommandBus.resolve_control_session_evidence(agent_uid) do
      {:ok, evidence} ->
        bind_authenticated_partition(changeset, agent_uid, evidence)

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset,
          field: :agent_uid,
          message: "authenticated agent partition is unavailable"
        )
    end
  end

  defp bind_authenticated_partition(changeset, agent_uid, evidence) when is_map(evidence) do
    evidence_agent_id = Map.get(evidence, :agent_id) || Map.get(evidence, "agent_id")
    partition_id = Map.get(evidence, :partition_id) || Map.get(evidence, "partition_id")

    if evidence_agent_id == agent_uid and is_binary(partition_id) and
         String.trim(partition_id) != "" do
      Ash.Changeset.force_change_attribute(changeset, :partition_id, String.trim(partition_id))
    else
      Ash.Changeset.add_error(changeset,
        field: :agent_uid,
        message: "authenticated agent partition does not match"
      )
    end
  end

  defp bind_authenticated_partition(changeset, _agent_uid, _evidence) do
    Ash.Changeset.add_error(changeset,
      field: :agent_uid,
      message: "authenticated agent partition is unavailable"
    )
  end
end
