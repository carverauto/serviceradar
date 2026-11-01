defmodule ServiceRadar.Edge.OutputGrants do
  @moduledoc """
  Issues, fences and signs standing edge-record output grants: one
  `ServiceRadar.Edge.OutputGrant` per (agent, passive output contract).

  A passive producer (sysmon today) has no execution core schedules, so instead of a lease it
  emits under a standing production capability. An agent holds a grant for a contract when:

    * the contract is active in the installation's registry, the same document the gateway
      admits records against (`ServiceRadar.Edge.MetricsBatchContract.current/0`); and
    * the agent is on the durable edge-record pipeline, which is the operator's per-agent
      leasing switch (`ServiceRadar.SweepJobs.LeaseSettings`), resolved agent, then partition,
      then global.

  Turning the switch off revokes the grant, which moves its epoch so the gateway refuses
  records signed before the revocation. Turning it back on, or moving the agent to another
  partition, reactivates the grant under a new epoch.

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
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.MetricsBatchContract
  alias ServiceRadar.Edge.OutputContract
  alias ServiceRadar.Edge.OutputGrant
  alias Serviceradar.Edge.V1.EdgeProductionClaimsV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias ServiceRadar.SweepJobs.LeaseSettings
  alias ServiceRadar.SweepJobs.ProducerAssignments

  require Ash.Query
  require Logger

  @day_seconds 86_400
  @validity_seconds 8 * @day_seconds
  # A fresh grant starts this far before its UTC day, so an agent whose clock runs a little
  # behind core can use it as soon as it arrives instead of refusing it as not yet valid.
  @clock_lead_seconds 300
  @package_id "serviceradar.agent.metrics"
  @package_sha256 :crypto.hash(:sha256, "serviceradar.agent.metrics.package.v1")
  @scope_domain "serviceradar.edge.output_grant_scope.v1"
  @effective_grant_domain "serviceradar.edge.output_grant.effective_grant.v1"

  @doc "The package id every standing-grant metrics record names."
  @spec package_id() :: String.t()
  def package_id, do: @package_id

  @type authority :: %{key: IssuerKey.t(), contract: OutputContract.t()}

  @doc """
  The issuer key and metrics batch contract to sign with, or why core issues no grants: the
  contract is not registered or not active, or no issuer key is configured.
  """
  @spec authority() :: {:ok, authority()} | {:error, term()}
  def authority do
    with {:ok, contract} <- MetricsBatchContract.current(),
         {:ok, key} <- IssuerKey.configured() do
      {:ok, %{key: key, contract: contract}}
    end
  end

  @doc """
  The grants to put in an agent's config: one `Monitoring.EdgeOutputGrant` per passive contract
  the agent currently holds. Reconciles the grant row first, so the config generator is where a
  grant is created, reactivated or revoked. Any failure leaves the agent without a grant (it
  keeps the status path) and is logged.
  """
  @spec config_grants(String.t(), String.t(), DateTime.t(), {:ok, authority()} | {:error, term()}) ::
          [Monitoring.EdgeOutputGrant.t()]
  def config_grants(agent_id, partition, now \\ DateTime.utc_now(), authority \\ authority())
      when is_binary(agent_id) and is_binary(partition) do
    with {:ok, %{key: key, contract: contract}} <- authority,
         {:ok, scope} <- ProducerAssignments.network_scope_id_for_partition(partition),
         {:ok, %{enabled?: enabled?}} <- LeaseSettings.resolve(agent_id, scope),
         {:ok, %OutputGrant{} = grant} <-
           reconcile(agent_id, contract.contract_id, scope, enabled?) do
      capability = production_capability(grant, contract, key, now)

      [
        %Monitoring.EdgeOutputGrant{
          contract_id: contract.contract_id,
          contract_version: contract.contract_version,
          production_capability: EdgeSignedCapabilityV1.encode(capability)
        }
      ]
    else
      {:ok, nil} ->
        []

      {:error, reason}
      when reason in [:contract_not_registered, :registry_not_configured, :not_configured] ->
        []

      {:error, reason} ->
        Logger.warning("Edge output grant not issued",
          agent_id: agent_id,
          reason: inspect(reason)
        )

        []
    end
  end

  @doc """
  Makes the agent's grant for `contract_id` match `enabled?`: an enabled agent gets an active
  grant under `network_scope_id` (created, or reactivated under a new epoch when it was revoked
  or its scope changed); a disabled agent's active grant is revoked. Returns the active grant,
  or `nil` when there is none.
  """
  @spec reconcile(String.t(), String.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, OutputGrant.t() | nil} | {:error, term()}
  def reconcile(agent_id, contract_id, network_scope_id, enabled?) do
    with {:ok, existing} <- get(agent_id, contract_id) do
      reconcile_existing(existing, agent_id, contract_id, network_scope_id, enabled?)
    end
  end

  defp reconcile_existing(nil, _agent, _contract, _scope, false), do: {:ok, nil}

  defp reconcile_existing(nil, agent_id, contract_id, network_scope_id, true) do
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
            reconcile_existing(existing, agent_id, contract_id, network_scope_id, true)

          _ ->
            {:error, error}
        end
    end
  end

  defp reconcile_existing(
         %OutputGrant{state: :active, network_scope_id: scope} = grant,
         _a,
         _c,
         scope,
         true
       ),
       do: {:ok, grant}

  defp reconcile_existing(%OutputGrant{} = grant, _agent, _contract, network_scope_id, true) do
    grant
    |> Ash.Changeset.for_update(:reactivate, %{network_scope_id: network_scope_id},
      actor: actor()
    )
    |> Ash.update()
  end

  defp reconcile_existing(%OutputGrant{state: :active} = grant, _agent, _contract, _scope, false) do
    with {:ok, _revoked} <-
           grant |> Ash.Changeset.for_update(:revoke, %{}, actor: actor()) |> Ash.update() do
      {:ok, nil}
    end
  end

  defp reconcile_existing(%OutputGrant{}, _agent, _contract, _scope, false), do: {:ok, nil}

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

  A missing grant or one that does not match is `{:error, :output_grant_not_current}`. Any
  other lookup failure is raised, so the EventWriter batch fails and JetStream redelivers it.
  `opts[:grant_lookup]` replaces the row read; production leaves it unset.
  """
  @spec check_current(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          Ecto.UUID.t(),
          non_neg_integer(),
          keyword()
        ) ::
          :ok | {:error, :output_grant_not_current}
  def check_current(
        grant_id,
        agent_id,
        contract_id,
        network_scope_id,
        authority_epoch,
        opts \\ []
      ) do
    case grant_row(grant_id, opts) do
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

  defp grant_row(grant_id, opts) do
    case Keyword.get(opts, :grant_lookup) do
      lookup when is_function(lookup, 1) -> lookup.(grant_id)
      _ -> Ash.get(OutputGrant, grant_id, actor: actor())
    end
  end

  defp grant_not_found?(%Ash.Error.Query.NotFound{}), do: true

  defp grant_not_found?(%{errors: errors}) when is_list(errors) do
    errors != [] and Enum.all?(errors, &grant_not_found?/1)
  end

  defp grant_not_found?(_error), do: false

  @doc """
  The signed production capability of a grant, valid from five minutes before `now`'s UTC day
  until eight days after that day starts.
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

    claims = %EdgeProductionClaimsV1{
      contract_id: contract.contract_id,
      contract_version: contract.contract_version,
      contract_bundle_sha256: contract.contract_bundle_sha256,
      registry_epoch: contract.registry_epoch,
      network_scope_id: Ecto.UUID.dump!(grant.network_scope_id),
      producer_assignment_id: id,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      origin_kind: :EDGE_ORIGIN_KIND_AGENT,
      origin_principal_id: grant.agent_id,
      producer_instance_id: grant.agent_id,
      run_id: id,
      run_shard: grant.run_shard,
      authority_epoch: grant.authority_epoch,
      scope_id: id,
      scope_sha256: scope_sha256,
      package_sha256: @package_sha256,
      registry_snapshot_sha256: contract.registry_snapshot_sha256,
      effective_grant_sha256: effective_grant_sha256(contract, scope_sha256),
      max_projected_row_count: contract.max_projected_row_count,
      max_projected_write_bytes: contract.max_projected_write_bytes,
      cost_model_version: contract.cost_model_version,
      package_id: @package_id
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
