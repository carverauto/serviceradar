defmodule ServiceRadar.SweepJobs.LeaseCapabilities do
  @moduledoc """
  Builds and signs the authority a sweep schedule lease carries: one production capability per
  lease and one SCHEDULED_SWEEP source authorization per (execution, range).

  What each claim binds, and why:

    * The agent's identity. `origin_principal_id` and `producer_instance_id` are both the agent
      uid: the gateway compares the principal with the authenticated component id, and the sweep
      join compares the batch's `agent_id` with the producer instance.
    * The lease. `producer_assignment_id`, `run_id` (the lease id), `run_shard` and
      `authority_epoch` come from the assignment the slots were planned under; a slot planned
      under another epoch, assignment or lease is refused rather than signed.
    * The production scope. `scope_id` is the sweep group and `scope_sha256` is
      `lease_scope_sha256/3`: the group, its check set and the canonical range CIDRs, so a
      capability names exactly what the lease may sweep.
    * Each execution. A source authorization's `context_id` is the execution id; `scope_id` is the
      range id; `scope_sha256` and `target_range_sha256` are the range digest; and
      `execution_plan_sha256` is the plan header digest. Its collection window and its signed
      window are the slot's `[slot_start, collection_expires]`.
    * The production window runs from issuance to the end of the lease's last slot, so every
      record the lease produces carries an event time inside it.

  Sweep runs inside the agent, so the package is a fixed built-in identity. The contract fields
  come from the caller (`ServiceRadar.Edge.SweepContract.current/0` reads them from the same
  registry document the gateway admits against), and the effective grant digest is derived here
  from that contract and the lease scope.
  """

  alias ServiceRadar.Edge.IssuerKey
  alias Serviceradar.Edge.V1.EdgeProductionClaimsV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias ServiceRadar.SweepJobs.SweepExecutionSlot
  alias ServiceRadar.SweepJobs.SweepProducerAssignment

  @package_id "serviceradar.agent.sweep"
  @package_sha256 :crypto.hash(:sha256, "serviceradar.agent.sweep.package.v1")
  @lease_scope_domain "serviceradar.sweep.lease_scope.v1"
  @effective_grant_domain "serviceradar.sweep.effective_grant.v1"

  @contract_keys [
    :contract_id,
    :contract_version,
    :contract_bundle_sha256,
    :registry_epoch,
    :registry_snapshot_sha256,
    :cost_model_version,
    :max_projected_row_count,
    :max_projected_write_bytes
  ]

  @type contract :: %{
          contract_id: String.t(),
          contract_version: pos_integer(),
          contract_bundle_sha256: <<_::256>>,
          registry_epoch: pos_integer(),
          registry_snapshot_sha256: <<_::256>>,
          cost_model_version: pos_integer(),
          max_projected_row_count: pos_integer(),
          max_projected_write_bytes: pos_integer()
        }

  @type reason ::
          :no_slots
          | :stale_slot
          | :mixed_lease
          | :invalid_plan
          | {:invalid_contract, atom()}

  @doc "The package id every sweep record names."
  @spec package_id() :: String.t()
  def package_id, do: @package_id

  @doc "The package digest every sweep record names."
  @spec package_sha256() :: <<_::256>>
  def package_sha256, do: @package_sha256

  @doc """
  The production scope digest of a lease: SHA-256 over a domain tag, the sweep group id, the
  check set digest and the range CIDRs in plan order, each length-framed.
  """
  @spec lease_scope_sha256(Ecto.UUID.t(), <<_::256>>, [String.t()]) :: <<_::256>>
  def lease_scope_sha256(sweep_group_id, <<_::256>> = check_set_sha256, cidrs)
      when is_list(cidrs) do
    :crypto.hash(:sha256, [
      frame(@lease_scope_domain),
      frame(Ecto.UUID.dump!(sweep_group_id)),
      frame(check_set_sha256),
      <<length(cidrs)::unsigned-64>>,
      Enum.map(cidrs, &frame/1)
    ])
  end

  @doc """
  The effective grant digest a lease's records name: SHA-256 over a domain tag, the contract
  reference (id, version, bundle, registry epoch and snapshot) and the lease scope digest, each
  length-framed or big-endian. It binds the grant to both the contract and what the lease may
  sweep.
  """
  @spec effective_grant_sha256(contract(), <<_::256>>) :: <<_::256>>
  def effective_grant_sha256(contract, <<_::256>> = lease_scope_sha256) do
    :crypto.hash(:sha256, [
      frame(@effective_grant_domain),
      frame(contract.contract_id),
      <<contract.contract_version::unsigned-64>>,
      frame(contract.contract_bundle_sha256),
      <<contract.registry_epoch::unsigned-64>>,
      frame(contract.registry_snapshot_sha256),
      frame(lease_scope_sha256)
    ])
  end

  @doc """
  The signed production capability of the lease the slots belong to. Every slot must be
  planned under the assignment's current epoch and share one lease, check set and range list.
  """
  @spec production_capability(
          SweepProducerAssignment.t(),
          [SweepExecutionSlot.t()],
          contract(),
          IssuerKey.t(),
          DateTime.t()
        ) :: {:ok, EdgeSignedCapabilityV1.t()} | {:error, reason()}
  def production_capability(assignment, slots, contract, key, issued_at \\ DateTime.utc_now())

  def production_capability(_assignment, [], _contract, _key, _issued_at), do: {:error, :no_slots}

  def production_capability(
        %SweepProducerAssignment{} = assignment,
        [first | _] = slots,
        contract,
        %IssuerKey{} = key,
        %DateTime{} = issued_at
      ) do
    with :ok <- check_contract(contract),
         :ok <- all_current(slots, assignment),
         {:ok, cidrs} <- one_lease(slots, first) do
      lease_end = slots |> Enum.map(& &1.collection_expires) |> Enum.max(DateTime)
      principal = assignment.agent_id

      scope_sha256 =
        lease_scope_sha256(assignment.sweep_group_id, first.check_set_sha256, cidrs)

      claims = %EdgeProductionClaimsV1{
        contract_id: contract.contract_id,
        contract_version: contract.contract_version,
        contract_bundle_sha256: contract.contract_bundle_sha256,
        registry_epoch: contract.registry_epoch,
        network_scope_id: uuid(assignment.network_scope_id),
        producer_assignment_id: uuid(assignment.id),
        traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
        origin_kind: :EDGE_ORIGIN_KIND_AGENT,
        origin_principal_id: principal,
        producer_instance_id: principal,
        run_id: uuid(first.lease_id),
        run_shard: assignment.run_shard,
        authority_epoch: assignment.authority_epoch,
        scope_id: uuid(assignment.sweep_group_id),
        scope_sha256: scope_sha256,
        package_sha256: @package_sha256,
        registry_snapshot_sha256: contract.registry_snapshot_sha256,
        effective_grant_sha256: effective_grant_sha256(contract, scope_sha256),
        max_projected_row_count: contract.max_projected_row_count,
        max_projected_write_bytes: contract.max_projected_write_bytes,
        cost_model_version: contract.cost_model_version,
        package_id: @package_id
      }

      {:ok,
       IssuerKey.sign(
         %EdgeSignedCapabilityV1{
           not_before_unix_nano: nanos(issued_at),
           expires_at_unix_nano: nanos(lease_end),
           claims: {:production, claims}
         },
         key
       )}
    end
  end

  @doc """
  The signed source authorizations of one execution, one per range of its plan, in plan order.
  """
  @spec source_authorizations(SweepProducerAssignment.t(), SweepExecutionSlot.t(), IssuerKey.t()) ::
          {:ok, [EdgeSourceAuthorizationV1.t()]} | {:error, reason()}
  def source_authorizations(
        %SweepProducerAssignment{} = assignment,
        %SweepExecutionSlot{} = slot,
        %IssuerKey{} = key
      ) do
    with :ok <- all_current([slot], assignment),
         {:ok, ranges} <- ranges(slot) do
      {:ok, Enum.map(ranges, &source_authorization(assignment, slot, &1, key))}
    end
  end

  defp source_authorization(assignment, slot, range, key) do
    execution_id = uuid(slot.id)
    not_before = nanos(slot.slot_start)
    expires = nanos(slot.collection_expires)
    principal = assignment.agent_id

    claims = %EdgeSourceClaimsV1{
      kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
      context_id: execution_id,
      scope_id: range.range_id,
      scope_sha256: range.range_sha256,
      network_scope_id: uuid(slot.network_scope_id),
      collection_not_before_unix_nano: not_before,
      collection_expires_unix_nano: expires,
      origin_principal_id: principal,
      producer_instance_id: principal,
      producer_assignment_id: uuid(assignment.id),
      run_id: uuid(slot.lease_id),
      run_shard: assignment.run_shard,
      authority_epoch: slot.authority_epoch,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      execution_plan_sha256: slot.plan_sha256,
      target_range_sha256: range.range_sha256,
      origin_kind: :EDGE_ORIGIN_KIND_AGENT
    }

    capability =
      IssuerKey.sign(
        %EdgeSignedCapabilityV1{
          not_before_unix_nano: not_before,
          expires_at_unix_nano: expires,
          claims: {:source, claims}
        },
        key
      )

    %EdgeSourceAuthorizationV1{
      kind: :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP,
      capability: capability,
      context_id: execution_id,
      scope_id: range.range_id,
      scope_sha256: range.range_sha256
    }
  end

  # A slot is signed only under the assignment and epoch it was planned for; the lease pass
  # re-plans stale slots, so a mismatch here means the caller raced a bump.
  defp all_current(slots, assignment) do
    if Enum.all?(slots, fn slot ->
         slot.producer_assignment_id == assignment.id and
           slot.authority_epoch == assignment.authority_epoch and
           slot.network_scope_id == assignment.network_scope_id
       end),
       do: :ok,
       else: {:error, :stale_slot}
  end

  defp one_lease(slots, first) do
    with {:ok, cidrs} <- cidrs(first) do
      same? =
        Enum.all?(slots, fn slot ->
          slot.lease_id == first.lease_id and slot.check_set_sha256 == first.check_set_sha256 and
            cidrs(slot) == {:ok, cidrs}
        end)

      if same?, do: {:ok, cidrs}, else: {:error, :mixed_lease}
    end
  end

  defp cidrs(slot) do
    with {:ok, ranges} <- ranges(slot), do: {:ok, Enum.map(ranges, & &1.cidr)}
  end

  defp ranges(%{plan_pages: pages}) when is_list(pages) and pages != [] do
    {:ok, Enum.flat_map(pages, &ScheduledPlanPageV1.decode(&1).ranges)}
  rescue
    _ -> {:error, :invalid_plan}
  end

  defp ranges(_slot), do: {:error, :invalid_plan}

  defp check_contract(contract) when is_map(contract) do
    case Enum.find(@contract_keys, &(not valid_contract_value?(&1, Map.get(contract, &1)))) do
      nil -> :ok
      key -> {:error, {:invalid_contract, key}}
    end
  end

  defp check_contract(_contract), do: {:error, {:invalid_contract, :contract}}

  defp valid_contract_value?(:contract_id, value), do: is_binary(value) and value != ""

  defp valid_contract_value?(key, value)
       when key in [:contract_bundle_sha256, :registry_snapshot_sha256],
       do: is_binary(value) and byte_size(value) == 32

  defp valid_contract_value?(_key, value), do: is_integer(value) and value > 0

  defp frame(bytes) when is_binary(bytes), do: [<<byte_size(bytes)::unsigned-64>>, bytes]

  defp uuid(value), do: Ecto.UUID.dump!(value)

  defp nanos(%DateTime{} = time), do: DateTime.to_unix(time, :nanosecond)
end
