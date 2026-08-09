defmodule ServiceRadar.Notifications.Changes.BindChannelPartition do
  @moduledoc """
  Binds an `:edge_agent` notification channel to the agent's server-owned partition.

  Design D3 makes the execution route a field on the channel, and R1 makes the
  `:edge_agent` route first class: a channel bound to a site agent egresses from
  inside the customer network over the existing bidirectional gRPC tunnel.
  `partition_id` is the only scoping dimension ServiceRadar has, and it is
  mTLS-derived. It is copied from the agent's current authenticated control
  session and is deliberately never accepted from API input, browser payloads,
  persisted agent metadata, or channel configuration. This mirrors
  `ServiceRadar.Plugins.Changes.BindAssignmentPartition`, which owns the same
  rule for plugin assignments; the two must not diverge.

  A `:control_plane` channel has no site binding, so the partition is force
  cleared. Relocating a channel back to platform egress must not leave the stale
  site partition behind, because a stale partition reads as a live binding to
  every partition-scoped check downstream.

  When the changeset carries no execution route at all - a partial update that
  touches neither `execution_route` nor the row it belongs to - the binding is
  left exactly as it is. Guessing in that case is what would silently unbind a
  healthy edge channel.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Edge.AgentCommandBus

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :execution_route) do
      :edge_agent ->
        bind_authenticated_partition(changeset)

      nil ->
        changeset

      _control_plane ->
        Ash.Changeset.force_change_attribute(changeset, :partition_id, nil)
    end
  end

  # Resolving the control session is Elixir-side work, so the change runs here
  # and hands back a changeset carrying only plain attribute values. That keeps
  # the enclosing update atomic rather than reaching for `require_atomic? false`.
  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp bind_authenticated_partition(changeset) do
    agent_uid = normalize(Ash.Changeset.get_attribute(changeset, :agent_uid))

    case agent_uid && AgentCommandBus.resolve_control_session_evidence(agent_uid) do
      {:ok, evidence} -> apply_evidence(changeset, agent_uid, evidence)
      _other -> partition_unavailable(changeset)
    end
  end

  defp apply_evidence(changeset, agent_uid, evidence) when is_map(evidence) do
    evidence_agent_id = Map.get(evidence, :agent_id) || Map.get(evidence, "agent_id")

    partition_id =
      normalize(Map.get(evidence, :partition_id) || Map.get(evidence, "partition_id"))

    if evidence_agent_id == agent_uid and is_binary(partition_id) do
      Ash.Changeset.force_change_attribute(changeset, :partition_id, partition_id)
    else
      Ash.Changeset.add_error(changeset,
        field: :agent_uid,
        message: "authenticated agent partition does not match"
      )
    end
  end

  defp apply_evidence(changeset, _agent_uid, _evidence), do: partition_unavailable(changeset)

  defp partition_unavailable(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :agent_uid,
      message: "authenticated agent partition is unavailable"
    )
  end

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil
end
