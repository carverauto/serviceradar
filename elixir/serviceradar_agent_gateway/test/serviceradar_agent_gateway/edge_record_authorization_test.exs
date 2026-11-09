defmodule ServiceRadarAgentGateway.EdgeRecordAuthorizationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.HashGrammar
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeDeliveryRolloverV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias ServiceRadarAgentGateway.EdgeRecordAuthorization
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory, as: Factory

  @durable :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
  @bulk :EDGE_RECORD_TRAFFIC_CLASS_BULK
  @mode_fresh 1
  @mode_renewal 2
  @mode_late_fenced 4

  setup do
    keys = Factory.keypair()
    spool_id = Factory.uuidv7()

    %{
      keys: keys,
      spool_id: spool_id,
      lane: %{spool_id: spool_id, route_profile: @durable, traffic_class: @bulk},
      identity: %{component_id: "agent-1", component_type: :agent}
    }
  end

  describe "a generic record" do
    test "publishes primary with no source authorization and no scanner collection capability", ctx do
      record = Factory.record(ctx.keys.private)
      assert record.source_authorization == nil

      assert {:ok, decision} = authorize(ctx, record)
      assert decision.publication == :primary
      assert decision.delivery_mode == @mode_fresh
      assert decision.delivery_proof == nil
      assert decision.grant == :none
      assert decision.record.event_id == record.event_id
    end

    test "verifies a source authorization when the record carries one", ctx do
      record = Factory.record(ctx.keys.private, source: [])
      assert {:ok, %{publication: :primary}} = authorize(ctx, record)
    end
  end

  test "recovery admission validates its typed body and bounds exact record overhead", ctx do
    page = %EdgeLossManifestPageV1{
      recovery_id: Factory.uuidv7(),
      page_count: 1,
      terminal: true,
      digest_version: 1,
      classification_spans: [
        %EdgeClassificationSpanV1{
          from_sequence: 1,
          through_sequence: 1,
          classification: {:unattributable, %EdgeUnattributableV1{reason: :EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL}}
        }
      ]
    }

    page = %{page | page_sha256: HashGrammar.manifest_page_digest(page)}
    control = %EdgeRecoveryControlPayloadV1{body: {:manifest_page, page}}
    payload = control |> EdgeRecoveryControlPayloadV1.encode() |> IO.iodata_to_binary()
    route = :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
    lane = %{ctx.lane | route_profile: route}

    record = fn raw, mutate ->
      Factory.record(ctx.keys.private,
        payload: raw,
        payload_family: :EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1,
        route_profile: route,
        output_contract: %{Factory.contract_ref() | contract_id: "serviceradar.edge.recovery_control"},
        source: [
          kind: :EDGE_SOURCE_AUTHORIZATION_KIND_RECOVERY_CONTROL,
          context_id: page.recovery_id,
          scope_id: page.recovery_id,
          scope_sha256: HashGrammar.manifest_page_scope_digest(page)
        ],
        mutate: mutate
      )
    end

    assert {:ok, %{publication: :primary}} = authorize(ctx, record.(payload, & &1), lane: lane)

    invalid = [
      {"synthetic invalid protobuf", :payload_decode},
      {payload <> <<0xA0, 0x06, 1>>, :unknown_fields}
    ]

    for {raw, reason} <- invalid do
      assert {:error, :permanent, {:recovery_control, ^reason}, _} =
               authorize(ctx, record.(raw, & &1), lane: lane)
    end

    frame = Factory.frame(record.(payload, & &1), spool_id: ctx.spool_id)
    # Repeating the known route field preserves its effective value and signatures,
    # but increases exact wire overhead beyond the admitted recovery envelope.
    raw = frame.record_bytes <> :binary.copy(<<0x48, 3>>, 8_192)
    oversized = %{frame | record_bytes: raw, record_sha256: :crypto.hash(:sha256, raw)}
    trust = snapshot(ctx)
    identity = EdgeRecordTrust.with_network_scopes(trust, ctx.identity)

    assert {:error, :permanent, {:recovery_control, :record_overhead}, _} =
             EdgeRecordAuthorization.authorize_frame(oversized, lane, identity, trust, now())
  end

  describe "conflicts are rejected locally" do
    test "a network scope outside the signed grant", ctx do
      record = Factory.record(ctx.keys.private, mutate: &%{&1 | network_scope_id: Factory.uuidv7()})
      assert {:error, :permanent, :production_grant, event_id} = authorize(ctx, record)
      assert event_id == record.event_id
    end

    test "an origin principal other than the authenticated agent", ctx do
      record = Factory.record(ctx.keys.private)
      identity = %{ctx.identity | component_id: "agent-2"}

      assert {:error, :permanent, :identity_conflict, _} = authorize(ctx, record, identity: identity)
    end

    test "a route or class other than the lane's", ctx do
      record = Factory.record(ctx.keys.private)
      lane = %{ctx.lane | traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}

      assert {:error, :permanent, :route_class_conflict, _} = authorize(ctx, record, lane: lane)
    end

    test "a record_sha256 that does not match the bytes, before decoding", ctx do
      frame = %{Factory.frame(Factory.record(ctx.keys.private)) | record_sha256: :binary.copy(<<0>>, 32)}

      assert {:error, :permanent, :record_sha256_mismatch, ""} =
               EdgeRecordAuthorization.authorize_frame(frame, ctx.lane, ctx.identity, snapshot(ctx), now())
    end

    test "a scheduler scan without its plan and range", ctx do
      scan = :EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP

      unranged = Factory.record(ctx.keys.private, source: [kind: scan])
      assert {:error, :permanent, :range_conflict, _} = authorize(ctx, unranged)

      ranged =
        Factory.record(ctx.keys.private,
          source: [kind: scan, execution_plan_sha256: Factory.digest(10), target_range_sha256: Factory.digest(11)]
        )

      assert {:ok, %{publication: :primary}} = authorize(ctx, ranged)
    end

    test "a collection window reaching past its signed envelope", ctx do
      record = Factory.record(ctx.keys.private, source: [collection_expires: Factory.hour_nanos() * 1000 + now()])
      assert {:error, :permanent, :source_window, _} = authorize(ctx, record)
    end
  end

  describe "network scope authority" do
    test "a record in a scope bound to its agent publishes", ctx do
      extra = Factory.uuidv7()
      record = Factory.record(ctx.keys.private, network_scope_id: extra)
      trust = snapshot(ctx, scopes: [{"agent-1", [Factory.network_scope_id(), extra]}], fences: [fence(record)])

      assert {:ok, %{publication: :primary}} = authorize(ctx, record, snapshot: trust)
    end

    test "a signed grant for a scope outside the agent's binding is withheld, never authorized", ctx do
      foreign = Factory.uuidv7()
      record = Factory.record(ctx.keys.private, network_scope_id: foreign)
      trust = snapshot(ctx, fences: [fence(record)])

      assert {:error, :retryable, :scope_not_bound, event_id} = authorize(ctx, record, snapshot: trust)
      assert event_id == record.event_id
    end

    test "an agent with no scope binding is withheld", ctx do
      record = Factory.record(ctx.keys.private)

      for scopes <- [[], [{"agent-2", [Factory.network_scope_id()]}]] do
        assert {:error, :retryable, :scope_unbound, _} =
                 authorize(ctx, record, snapshot: snapshot(ctx, scopes: scopes))
      end
    end

    test "a forged grant is refused on its signature before its scope is checked against the binding", ctx do
      forger = Factory.keypair()
      record = Factory.record(ctx.keys.private, network_scope_id: Factory.uuidv7(), production_signer: forger.private)

      for scopes <- [[{"agent-1", [Factory.network_scope_id()]}], []] do
        trust = snapshot(ctx, scopes: scopes, fences: [fence(record)])
        assert {:error, :permanent, {:production, :signature}, _} = authorize(ctx, record, snapshot: trust)
      end
    end
  end

  describe "signatures and keys" do
    test "a production grant signed by an unknown key", ctx do
      forger = Factory.keypair()
      record = Factory.record(ctx.keys.private, production_signer: forger.private)

      assert {:error, :permanent, {:production, :signature}, _} = authorize(ctx, record)
    end

    test "a key not authorized to issue production grants is withheld, never authorized", ctx do
      record = Factory.record(ctx.keys.private)
      trust = snapshot(ctx, purposes: ["source", "delivery"])

      assert {:error, :retryable, {:production, :key_purpose_unavailable}, event_id} =
               authorize(ctx, record, snapshot: trust)

      assert event_id == record.event_id
    end

    test "a production grant under a key id the snapshot does not hold is withheld, not rejected", ctx do
      record = Factory.record(ctx.keys.private)
      trust = snapshot(ctx, issuer_key_id: "test-edge-key-2")

      assert {:error, :retryable, {:production, :key_unavailable}, event_id} = authorize(ctx, record, snapshot: trust)
      assert event_id == record.event_id
    end

    test "a forged source authorization", ctx do
      forger = Factory.keypair()
      record = Factory.record(ctx.keys.private, source: [signer: forger.private])

      assert {:error, :permanent, {:source, :signature}, _} = authorize(ctx, record)
    end

    test "a compromise-revoked source key makes the record a security quarantine", ctx do
      compromised = Factory.keypair()
      record = Factory.record(ctx.keys.private, source: [signer: compromised.private, issuer_key_id: "compromised"])

      extra = Factory.key_entry(compromised.public, issuer_key_id: "compromised", status: "historically_revoked")
      trust = snapshot(ctx, extra_keys: [extra])

      assert {:ok, %{publication: :security_quarantine, grant: :none}} = authorize(ctx, record, snapshot: trust)
    end
  end

  # Decision 7: these classifications run before any issuer key lookup, so a key id the snapshot
  # does not hold -- which alone would withhold the record -- cannot turn them into a withhold.
  describe "registry epochs that can never publish" do
    test "a static-era epoch is rejected permanently, even under a key id the snapshot does not hold", ctx do
      record = Factory.record(ctx.keys.private, output_contract: %{Factory.contract_ref() | registry_epoch: 2})
      trust = snapshot(ctx, issuer_key_id: "test-edge-key-2")

      assert {:error, :permanent, :static_registry_epoch, event_id} = authorize(ctx, record, snapshot: trust)
      assert event_id == record.event_id
    end

    test "a retired epoch is rejected permanently, even under a key id the snapshot does not hold", ctx do
      newer = Factory.registry_epoch(epoch: Factory.contract_ref().registry_epoch + 1)
      record = Factory.record(ctx.keys.private)

      trust =
        snapshot(ctx, issuer_key_id: "test-edge-key-2", contract_registry: Factory.registry_member([newer]))

      assert {:error, :permanent, :registry_epoch_retired, event_id} = authorize(ctx, record, snapshot: trust)
      assert event_id == record.event_id
    end
  end

  describe "authority" do
    test "a missing producer fence drains only a bound current rollover as audit", ctx do
      record = expired_record(ctx)
      trust = snapshot(ctx, fences: [])
      renewal = Factory.delivery_capability(record, ctx.keys.private, spool_id: ctx.spool_id)
      {:delivery, claims} = renewal.claims

      rollover_claims = %{
        claims
        | transition:
            {:rollover,
             %EdgeDeliveryRolloverV1{
               recovery_id: Factory.uuidv7(),
               prior_spool_id: Factory.uuidv7(),
               prior_sequence: 1
             }}
      }

      rollover = Factory.sign(%{renewal | claims: {:delivery, rollover_claims}}, ctx.keys.private)

      for delivery <- [nil, renewal] do
        assert {:error, :retryable, :fence_not_ready, _} =
                 authorize(ctx, record, snapshot: trust, delivery_capability: delivery)
      end

      assert {:ok, %{publication: :audit, delivery_mode: @mode_late_fenced, grant: :rollover}} =
               authorize(ctx, record, snapshot: trust, delivery_capability: rollover)

      mismatched =
        Factory.sign(%{rollover | claims: {:delivery, %{rollover_claims | event_id: Factory.uuidv7()}}}, ctx.keys.private)

      assert {:error, :permanent, {:delivery_capability, :event_id}, _} =
               authorize(ctx, record, snapshot: trust, delivery_capability: mismatched)

      future = snapshot(ctx, fences: [{record.network_scope_id, record.producer_context.producer_assignment_id, 0, 0}])

      assert {:error, :retryable, :fence_not_ready, _} =
               authorize(ctx, record, snapshot: future, delivery_capability: rollover)
    end

    test "expired production authority without a delivery grant is withheld", ctx do
      record = expired_record(ctx)
      assert {:error, :retryable, :authority_expired, _} = authorize(ctx, record)
    end

    test "not-yet-valid production authority is withheld", ctx do
      hour = Factory.hour_nanos()
      record = Factory.record(ctx.keys.private, not_before: now() + hour, expires: now() + 2 * hour)

      assert {:error, :retryable, :authority_not_yet_valid, _} = authorize(ctx, record)
    end

    test "an expired grant drains under a renewal bound to the exact record", ctx do
      record = expired_record(ctx)
      dc = Factory.delivery_capability(record, ctx.keys.private, spool_id: ctx.spool_id)

      assert {:ok, decision} = authorize(ctx, record, delivery_capability: dc)
      assert decision.publication == :primary
      assert decision.delivery_mode == @mode_renewal
      assert decision.grant == :renewal
      assert byte_size(decision.delivery_proof) == 32
    end

    test "a producer with no fence entry is withheld, never authorized as current", ctx do
      record = Factory.record(ctx.keys.private)
      assert {:ok, %{publication: :primary}} = authorize(ctx, record)

      assert {:error, :retryable, :fence_not_ready, event_id} =
               authorize(ctx, record, snapshot: snapshot(ctx, fences: []))

      assert event_id == record.event_id
    end

    test "a producer ahead of the locally known fence is withheld", ctx do
      assignment = Factory.uuidv7()
      scope = Factory.network_scope_id()

      record =
        Factory.record(ctx.keys.private,
          producer_assignment_id: assignment,
          network_scope_id: scope,
          authority_epoch: 3
        )

      trust = snapshot(ctx, fences: [{scope, assignment, 0, 2}])

      assert {:error, :retryable, :fence_not_ready, _} = authorize(ctx, record, snapshot: trust)
    end

    test "a stale-epoch producer without a delivery capability is rejected", ctx do
      {record, trust} = stale_record(ctx)
      assert {:error, :permanent, :fence_stale, _} = authorize(ctx, record, snapshot: trust)
    end

    test "a stale-epoch immutable replay is permitted only for audit, stamped late-fenced", ctx do
      {record, trust} = stale_record(ctx)
      dc = Factory.delivery_capability(record, ctx.keys.private, spool_id: ctx.spool_id)

      assert {:ok, decision} = authorize(ctx, record, snapshot: trust, delivery_capability: dc)
      assert decision.publication == :audit
      assert decision.delivery_mode == @mode_late_fenced
      assert byte_size(decision.delivery_proof) == 32
    end

    test "a replay capability bound to different record bytes is rejected", ctx do
      {record, trust} = stale_record(ctx)

      dc =
        Factory.delivery_capability(record, ctx.keys.private, spool_id: ctx.spool_id, record_sha256: Factory.digest(99))

      assert {:error, :permanent, {:delivery_capability, :binding}, ""} =
               authorize(ctx, record, snapshot: trust, delivery_capability: dc)
    end

    test "a replay capability bound to a different event id is rejected", ctx do
      {record, trust} = stale_record(ctx)
      dc = Factory.delivery_capability(record, ctx.keys.private, spool_id: ctx.spool_id, event_id: Factory.uuidv7())

      assert {:error, :permanent, {:delivery_capability, :event_id}, _} =
               authorize(ctx, record, snapshot: trust, delivery_capability: dc)
    end

    test "an expired delivery capability does not authorize a replay", ctx do
      {record, trust} = stale_record(ctx)
      hour = Factory.hour_nanos()

      dc =
        Factory.delivery_capability(record, ctx.keys.private,
          spool_id: ctx.spool_id,
          not_before: now() - 3 * hour,
          expires: now() - 2 * hour
        )

      assert {:error, :retryable, {:delivery, :authority_expired}, _} =
               authorize(ctx, record, snapshot: trust, delivery_capability: dc)
    end
  end

  defp authorize(ctx, record, opts \\ []) do
    frame =
      Factory.frame(record, spool_id: ctx.spool_id, delivery_capability: Keyword.get(opts, :delivery_capability))

    snapshot = Keyword.get_lazy(opts, :snapshot, fn -> snapshot(ctx) end)
    identity = EdgeRecordTrust.with_network_scopes(snapshot, Keyword.get(opts, :identity, ctx.identity))

    EdgeRecordAuthorization.authorize_frame(frame, Keyword.get(opts, :lane, ctx.lane), identity, snapshot, now())
  end

  defp fence(record) do
    context = record.producer_context
    {record.network_scope_id, context.producer_assignment_id, context.run_shard, context.authority_epoch}
  end

  defp snapshot(ctx, opts \\ []) do
    {:ok, snapshot} = EdgeRecordTrust.new(Factory.trust_document(ctx.keys.public, opts))
    snapshot
  end

  defp expired_record(ctx) do
    hour = Factory.hour_nanos()
    Factory.record(ctx.keys.private, not_before: now() - 3 * hour, expires: now() - 2 * hour)
  end

  defp stale_record(ctx) do
    assignment = Factory.uuidv7()
    scope = Factory.network_scope_id()

    record =
      Factory.record(ctx.keys.private, producer_assignment_id: assignment, network_scope_id: scope, authority_epoch: 1)

    {record, snapshot(ctx, fences: [{scope, assignment, 0, 2}])}
  end

  defp now, do: System.os_time(:nanosecond)
end
