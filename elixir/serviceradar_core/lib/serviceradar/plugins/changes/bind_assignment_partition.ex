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
    agent_uid = resolve_agent_uid(changeset)

    case agent_uid && AgentCommandBus.resolve_control_session_evidence(agent_uid) do
      {:ok, evidence} ->
        bind_authenticated_partition(changeset, agent_uid, evidence)

      {:error, reason} ->
        partition_unavailable(changeset, agent_uid, reason)

      _missing_agent_uid ->
        partition_unavailable(changeset, nil, :missing_agent_uid)
    end
  end

  # Resolving the control session is Elixir-side work. Returning a changeset of
  # plain attributes keeps the enclosing create atomic instead of
  # `require_atomic? false`.
  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp bind_authenticated_partition(changeset, agent_uid, evidence) when is_map(evidence) do
    evidence_agent_id = Map.get(evidence, :agent_id) || Map.get(evidence, "agent_id")
    partition_id = Map.get(evidence, :partition_id) || Map.get(evidence, "partition_id")

    if evidence_agent_id == agent_uid and is_binary(partition_id) and
         String.trim(partition_id) != "" do
      Ash.Changeset.force_change_attribute(changeset, :partition_id, String.trim(partition_id))
    else
      Ash.Changeset.add_error(changeset,
        field: :agent_uid,
        message: "authenticated agent partition does not match",
        value: agent_uid
      )
    end
  end

  defp bind_authenticated_partition(changeset, agent_uid, _evidence) do
    partition_unavailable(changeset, agent_uid, :unavailable)
  end

  defp partition_unavailable(changeset, agent_uid, reason) do
    Ash.Changeset.add_error(changeset,
      field: :agent_uid,
      message: partition_error_message(agent_uid, reason),
      value: agent_uid
    )
  end

  defp partition_error_message(_agent_uid, :missing_agent_uid) do
    "select an agent that currently has a live authenticated control session"
  end

  defp partition_error_message(agent_uid, {:agent_offline, _}) do
    "#{agent_uid} has no live authenticated control session; wait until it reconnects and try again"
  end

  defp partition_error_message(agent_uid, {:agent_partition_ambiguous, _}) do
    "#{agent_uid} has more than one live partition; assignment cannot choose one automatically"
  end

  defp partition_error_message(agent_uid, _reason) when is_binary(agent_uid) do
    "authenticated partition for #{agent_uid} is unavailable"
  end

  defp partition_error_message(_agent_uid, _reason) do
    "authenticated agent partition is unavailable"
  end

  defp resolve_agent_uid(changeset) do
    changeset
    |> Ash.Changeset.get_attribute(:agent_uid)
    |> normalize_agent_uid() ||
      changeset
      |> change_agent_uid()
      |> normalize_agent_uid()
  end

  defp change_agent_uid(changeset) do
    case Ash.Changeset.fetch_change(changeset, :agent_uid) do
      {:ok, value} -> value
      :error -> Map.get(changeset.params, :agent_uid) || Map.get(changeset.params, "agent_uid")
    end
  end

  defp normalize_agent_uid(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_agent_uid(_value), do: nil
end
