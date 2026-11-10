defmodule ServiceRadar.Edge.OutputGrants do
  @moduledoc """
  Issues, fences and signs standing edge-record output grants: one
  `ServiceRadar.Edge.OutputGrant` per (agent, passive output contract).

  A producer the agent schedules from its own config has no execution core schedules, so
  instead of a lease it emits under a standing production capability. Core issues grants
  for every `:standing_grant` contract in `ServiceRadar.Edge.ContractCatalog`. The pipeline
  has no switch: an agent holds a grant for such a contract whenever the contract is in the
  active registry epoch, the epoch the gateway admits records under, and this node's catalog
  holds its exact bundle (`ServiceRadar.Edge.OutputContract.current/1`), and the agent's
  partition has a row.

  `revoke_agent/1` revokes every grant of an agent whose identity is superseded or whose
  certificate is revoked. Revoking moves a grant's epoch, so the gateway refuses records signed
  before it. The agent's next config, which it can only fetch after authenticating again (a
  revived identity, a new certificate), reactivates the grant under a new epoch, as does moving
  the agent to another partition.

  The capability is delivered in the agent config (`AgentConfigResponse.edge_output_grants`).
  Its validity window starts five minutes before the UTC day the config is generated in and
  ends eight days after that day starts, and Ed25519 signatures are deterministic, so the config only
  changes once a day while records spooled during an outage of up to a week stay deliverable:
  the gateway withholds a record whose capability expired before it was delivered.

  Records under a standing grant carry no source authorization. The capability's
  `producer_assignment_id`, `run_id` and `scope_id` are all the grant id, and its
  `scope_sha256` binds the grant, the agent, the contract and the network scope.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputContract
  alias ServiceRadar.Edge.OutputGrant
  alias ServiceRadar.Edge.RecoveryAssignmentEvidence
  alias ServiceRadar.Edge.RecoveryAssignments
  alias Serviceradar.Edge.V1.EdgeProductionClaimsV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias ServiceRadar.SweepJobs.ProducerAssignments

  require Ash.Query
  require Logger

  @day_seconds 86_400
  @validity_seconds 8 * @day_seconds
  # A fresh grant starts this far before its UTC day, so an agent whose clock runs a little
  # behind core can use it as soon as it arrives instead of refusing it as not yet valid.
  @clock_lead_seconds 300
  @scope_domain "serviceradar.edge.output_grant_scope.v1"
  @effective_grant_domain "serviceradar.edge.output_grant.effective_grant.v1"

  @type authority :: %{key: IssuerKey.t(), contracts: [OutputContract.t()]}

  @doc """
  The longest a standing grant can stay valid after it is signed: its eight-day window plus the
  clock lead. A registry epoch drains at least this long, so no grant outlives its epoch.
  """
  @spec max_lifetime_seconds() :: pos_integer()
  def max_lifetime_seconds, do: @validity_seconds + @clock_lead_seconds

  @doc """
  The issuer key and the standing-grant contracts to sign, or why core issues no grants: the
  issuer key cannot be read. A catalog contract the active registry epoch does not hold, or
  holds under a bundle this node's catalog does not, is left out; with no verified active epoch
  every contract is left out.
  """
  @spec authority() :: {:ok, authority()} | {:error, term()}
  def authority do
    with {:ok, key} <- IssuerKey.configured() do
      contracts =
        Enum.flat_map(ContractCatalog.standing_grant_refs(), fn ref ->
          case OutputContract.current(ref) do
            {:ok, contract} -> [contract]
            {:error, _reason} -> []
          end
        end)

      {:ok, %{key: key, contracts: contracts}}
    end
  end

  @doc """
  The grants to put in an agent's config: one `Monitoring.EdgeOutputGrant` per passive contract
  the agent holds. Reconciles the grant row first, so the config generator is where a grant is
  created or reactivated. An agent whose partition has no row gets no grant: core never creates
  a partition from an agent's claim, and the agent shows `partition_not_found`
  (`ServiceRadar.Edge.PipelineReadiness`). Any failure leaves the agent without a grant and is
  logged.
  """
  @spec config_grants(String.t(), String.t(), DateTime.t(), {:ok, authority()} | {:error, term()}) ::
          [Monitoring.EdgeOutputGrant.t()]
  def config_grants(agent_id, partition, now \\ DateTime.utc_now(), authority \\ authority())
      when is_binary(agent_id) and is_binary(partition) do
    with {:ok, %{key: key, contracts: [_ | _] = contracts}} <- authority,
         {:ok, scope} <- ProducerAssignments.network_scope_id_for_partition(partition) do
      Enum.flat_map(contracts, &contract_grant(&1, agent_id, scope, key, now))
    else
      {:ok, %{contracts: []}} ->
        []

      {:error, reason} ->
        Logger.warning(
          "Edge output grant not issued to agent #{agent_id} in partition #{partition}: " <>
            inspect(reason),
          agent_id: agent_id,
          partition: partition,
          reason: inspect(reason)
        )

        []
    end
  end

  defp contract_grant(contract, agent_id, scope, key, now) do
    with {:ok, %OutputGrant{} = grant} <- reconcile(agent_id, contract.contract_id, scope),
         capability = production_capability(grant, contract, key, now),
         {:ok, entry} <- RecoveryAssignmentEvidence.standing(capability, key.public_key),
         {:ok, :committed} <- RecoveryAssignments.commit_issuance([entry]) do
      [
        %Monitoring.EdgeOutputGrant{
          contract_id: contract.contract_id,
          contract_version: contract.contract_version,
          production_capability: EdgeSignedCapabilityV1.encode(capability)
        }
      ]
    else
      failure ->
        Logger.warning(
          "Edge output grant for #{contract.contract_id} not issued to agent #{agent_id}: " <>
            inspect(failure),
          agent_id: agent_id,
          contract_id: contract.contract_id,
          reason: inspect(failure)
        )

        []
    end
  end

  @doc """
  Makes the agent's grant for `contract_id` active under `network_scope_id`: created, or
  reactivated under a new epoch when it was revoked or its scope changed. An active grant
  under the same scope is returned unchanged, so reconciling again never moves the epoch.
  """
  @spec reconcile(String.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, OutputGrant.t()} | {:error, term()}
  def reconcile(agent_id, contract_id, network_scope_id) do
    with {:ok, existing} <- get(agent_id, contract_id) do
      reconcile_existing(existing, agent_id, contract_id, network_scope_id)
    end
  end

  defp reconcile_existing(nil, agent_id, contract_id, network_scope_id) do
    attrs = %{agent_id: agent_id, contract_id: contract_id, network_scope_id: network_scope_id}

    case OutputGrant
         |> Ash.Changeset.for_create(:create, attrs, actor: actor())
         |> Ash.create() do
      {:ok, grant} ->
        {:ok, grant}

      {:error, error} ->
        # A concurrent reconcile won the unique (agent, contract) row: use it.
        case get(agent_id, contract_id) do
          {:ok, %OutputGrant{} = existing} ->
            reconcile_existing(existing, agent_id, contract_id, network_scope_id)

          _ ->
            {:error, error}
        end
    end
  end

  defp reconcile_existing(
         %OutputGrant{state: :active, network_scope_id: scope} = grant,
         _agent,
         _contract,
         scope
       ),
       do: {:ok, grant}

  defp reconcile_existing(%OutputGrant{} = grant, _agent, _contract, network_scope_id) do
    grant
    |> Ash.Changeset.for_update(:reactivate, %{network_scope_id: network_scope_id},
      actor: actor()
    )
    |> Ash.update()
  end

  @doc """
  Revokes every active grant of an agent, moving each one's epoch so the gateway's next trust
  document fences the records signed before. Called when the agent's identity is superseded or
  its certificate is revoked; grants already revoked are left alone. Returns how many were
  revoked.
  """
  @spec revoke_agent(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_agent(agent_id) when is_binary(agent_id) do
    with {:ok, grants} <-
           OutputGrant
           |> Ash.Query.filter(agent_id == ^agent_id and state == :active)
           |> Ash.read(actor: actor()) do
      Enum.reduce_while(grants, {:ok, 0}, fn grant, {:ok, count} ->
        case grant |> Ash.Changeset.for_update(:revoke, %{}, actor: actor()) |> Ash.update() do
          {:ok, _revoked} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc "The agent's grant for a contract, or `nil`."
  @spec get(String.t(), String.t()) :: {:ok, OutputGrant.t() | nil} | {:error, term()}
  def get(agent_id, contract_id) do
    OutputGrant
    |> Ash.Query.filter(agent_id == ^agent_id and contract_id == ^contract_id)
    |> Ash.read_one(actor: actor())
  end

  @doc """
  Whether a record's authority is still the grant's current authority: the grant exists, is
  active, belongs to the record's agent, contract and network scope, and is at the record's
  epoch. The projector checks this again before writing, as the sweep projection does for its
  assignment.

  A missing grant (`Ash.Error.Query.NotFound` or `{:ok, nil}`) or one that does not match
  state, agent, contract, scope, or epoch is `{:error, :output_grant_not_current}`. Every
  other Ash result is raised, so the EventWriter batch fails and JetStream redelivers it.
  """
  @spec check_current(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          Ecto.UUID.t(),
          non_neg_integer()
        ) ::
          :ok | {:error, :output_grant_not_current}
  def check_current(grant_id, agent_id, contract_id, network_scope_id, authority_epoch) do
    case Ash.get(OutputGrant, grant_id, actor: actor()) do
      {:ok,
       %OutputGrant{
         state: :active,
         agent_id: ^agent_id,
         contract_id: ^contract_id,
         network_scope_id: ^network_scope_id,
         authority_epoch: ^authority_epoch
       }} ->
        :ok

      {:ok, %OutputGrant{}} ->
        {:error, :output_grant_not_current}

      {:ok, nil} ->
        {:error, :output_grant_not_current}

      {:error, error} ->
        if grant_not_found?(error) do
          {:error, :output_grant_not_current}
        else
          raise error
        end
    end
  end

  defp grant_not_found?(%Ash.Error.Query.NotFound{}), do: true

  defp grant_not_found?(%{errors: errors}) when is_list(errors) do
    errors != [] and Enum.all?(errors, &grant_not_found?/1)
  end

  defp grant_not_found?(_error), do: false

  @doc """
  The signed production capability of a grant, valid from five minutes before `now`'s UTC day
  until eight days after that day starts. Its package is the contract's catalog package.
  """
  @spec production_capability(OutputGrant.t(), OutputContract.t(), IssuerKey.t(), DateTime.t()) ::
          EdgeSignedCapabilityV1.t()
  def production_capability(
        %OutputGrant{} = grant,
        contract,
        %IssuerKey{} = key,
        %DateTime{} = now
      ) do
    day = div(DateTime.to_unix(now), @day_seconds) * @day_seconds
    scope_sha256 = scope_sha256(grant)
    id = Ecto.UUID.dump!(grant.id)

    {:ok, %{package_id: package_id, route_profile: route, traffic_class: traffic}} =
      ContractCatalog.fetch({contract.contract_id, contract.contract_version})

    claims = %EdgeProductionClaimsV1{
      contract_id: contract.contract_id,
      contract_version: contract.contract_version,
      contract_bundle_sha256: contract.contract_bundle_sha256,
      registry_epoch: contract.registry_epoch,
      network_scope_id: Ecto.UUID.dump!(grant.network_scope_id),
      producer_assignment_id: id,
      traffic_class: traffic,
      route_profile: route,
      origin_kind: :EDGE_ORIGIN_KIND_AGENT,
      origin_principal_id: grant.agent_id,
      producer_instance_id: grant.agent_id,
      run_id: id,
      run_shard: grant.run_shard,
      authority_epoch: grant.authority_epoch,
      scope_id: id,
      scope_sha256: scope_sha256,
      package_sha256: :crypto.hash(:sha256, package_id <> ".package.v1"),
      registry_snapshot_sha256: contract.registry_snapshot_sha256,
      effective_grant_sha256: effective_grant_sha256(contract, scope_sha256),
      max_projected_row_count: contract.max_projected_row_count,
      max_projected_write_bytes: contract.max_projected_write_bytes,
      cost_model_version: contract.cost_model_version,
      package_id: package_id
    }

    IssuerKey.sign(
      %EdgeSignedCapabilityV1{
        not_before_unix_nano: (day - @clock_lead_seconds) * 1_000_000_000,
        expires_at_unix_nano: (day + @validity_seconds) * 1_000_000_000,
        claims: {:production, claims}
      },
      key
    )
  end

  defp scope_sha256(grant) do
    :crypto.hash(:sha256, [
      frame(@scope_domain),
      frame(Ecto.UUID.dump!(grant.id)),
      frame(grant.agent_id),
      frame(grant.contract_id),
      frame(Ecto.UUID.dump!(grant.network_scope_id))
    ])
  end

  defp effective_grant_sha256(contract, scope_sha256) do
    :crypto.hash(:sha256, [
      frame(@effective_grant_domain),
      frame(contract.contract_id),
      <<contract.contract_version::unsigned-64>>,
      frame(contract.contract_bundle_sha256),
      <<contract.registry_epoch::unsigned-64>>,
      frame(contract.registry_snapshot_sha256),
      frame(scope_sha256)
    ])
  end

  defp frame(bytes) when is_binary(bytes), do: [<<byte_size(bytes)::unsigned-64>>, bytes]

  defp actor, do: SystemActor.system(:edge_output_grants)
end
