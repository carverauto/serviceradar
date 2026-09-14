defmodule ServiceRadarAgentGateway.EdgeRecordAuthorizationTest do
  use ExUnit.Case, async: true

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

  describe "signatures and keys" do
    test "a production grant signed by an unknown key", ctx do
      forger = Factory.keypair()
      record = Factory.record(ctx.keys.private, production_signer: forger.private)

      assert {:error, :permanent, {:production, :signature}, _} = authorize(ctx, record)
    end

    test "a key not authorized to issue production grants", ctx do
      record = Factory.record(ctx.keys.private)
      trust = snapshot(ctx, purposes: ["source", "delivery"])

      assert {:error, :permanent, {:production, :key_invalid}, _} = authorize(ctx, record, snapshot: trust)
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

  describe "authority" do
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
      scope = Factory.uuidv7()

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

    EdgeRecordAuthorization.authorize_frame(
      frame,
      Keyword.get(opts, :lane, ctx.lane),
      Keyword.get(opts, :identity, ctx.identity),
      Keyword.get_lazy(opts, :snapshot, fn -> snapshot(ctx) end),
      now()
    )
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
    scope = Factory.uuidv7()

    record =
      Factory.record(ctx.keys.private, producer_assignment_id: assignment, network_scope_id: scope, authority_epoch: 1)

    {record, snapshot(ctx, fences: [{scope, assignment, 0, 2}])}
  end

  defp now, do: System.os_time(:nanosecond)
end
