defmodule ServiceRadar.EventWriter.Processors.EdgeRecordRecoveryDbTest do
  use ServiceRadar.DataCase, async: true

  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.PublicationIdentity
  alias ServiceRadar.Edge.RecoveryAssignmentEvidence
  alias ServiceRadar.Edge.RecoveryAssignmentIssuance
  alias ServiceRadar.Edge.RecoveryAssignments
  alias ServiceRadar.Edge.RecoveryEffects
  alias ServiceRadar.Edge.RecoveryOperations
  alias ServiceRadar.Edge.RecoveryReceivedPage
  alias ServiceRadar.Edge.RecoveryValidate
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeDeliveryClaimsV1
  alias Serviceradar.Edge.V1.EdgeDeliveryRenewalV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeOutputContractRef
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias Serviceradar.Edge.V1.EdgeSignedCapabilityV1
  alias Serviceradar.Edge.V1.EdgeSourceAuthorizationV1
  alias Serviceradar.Edge.V1.EdgeSourceClaimsV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1
  alias ServiceRadar.EventWriter.Processors.EdgeRecord
  alias ServiceRadar.RecoveryAssignmentFixtures
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration
  @ref {"serviceradar.edge.recovery_control", 1}

  test "a committed deferred ledger replay converges after original issuance repair" do
    ctx = RecoveryAssignmentFixtures.fixture(:standing)
    {:ok, entry} = RecoveryAssignmentEvidence.standing(ctx.capability, ctx.key.public_key)
    assert {:ok, :committed} = RecoveryAssignments.commit_issuance([entry])

    original =
      RecoveryAssignmentIssuance
      |> Ash.Query.filter(mapping_key == ^entry.key)
      |> Ash.read_one!(actor: actor())

    Repo.query!(
      "DELETE FROM platform.edge_recovery_assignment_candidates WHERE issuance_id = $1",
      [Ecto.UUID.dump!(original.id)]
    )

    plan = plan(ctx)
    assert {:ok, _} = RecoveryOperations.register(ctx.agent, plan)
    page = frame(ctx, plan, :manifest_page)
    tombstone = frame(ctx, plan, :tombstone)

    assert {:ok, :inserted} = EdgeRecord.ingest(page.bytes, page.headers)
    assert length(receipts(ctx, plan)) == 1
    assert operation(ctx, plan).effects_state == :pending
    assert {:ok, {:deferred, :blocked}} = EdgeRecord.ingest(tombstone.bytes, tombstone.headers)
    assert operation(ctx, plan).tombstone_received
    assert operation(ctx, plan).effects_state == :blocked
    assert ledger_count(tombstone.record) == 1

    assert {:ok, true} =
             RecoveryEffects.generation_fenced?(ctx.scope, ctx.agent, plan.prior_spool_id)

    assert {:ok, {:deferred, :blocked}} = EdgeRecord.ingest(tombstone.bytes, tombstone.headers)
    assert ledger_count(tombstone.record) == 1
    assert length(receipts(ctx, plan)) == 1

    assert {:ok, :committed} = RecoveryAssignments.repair(original.id)
    assert {:ok, :replay} = EdgeRecord.ingest(tombstone.bytes, tombstone.headers)
    assert operation(ctx, plan).effects_state == :applied
    assert {:ok, :replay} = EdgeRecord.ingest(tombstone.bytes, tombstone.headers)
    assert ledger_count(tombstone.record) == 1
  end

  test "late-fenced delivery remains ledger-only while an outer rollback removes a fresh receipt" do
    ctx = RecoveryAssignmentFixtures.fixture(:standing)
    plan = plan(ctx)
    assert {:ok, _} = RecoveryOperations.register(ctx.agent, plan)
    late = frame(ctx, plan, :manifest_page, PublicationIdentity.mode_late_fenced())
    assert {:ok, :inserted} = EdgeRecord.ingest(late.bytes, late.headers)
    assert ledger_count(late.record) == 1
    assert receipts(ctx, plan) == []

    fresh = frame(ctx, plan, :manifest_page)

    hook = fn
      :before_commit, _, _ -> raise "synthetic outer transaction failure"
      _, _, _ -> :ok
    end

    assert_raise RuntimeError, "synthetic outer transaction failure", fn ->
      EdgeRecord.ingest(fresh.bytes, fresh.headers, Repo, test_hook: hook)
    end

    assert ledger_count(fresh.record) == 0
    assert receipts(ctx, plan) == []
    assert {:ok, :inserted} = EdgeRecord.ingest(fresh.bytes, fresh.headers)
    assert length(receipts(ctx, plan)) == 1
  end

  defp plan(ctx) do
    id = uuid()

    page = %EdgeLossManifestPageV1{
      recovery_id: id,
      page_count: 1,
      terminal: true,
      digest_version: 1,
      classification_spans: [ctx.span]
    }

    page = %{page | page_sha256: HashGrammar.manifest_page_digest(page)}

    tombstone = %SpoolLossTombstoneV1{
      recovery_id: id,
      prior_spool_id: uuid(),
      new_spool_id: uuid(),
      manifest_page_count: 1,
      manifest_root_sha256: HashGrammar.manifest_root([page]),
      detected_at_unix_nano: 1_800_000_000_000_000_000,
      reason: "synthetic_crash",
      digest_version: 1
    }

    %EdgeRecoveryRegistration{
      protocol_version: 1,
      network_scope_id: ctx.scope,
      recovery_id: id,
      prior_spool_id: tombstone.prior_spool_id,
      new_spool_id: tombstone.new_spool_id,
      route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
      traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
      source_high_water: 1,
      from_sequence: 1,
      through_sequence: 1,
      manifest_pages: [EdgeLossManifestPageV1.encode(page)],
      tombstone: SpoolLossTombstoneV1.encode(tombstone)
    }
  end

  defp frame(ctx, plan, kind, mode \\ PublicationIdentity.mode_fresh()) do
    body =
      case kind do
        :manifest_page -> {:manifest_page, EdgeLossManifestPageV1.decode(hd(plan.manifest_pages))}
        :tombstone -> {:tombstone, SpoolLossTombstoneV1.decode(plan.tombstone)}
      end

    control = %EdgeRecoveryControlPayloadV1{body: body}
    {:ok, {rid, scope_sha}} = RecoveryValidate.control_body(control)
    payload = EdgeRecoveryControlPayloadV1.encode(control)
    local = ContractBundle.local()
    entry = Map.fetch!(local.contracts, @ref)
    now = DateTime.utc_now()
    nanos = DateTime.to_unix(now, :nanosecond)

    claims = %{
      ctx.production
      | contract_id: elem(@ref, 0),
        contract_bundle_sha256: entry.contract_bundle_sha256,
        registry_snapshot_sha256: local.snapshot_sha256,
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1,
        max_projected_row_count: 8192,
        max_projected_write_bytes: 34_603_008,
        package_id: "serviceradar.agent.recovery"
    }

    production = sign(:production, claims, ctx.key, nanos)

    source_claims =
      struct!(
        EdgeSourceClaimsV1,
        claims
        |> Map.take([
          :network_scope_id,
          :origin_kind,
          :origin_principal_id,
          :producer_instance_id,
          :producer_assignment_id,
          :run_id,
          :run_shard,
          :authority_epoch,
          :traffic_class,
          :route_profile
        ])
        |> Map.merge(%{
          kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
          context_id: rid,
          scope_id: rid,
          scope_sha256: scope_sha,
          collection_not_before_unix_nano: nanos - 1_000_000_000,
          collection_expires_unix_nano: nanos + 60_000_000_000
        })
      )

    source = %EdgeSourceAuthorizationV1{
      kind: source_claims.kind,
      context_id: rid,
      scope_id: rid,
      scope_sha256: scope_sha,
      capability: sign(:source, source_claims, ctx.key, nanos)
    }

    record = %EdgeRecordV1{
      event_id: Ecto.UUID.dump!(ServiceRadar.SweepJobs.ExecutionSlots.mint_id(now)),
      network_scope_id: ctx.scope,
      production_capability: production,
      source_authorization: source,
      output_contract:
        struct!(
          EdgeOutputContractRef,
          Map.take(claims, [
            :contract_id,
            :contract_version,
            :contract_bundle_sha256,
            :registry_epoch,
            :registry_snapshot_sha256,
            :effective_grant_sha256
          ])
        ),
      producer_context:
        struct!(
          EdgeProducerContext,
          Map.take(claims, [
            :origin_kind,
            :origin_principal_id,
            :producer_instance_id,
            :producer_assignment_id,
            :run_id,
            :run_shard,
            :authority_epoch,
            :scope_id,
            :scope_sha256,
            :package_id,
            :package_sha256
          ])
        ),
      route_profile: claims.route_profile,
      traffic_class: claims.traffic_class,
      payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1,
      compression: :EDGE_RECORD_COMPRESSION_NONE,
      payload: payload,
      encoded_size: byte_size(payload),
      uncompressed_size: byte_size(payload),
      payload_sha256: :crypto.hash(:sha256, payload),
      projected_row_count: 22,
      projected_write_bytes: 1_081_344,
      cost_model_version: 1
    }

    record = %{record | semantic_envelope_sha256: SemanticDigest.compute(record)}
    # Exercise the signed ingress before the transport boundary to ensure this test
    # does not manufacture an authorization-invalid receipt.
    policy = %{
      trust: fn _, _, _ -> {:ok, ctx.key.public_key, :valid} end,
      now_unix_nano: nanos,
      active_fence: {:resolved, claims.authority_epoch},
      trust_policy_epoch: 1
    }

    assert :ok = RecoveryValidate.recovery_control(record, record.output_contract, policy)
    bytes = EdgeRecordV1.encode(record)
    sha = :crypto.hash(:sha256, bytes)

    slot = %{
      network_scope_id: ctx.scope,
      authenticated_agent_id: ctx.agent,
      spool_id: uuid(),
      sequence: 1
    }

    {:ok, msg_id} = PublicationIdentity.nats_msg_id(slot, record.semantic_envelope_sha256, sha)
    {:ok, delivery_id} = PublicationIdentity.delivery_id(slot)

    {:ok, provenance} =
      PublicationIdentity.transport_provenance(%{
        edge: slot,
        delivery_mode: mode,
        delivery_proof: delivery_proof(record, sha, slot, mode, ctx.key, nanos),
        record_sha256: sha,
        route_map_version: 1
      })

    %{
      record: record,
      bytes: bytes,
      headers: %{
        "Nats-Msg-Id" => msg_id,
        "Sr-Edge-Delivery-Id" => delivery_id,
        "Sr-Edge-Transport-Provenance" => provenance
      }
    }
  end

  # Every non-FRESH mode carries the digest of a signed DELIVERY renewal bound to this exact
  # record and slot, the same claim shape `DeliveryGrants` issues.
  defp delivery_proof(record, sha, slot, mode, key, nanos) do
    if mode == PublicationIdentity.mode_fresh() do
      nil
    else
      claims = %EdgeDeliveryClaimsV1{
        event_id: record.event_id,
        record_sha256: sha,
        spool_id: slot.spool_id,
        sequence: slot.sequence,
        transition:
          {:renewal,
           %EdgeDeliveryRenewalV1{
             renewed_not_before_unix_nano: nanos - 1_000_000_000,
             renewed_expires_unix_nano: nanos + 60_000_000_000
           }}
      }

      {:ok, proof} =
        PublicationIdentity.delivery_proof_digest(sign(:delivery, claims, key, nanos), mode)

      proof
    end
  end

  defp sign(kind, claims, key, nanos),
    do:
      IssuerKey.sign(
        %EdgeSignedCapabilityV1{
          claims: {kind, claims},
          not_before_unix_nano: nanos - 1_000_000_000,
          expires_at_unix_nano: nanos + 60_000_000_000
        },
        key
      )

  defp operation(ctx, plan) do
    {:ok, row} = RecoveryOperations.fetch(ctx.scope, ctx.agent, plan.recovery_id)
    row
  end

  defp receipts(ctx, plan) do
    scope = Ecto.UUID.load!(ctx.scope)
    recovery = Ecto.UUID.load!(plan.recovery_id)

    RecoveryReceivedPage
    |> Ash.Query.filter(
      network_scope_id == ^scope and agent_id == ^ctx.agent and recovery_id == ^recovery
    )
    |> Ash.read!(actor: actor())
  end

  defp ledger_count(record) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.event_ledger WHERE network_scope_id = $1::uuid AND event_id = $2::uuid",
        [record.network_scope_id, record.event_id]
      )

    count
  end

  defp actor, do: SystemActor.system(:edge_recovery_consumer_test)
  defp uuid, do: Ecto.UUID.dump!(Ash.UUIDv7.generate())
end
