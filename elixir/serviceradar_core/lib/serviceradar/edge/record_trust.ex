defmodule ServiceRadar.Edge.RecordTrust do
  @moduledoc """
  Core's public trust document for edge records.

  Gateways fetch this over the authenticated ERTS control plane. The authorities are the sweep
  producer assignments and the standing output grants (`ServiceRadar.Edge.OutputGrant`); each
  is a producer assignment to the gateway, fenced by its id, network scope, shard and epoch.
  Bounded reads supply both the authority fences and the principal-to-scope bindings, including
  revoked authorities: their advanced fence makes previously issued records stale. No issuer
  seed is returned. An oversized snapshot fails closed instead of silently omitting
  authorities.

  The document also carries the contract registry (`"contract_registry"`, format 2): every
  non-retired registry epoch whose row verifies, with its signature and signing key id
  (`ServiceRadar.Edge.ContractRegistry.trust_member/1`). A gateway verifies each epoch against
  the `"keys"` of the same document before it installs the registry, and installs trust and
  registry from the same read. `refresh/1` is the gateway's call: it also takes the gateway's
  report of the registry it installed on its previous refresh.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrant
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ash.Query
  require Logger

  @max_assignments 10_000
  @clock_tolerance_nano 5 * 60 * 1_000_000_000

  @doc "Reads current assignment authority with the installation's configured public key."
  def snapshot do
    with {:ok, key} <- IssuerKey.configured(), do: snapshot(key)
  end

  @doc """
  The gateway's refresh: records its report of the registry it installed
  (`ServiceRadar.Edge.ContractRegistry.record_gateway_report/2`), then returns `snapshot/0`. A
  malformed report is logged and dropped; it never withholds the trust document.
  """
  def refresh(report) do
    case ContractRegistry.record_gateway_report(report) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Edge record trust refresh report dropped: #{inspect(reason)}")
    end

    snapshot()
  end

  @doc "Reads current assignment authority for the supplied issuer."
  def snapshot(%IssuerKey{} = key) do
    with {:ok, sweeps} <- read_authorities(SweepProducerAssignment),
         {:ok, grants} <- read_authorities(OutputGrant),
         {:ok, registry} <- ContractRegistry.trust_member(key) do
      assignments = Enum.sort_by(sweeps ++ grants, & &1.id)

      if length(assignments) > @max_assignments do
        {:error, :trust_snapshot_too_large}
      else
        {:ok,
         %{
           "clock_tolerance_nano" => @clock_tolerance_nano,
           "keys" => [IssuerKey.trust_entry(key)],
           "contract_registry" => registry,
           "fences" => Enum.map(assignments, &fence/1),
           "scopes" => scopes(assignments)
         }}
      end
    end
  end

  # Each read stops one past the cap, so an oversized table is detected without reading all of it.
  defp read_authorities(resource) do
    resource
    |> Ash.Query.select([:id, :agent_id, :network_scope_id, :run_shard, :authority_epoch])
    |> Ash.Query.sort(:id)
    |> Ash.Query.limit(@max_assignments + 1)
    |> Ash.read(actor: SystemActor.system(:edge_record_trust))
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
