defmodule ServiceRadar.Edge.RecoveryAuthorizationDbTest do
  use ServiceRadar.DataCase, async: false

  alias Monitoring.EdgeRecoveryAuthorizationRequest
  alias Monitoring.EdgeRecoveryQuery
  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.ContractBundle
  alias ServiceRadar.Edge.ContractCatalog
  alias ServiceRadar.Edge.ContractRegistry
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.OutputContract
  alias ServiceRadar.Edge.OutputGrants
  alias ServiceRadar.Edge.RecoveryAssignments
  alias ServiceRadar.Edge.RecoveryControl
  alias ServiceRadar.Edge.RecoveryOperations
  alias Serviceradar.Edge.V1.EdgeAttributedPassiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1
  alias ServiceRadar.Infrastructure.Partition

  @moduletag :integration
  @contract {"serviceradar.edge.recovery_control", 1}

  setup do
    actor = SystemActor.system(:recovery_authorization_test)
    slug = "synthetic-recovery-#{System.unique_integer([:positive])}"

    partition =
      Partition
      |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: actor)
      |> Ash.create!()

    {:ok, issuer} = IssuerKey.configured()
    ContractRegistry.invalidate()
    on_exit(&ContractRegistry.invalidate/0)

    {:ok, _} =
      ContractRegistry.ensure_epoch(
        ContractBundle.derive(ContractCatalog.entries()),
        issuer,
        DateTime.utc_now()
      )

    {:ok, contract} = OutputContract.current(@contract)
    {:ok, grant} = OutputGrants.reconcile(slug, elem(@contract, 0), partition.id)
    capability = OutputGrants.production_capability(grant, contract, issuer, DateTime.utc_now())
    plan = plan(Ecto.UUID.dump!(partition.id))
    {:ok, _} = RecoveryOperations.register(slug, plan)

    request = %EdgeRecoveryAuthorizationRequest{
      recovery: %EdgeRecoveryQuery{
        network_scope_id: plan.network_scope_id,
        recovery_id: plan.recovery_id
      },
      production_capability: capability,
      control_payload:
        EdgeRecoveryControlPayloadV1.encode(%EdgeRecoveryControlPayloadV1{
          body: {:manifest_page, EdgeLossManifestPageV1.decode(hd(plan.manifest_pages))}
        })
    }

    {:ok, agent: slug, issuer: issuer, request: request}
  end

  test "returned source authority already has durable explicit-negative mapping", ctx do
    assert {:ok, response} = RecoveryControl.authorize(ctx.agent, ctx.request)
    source = response.source_authorization
    assert CapabilitySigning.verify(source.capability, :source, ctx.issuer.public_key)
    assert source.context_id == ctx.request.recovery.recovery_id
    {:production, p} = ctx.request.production_capability.claims

    identity =
      struct!(
        EdgeAttributedSpanIdentityV1,
        Map.take(p, [
          :producer_assignment_id,
          :run_id,
          :run_shard,
          :authority_epoch,
          :scope_sha256,
          :contract_bundle_sha256
        ])
      )

    identity = %{
      identity
      | production_scope_id: p.scope_id,
        source: %EdgeSourceSpanIdentityV1{
          kind: source.kind,
          context_id: source.context_id,
          source_scope_id: source.scope_id,
          source_scope_sha256: source.scope_sha256
        }
    }

    span = %EdgeClassificationSpanV1{
      from_sequence: 1,
      through_sequence: 1,
      classification: {:attributed_passive, %EdgeAttributedPassiveV1{identity: identity}}
    }

    assert {:not_scheduled, %{"reason" => "recovery_control"}} =
             RecoveryAssignments.lookup(p.network_scope_id, ctx.agent, span)

    assert {:ok, ^response} = RecoveryControl.authorize(ctx.agent, ctx.request)

    assert {:ok, 1} = OutputGrants.revoke_agent(ctx.agent)

    assert {:error, :production_authority_refused} =
             RecoveryControl.authorize(ctx.agent, ctx.request)

    assert {:not_scheduled, _} = RecoveryAssignments.lookup(p.network_scope_id, ctx.agent, span)
  end

  test "registration is not authority for a different body, principal or signature", ctx do
    payload = EdgeRecoveryControlPayloadV1.decode(ctx.request.control_payload)
    {:manifest_page, page} = payload.body
    [span] = page.classification_spans
    page = %{page | classification_spans: [%{span | through_sequence: 2}]}
    page = %{page | page_sha256: HashGrammar.manifest_page_digest(page)}

    changed = %{
      ctx.request
      | control_payload:
          EdgeRecoveryControlPayloadV1.encode(%{payload | body: {:manifest_page, page}})
    }

    assert {:error, :recovery_authority_refused} = RecoveryControl.authorize(ctx.agent, changed)

    assert {:error, :registration_missing} =
             RecoveryControl.authorize(ctx.agent <> "-other", ctx.request)

    capability = %{ctx.request.production_capability | signature: :binary.copy(<<0>>, 64)}

    assert {:error, :production_authority_refused} =
             RecoveryControl.authorize(ctx.agent, %{
               ctx.request
               | production_capability: capability
             })
  end

  defp plan(scope) do
    id = uuid()

    span = %EdgeClassificationSpanV1{
      from_sequence: 1,
      through_sequence: 1,
      classification:
        {:unattributable, %EdgeUnattributableV1{reason: :EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL}}
    }

    page = %EdgeLossManifestPageV1{
      recovery_id: id,
      page_count: 1,
      terminal: true,
      digest_version: 1,
      classification_spans: [span]
    }

    page = %{page | page_sha256: HashGrammar.manifest_page_digest(page)}

    tombstone = %SpoolLossTombstoneV1{
      recovery_id: id,
      prior_spool_id: uuid(),
      new_spool_id: uuid(),
      manifest_page_count: 1,
      manifest_root_sha256: HashGrammar.manifest_root([page]),
      detected_at_unix_nano: 1_800_000_000_000_000_000,
      reason: "synthetic_append_gap",
      digest_version: 1
    }

    %EdgeRecoveryRegistration{
      protocol_version: 1,
      network_scope_id: scope,
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

  defp uuid, do: Ecto.UUID.dump!(Ash.UUIDv7.generate())
end
