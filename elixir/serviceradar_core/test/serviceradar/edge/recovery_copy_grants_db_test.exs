defmodule ServiceRadar.Edge.RecoveryCopyGrantsDbTest do
  use ServiceRadar.DataCase, async: true

  alias Monitoring.EdgeRecoveryCopy
  alias Monitoring.EdgeRecoveryQuery
  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.RecoveryAssignmentEvidence
  alias ServiceRadar.Edge.RecoveryAssignments
  alias ServiceRadar.Edge.RecoveryAttribution
  alias ServiceRadar.Edge.RecoveryControl
  alias ServiceRadar.Edge.RecoveryOperations
  alias ServiceRadar.Edge.SemanticDigest
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeRecordV1
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric
  alias Serviceradar.Metric.V1.MetricBatch

  @moduletag :integration
  @fixture Path.expand("../../../../../proto/edge/v1/testdata/record_no_source.bin", __DIR__)

  test "registered copy needs original mapping and grants only its exact rollover coordinates" do
    {record, raw, key, attribution} = record()
    agent = record.producer_context.origin_principal_id
    plan = plan(record, raw, attribution)

    query = %EdgeRecoveryQuery{
      network_scope_id: plan.network_scope_id,
      recovery_id: plan.recovery_id
    }

    item = %{prior_sequence: 1, new_sequence: 1, attribution: attribution}
    assert {:ok, _} = RecoveryOperations.register(agent, plan)

    assert {:ok, %{results: [%{refusal: "missing", delivery_capability: nil}]}} =
             RecoveryControl.renew_copies(agent, query, [item])

    {:ok, original} =
      RecoveryAssignmentEvidence.standing(record.production_capability, key.public_key)

    assert {:ok, :committed} = RecoveryAssignments.commit_issuance([original])
    # There is no current OutputGrant row: only real retained issuance evidence.
    assert {:ok, %{results: [%{sequence: 1, delivery_capability: capability}]}} =
             RecoveryControl.renew_copies(agent, query, [item])

    assert {:ok, issuer} = IssuerKey.configured()
    assert CapabilitySigning.verify(capability, :delivery, issuer.public_key)
    assert :ok = CapabilitySigning.validate(capability, :delivery)
    {:delivery, claims} = capability.claims
    assert claims.event_id == record.event_id
    assert claims.record_sha256 == :crypto.hash(:sha256, raw)
    assert claims.spool_id == plan.new_spool_id
    assert claims.sequence == 1
    assert {:rollover, transition} = claims.transition
    assert transition.recovery_id == plan.recovery_id
    assert transition.prior_spool_id == plan.prior_spool_id
    assert transition.prior_sequence == 1

    assert {:ok, %{results: [%{refusal: "copy_mismatch", delivery_capability: nil}]}} =
             RecoveryControl.renew_copies(agent, query, [%{item | new_sequence: 2}])

    assert {:error, :registration_missing} =
             RecoveryControl.renew_copies(agent <> "-other", query, [item])

    wrong = plan(record, raw, attribution)
    [wrong_copy] = wrong.copies

    wrong = %{
      wrong
      | copies: [%{wrong_copy | attribution_binding_sha256: :binary.copy(<<0>>, 32)}]
    }

    assert {:ok, _} = RecoveryOperations.register(agent, wrong)
    wrong_query = %{query | recovery_id: wrong.recovery_id}

    assert {:ok, %{results: [%{refusal: "copy_mismatch", delivery_capability: nil}]}} =
             RecoveryControl.renew_copies(agent, wrong_query, [item])

    [copy] = plan.copies
    changed = %{plan | copies: [%{copy | attribution_binding_sha256: :binary.copy(<<0>>, 32)}]}

    assert {:ok, %{blocked_reason: "registration_conflict"}} =
             RecoveryOperations.register(agent, changed)

    assert {:error, :recovery_authority_refused} =
             RecoveryControl.renew_copies(agent, query, [item])
  end

  defp record do
    r = EdgeRecordV1.decode(File.read!(@fixture))
    key = IssuerKey.from_seed(:binary.copy(<<0x54>>, 32))
    scope = uuid()
    agent = "recovery-copy-#{System.unique_integer([:positive])}"

    contract = %{
      r.output_contract
      | contract_id: "serviceradar.metrics.batch",
        contract_version: 1
    }

    context = %{r.producer_context | origin_principal_id: agent, producer_instance_id: agent}
    {:production, p} = r.production_capability.claims

    p = %{
      p
      | network_scope_id: scope,
        origin_principal_id: agent,
        producer_instance_id: agent,
        contract_id: contract.contract_id,
        contract_version: 1
    }

    cap = IssuerKey.sign(%{r.production_capability | claims: {:production, p}}, key)

    payload =
      MetricBatch.encode(%MetricBatch{
        schema_version: "serviceradar.metric.v1",
        ingest_identity: %IngestIdentity{source: "sysmon-metrics"},
        metrics: [%Metric{name: "cpu.usage_percent", metric_type: "sysmon.cpu"}]
      })

    r = %{
      r
      | network_scope_id: scope,
        producer_context: context,
        output_contract: contract,
        production_capability: cap,
        payload: payload,
        payload_sha256: :crypto.hash(:sha256, payload),
        encoded_size: byte_size(payload),
        uncompressed_size: byte_size(payload),
        projected_row_count: 1,
        projected_write_bytes: 1024
    }

    r = %{r | semantic_envelope_sha256: SemanticDigest.compute(r)}
    raw = EdgeRecordV1.encode(r)
    policy = %{trust_policy_epoch: 1, trust: fn _, _, _ -> {:ok, key.public_key, :valid} end}
    {:ok, attribution} = RecoveryAttribution.historical(raw, contract, policy)
    {r, raw, key, attribution}
  end

  defp plan(r, raw, attribution) do
    id = uuid()
    prior = uuid()
    destination = uuid()

    page = %EdgeLossManifestPageV1{
      recovery_id: id,
      page_count: 1,
      terminal: true,
      digest_version: 1,
      classification_spans: [
        %EdgeClassificationSpanV1{
          from_sequence: 2,
          through_sequence: 2,
          classification:
            {:unattributable,
             %EdgeUnattributableV1{reason: :EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL}}
        }
      ]
    }

    page = %{page | page_sha256: HashGrammar.manifest_page_digest(page)}

    tombstone = %SpoolLossTombstoneV1{
      recovery_id: id,
      prior_spool_id: prior,
      new_spool_id: destination,
      manifest_page_count: 1,
      manifest_root_sha256: HashGrammar.manifest_root([page]),
      detected_at_unix_nano: 1_800_000_000_000_000_000,
      reason: "synthetic_append_gap",
      digest_version: 1
    }

    coordinates = %{
      network_scope_id: r.network_scope_id,
      authenticated_agent_id: r.producer_context.origin_principal_id,
      lane_route_profile: r.route_profile,
      lane_traffic_class: r.traffic_class,
      spool_generation_id: destination,
      sequence: 1,
      event_id: r.event_id,
      record_sha256: :crypto.hash(:sha256, raw)
    }

    {:ok, binding} =
      RecoveryAttribution.bind(
        attribution,
        coordinates,
        RecoveryAttribution.attribution(attribution)
      )

    %EdgeRecoveryRegistration{
      protocol_version: 1,
      network_scope_id: r.network_scope_id,
      recovery_id: id,
      prior_spool_id: prior,
      new_spool_id: destination,
      route_profile: r.route_profile,
      traffic_class: r.traffic_class,
      source_high_water: 2,
      from_sequence: 1,
      through_sequence: 2,
      manifest_pages: [EdgeLossManifestPageV1.encode(page)],
      tombstone: SpoolLossTombstoneV1.encode(tombstone),
      copies: [
        %EdgeRecoveryCopy{
          prior_sequence: 1,
          new_sequence: 1,
          event_id: r.event_id,
          record_sha256: coordinates.record_sha256,
          attribution_binding_sha256: binding
        }
      ]
    }
  end

  defp uuid, do: Ecto.UUID.dump!(Ash.UUIDv7.generate())
end
