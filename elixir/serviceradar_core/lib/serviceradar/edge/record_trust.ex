defmodule ServiceRadar.Edge.RecordTrust do
  @moduledoc """
  Core's public trust document for scheduled sweep records.

  Gateways fetch this over the authenticated ERTS control plane. One bounded database read
  supplies both the authority fences and the principal-to-scope bindings, including revoked
  assignments: their advanced fence makes previously issued records stale. No issuer seed is
  returned. An oversized snapshot fails closed instead of silently omitting authorities.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ash.Query

  @max_assignments 10_000
  @clock_tolerance_nano 5 * 60 * 1_000_000_000

  @doc "Reads current assignment authority with the installation's configured public key."
  def snapshot do
    with {:ok, key} <- IssuerKey.configured(), do: snapshot(key)
  end

  @doc "Reads current assignment authority for the supplied issuer."
  def snapshot(%IssuerKey{} = key) do
    actor = SystemActor.system(:edge_record_trust)

    query =
      SweepProducerAssignment
      |> Ash.Query.select([:id, :agent_id, :network_scope_id, :run_shard, :authority_epoch])
      |> Ash.Query.sort(:id)
      |> Ash.Query.limit(@max_assignments + 1)

    with {:ok, assignments} <- Ash.read(query, actor: actor) do
      if length(assignments) > @max_assignments do
        {:error, :trust_snapshot_too_large}
      else
        {:ok,
         %{
           "clock_tolerance_nano" => @clock_tolerance_nano,
           "keys" => [IssuerKey.trust_entry(key)],
           "fences" => Enum.map(assignments, &fence/1),
           "scopes" => scopes(assignments)
         }}
      end
    end
  end

  defp fence(assignment) do
    %{
      "network_scope_id" => encode_uuid(assignment.network_scope_id),
      "producer_assignment_id" => encode_uuid(assignment.id),
      "run_shard" => assignment.run_shard,
      "authority_epoch" => assignment.authority_epoch
    }
  end

  defp scopes(assignments) do
    assignments
    |> Enum.group_by(& &1.agent_id, &encode_uuid(&1.network_scope_id))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {agent, scopes} ->
      %{"agent_id" => agent, "network_scope_ids" => Enum.sort(Enum.uniq(scopes))}
    end)
  end

  defp encode_uuid(id), do: id |> Ecto.UUID.dump!() |> Base.encode64()
end
