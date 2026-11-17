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

  `"terminal_intervals"` names, once each, every authority interval that ended
  `certificate_revoked` or `revoked_cause_unknown` (`platform.edge_authority_history`), as
  `(producer_assignment_id, network_scope_id, run_shard, authority_epoch)`. A late record naming
  one is security-quarantined whoever presents it, whatever grant it carries; a higher current
  fence alone never is (openspec add-edge-production-time-admission, Decision 4). These intervals
  are never pruned: no age bound applies to late admission (a record too old for PRIMARY still
  leaves the edge as AUDIT), so pruning one would turn its records from quarantine into AUDIT.
  The list is therefore bounded by its own cap, `max_terminal_intervals/0` in the gateway's
  document, and the document fails closed past it exactly as it does past the assignment cap. An
  agent's own document carries only that agent's terminal intervals, under the assignment cap
  (Go's `maxTrustFences`).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputGrant
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  require Ash.Query
  require Logger

  @max_assignments 10_000
  @max_terminal_intervals 100_000
  @terminal_reasons ["certificate_revoked", "revoked_cause_unknown"]
  @clock_tolerance_nano 5 * 60 * 1_000_000_000

  @doc "How far a producer clock may run ahead of core's: five minutes."
  @spec clock_tolerance_nano() :: pos_integer()
  def clock_tolerance_nano, do: @clock_tolerance_nano

  @doc "The most terminal intervals the gateway's document lists before it fails closed."
  @spec max_terminal_intervals() :: pos_integer()
  def max_terminal_intervals, do: @max_terminal_intervals

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
         {:ok, terminal} <- read_terminal_intervals(nil, @max_terminal_intervals) do
      build_snapshot(key, sweeps ++ grants, terminal)
    end
  end

  @doc "Complete public trust for the authenticated agent's partition, including revoked fences."
  def agent_snapshot(agent_id, partition_id) do
    with {:ok, key} <- IssuerKey.configured(), do: agent_snapshot(agent_id, partition_id, key)
  end

  def agent_snapshot(agent_id, partition_id, %IssuerKey{} = key)
      when is_binary(agent_id) and is_binary(partition_id) do
    with {:ok, terminal} <- read_terminal_intervals(agent_id, @max_assignments) do
      case ProducerAssignments.network_scope_id_for_partition(partition_id) do
        {:ok, scope_id} ->
          with {:ok, sweeps} <-
                 read_agent_authorities(SweepProducerAssignment, agent_id, scope_id),
               {:ok, grants} <- read_agent_authorities(OutputGrant, agent_id, scope_id) do
            build_snapshot(key, sweeps ++ grants, terminal)
          end

        {:error, :partition_not_found} ->
          build_snapshot(key, [], terminal)

        {:error, _} = error ->
          error
      end
    end
  end

  defp build_snapshot(key, assignments, terminal) do
    if length(assignments) > @max_assignments do
      {:error, :trust_snapshot_too_large}
    else
      with {:ok, registry} <- ContractRegistry.trust_member(key) do
        assignments = Enum.sort_by(assignments, & &1.id)

        {:ok,
         %{
           "clock_tolerance_nano" => @clock_tolerance_nano,
           "keys" => [IssuerKey.trust_entry(key)],
           "contract_registry" => registry,
           "fences" => Enum.map(assignments, &fence/1),
           "terminal_intervals" => terminal,
           "scopes" => scopes(assignments)
         }}
      end
    end
  end

  defp read_agent_authorities(resource, agent, scope) do
    resource
    |> Ash.Query.filter(agent_id == ^agent and network_scope_id == ^scope)
    |> read_authorities()
  end

  # Each read stops one past the cap, so an oversized table is detected without reading all of it.
  defp read_authorities(resource) do
    resource
    |> Ash.Query.select([:id, :agent_id, :network_scope_id, :run_shard, :authority_epoch])
    |> Ash.Query.sort(:id)
    |> Ash.Query.limit(@max_assignments + 1)
    |> Ash.read(actor: SystemActor.system(:edge_record_trust))
  end

  # Each read stops one past its cap, so an oversized list is detected without reading all of it.
  defp read_terminal_intervals(agent_id, cap) do
    {agent_filter, params} =
      if agent_id,
        do: {"AND agent_id = $3", [@terminal_reasons, cap + 1, agent_id]},
        else: {"", [@terminal_reasons, cap + 1]}

    sql = """
    SELECT DISTINCT assignment_id, network_scope_id, run_shard, authority_epoch
      FROM platform.edge_authority_history
     WHERE ended_reason = ANY($1) #{agent_filter}
     ORDER BY assignment_id, authority_epoch, network_scope_id, run_shard
     LIMIT $2
    """

    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} when length(rows) > cap -> {:error, :trust_snapshot_too_large}
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &terminal_interval/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminal_interval([assignment_id, scope_id, run_shard, epoch]) do
    %{
      "network_scope_id" => Base.encode64(scope_id),
      "producer_assignment_id" => Base.encode64(assignment_id),
      "run_shard" => run_shard,
      "authority_epoch" => epoch
    }
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
