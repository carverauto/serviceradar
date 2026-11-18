defmodule ServiceRadarAgentGateway.EdgeRecordLateAuthorizationTest do
  @moduledoc """
  The gateway's two late-admission decisions (openspec add-edge-production-time-admission, design
  Decisions 6 and 7, task 2.6c). The oracle is Go's `edgerecord.ValidateLateFrameSigned` and the
  design's dispositions, not this module's code:

    * on a LATE session, a compromise-revoked key, a foreign origin principal and a terminal
      authority interval go to security quarantine before any grant is considered; otherwise only
      core's late-admission grant, naming this record's production time and epoch, publishes, and
      the publication is the grant's; anything else is withheld, never rejected for it alone;
    * on a LIVE session whose lane open advertised late-admission version 1 or later, a record that
      cannot be delivered live -- a stale fence with no grant, a missing fence with no grant or a
      renewal, a scope no longer bound, a foreign origin -- resolves permanently as
      `:late_admission_required` so the agent relocates it to late storage; older agents keep
      today's dispositions.
  """

  use ExUnit.Case, async: true

  alias Serviceradar.Edge.V1.EdgeDeliveryRolloverV1
  alias ServiceRadarAgentGateway.EdgeRecordAuthorization
  alias ServiceRadarAgentGateway.EdgeRecordTrust
  alias ServiceRadarAgentGateway.TestSupport.EdgeRecordFactory, as: Factory

  @durable :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
  @bulk :EDGE_RECORD_TRAFFIC_CLASS_BULK
  @mode_late_fenced 4
  @mode_late_admission 5
  @day 24 * 3600 * 1_000_000_000

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

  # A record produced three days ago whose production grant expired long since: the case a late
  # session exists for.
  defp days_old_record(ctx, opts \\ []) do
    not_before = now() - 3 * @day
    Factory.record(ctx.keys.private, Keyword.merge([not_before: not_before, expires: not_before + @day], opts))
  end

  defp grant(ctx, record, opts \\ []) do
    Factory.late_admission_capability(record, ctx.keys.private, Keyword.put(opts, :spool_id, ctx.spool_id))
  end

  # The agent's assignment is gone: no fence and no scope binding for it remain.
  defp gone(ctx, opts \\ []), do: snapshot(ctx, Keyword.merge([fences: [], scopes: []], opts))

  defp late(ctx, record, opts \\ []) do
    frame = Factory.frame(record, spool_id: ctx.spool_id, delivery_capability: Keyword.get(opts, :delivery_capability))
    snapshot = Keyword.get_lazy(opts, :snapshot, fn -> gone(ctx) end)
    identity = EdgeRecordTrust.with_network_scopes(snapshot, ctx.identity)
    EdgeRecordAuthorization.authorize_late_frame(frame, ctx.lane, identity, snapshot, now())
  end

  defp live(ctx, record, version, opts \\ []) do
    frame = Factory.frame(record, spool_id: ctx.spool_id, delivery_capability: Keyword.get(opts, :delivery_capability))
    snapshot = Keyword.get_lazy(opts, :snapshot, fn -> snapshot(ctx) end)
    identity = EdgeRecordTrust.with_network_scopes(snapshot, ctx.identity)
    lane = Map.put(ctx.lane, :late_admission_protocol_version, version)
    EdgeRecordAuthorization.authorize_frame(frame, lane, identity, snapshot, now())
  end

  describe "a late session" do
    test "publishes a days-old record its grant admits PRIMARY, though its fence and scope are gone", ctx do
      record = days_old_record(ctx)

      assert {:ok, decision} = late(ctx, record, delivery_capability: grant(ctx, record))
      assert decision.publication == :primary
      assert decision.delivery_mode == @mode_late_admission
      assert byte_size(decision.delivery_proof) == 32
      assert decision.grant == :late_admission
    end

    test "takes the publication and reason from the grant, never from the current fence", ctx do
      record = days_old_record(ctx)
      audit = grant(ctx, record, decision: {:audit, :fenced_at_production})

      assert {:ok, decision} = late(ctx, record, delivery_capability: audit, snapshot: snapshot(ctx))
      assert {decision.publication, decision.late_reason} == {:audit, :fenced_at_production}
      assert decision.delivery_mode == @mode_late_admission
    end

    test "withholds a frame without a valid late grant, and never rejects it for that alone", ctx do
      record = days_old_record(ctx)
      renewal = Factory.delivery_capability(record, ctx.keys.private, spool_id: ctx.spool_id)
      expired = grant(ctx, record, not_before: now() - 3 * @day, expires: now() - 2 * @day)
      other_time = grant(ctx, record, produced_at: 1)
      other_epoch = grant(ctx, record, authority_epoch: 9)

      assert {:error, :retryable, :late_admission_grant_required, event_id} = late(ctx, record)
      assert event_id == record.event_id

      for dc <- [renewal, expired, other_time, other_epoch] do
        assert {:error, :retryable, {:late_admission_grant, _reason}, _} = late(ctx, record, delivery_capability: dc)
      end
    end

    test "quarantines a foreign origin, a revoked key and a terminal interval before any grant", ctx do
      record = days_old_record(ctx)
      primary = grant(ctx, record)

      foreign = days_old_record(ctx, principal: "agent-2")

      assert {:ok, %{publication: :security_quarantine, delivery_mode: 1, delivery_proof: nil}} =
               late(ctx, foreign, delivery_capability: grant(ctx, foreign))

      revoked = gone(ctx, status: "historically_revoked")

      assert {:ok, %{publication: :security_quarantine}} =
               late(ctx, record, delivery_capability: primary, snapshot: revoked)

      context = record.producer_context

      terminal =
        ctx
        |> gone()
        |> Map.update!(
          :terminal_intervals,
          &MapSet.put(
            &1,
            {{record.network_scope_id, context.producer_assignment_id, context.run_shard}, context.authority_epoch}
          )
        )

      # Even an already-issued PRIMARY grant loses to the terminal interval.
      assert {:ok, %{publication: :security_quarantine}} =
               late(ctx, record, delivery_capability: primary, snapshot: terminal)
    end

    test "leaves a retired registry epoch to core's AUDIT decision instead of rejecting it", ctx do
      newer = Factory.registry_epoch(epoch: Factory.contract_ref().registry_epoch + 1)
      record = days_old_record(ctx)
      trust = gone(ctx, contract_registry: Factory.registry_member([newer]))
      audit = grant(ctx, record, decision: {:audit, :contract_retired})

      assert {:ok, %{publication: :audit, late_reason: :contract_retired}} =
               late(ctx, record, delivery_capability: audit, snapshot: trust)
    end

    test "still rejects bytes that are not what they claim, or the wrong lane", ctx do
      record = days_old_record(ctx)
      frame = %{Factory.frame(record, spool_id: ctx.spool_id) | record_sha256: :binary.copy(<<0>>, 32)}
      snapshot = gone(ctx)

      assert {:error, :permanent, :record_sha256_mismatch, ""} =
               EdgeRecordAuthorization.authorize_late_frame(frame, ctx.lane, ctx.identity, snapshot, now())

      other_lane = %{ctx.lane | traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE}
      frame = Factory.frame(record, spool_id: ctx.spool_id, delivery_capability: grant(ctx, record))

      assert {:error, :permanent, :route_class_conflict, _} =
               EdgeRecordAuthorization.authorize_late_frame(frame, other_lane, ctx.identity, snapshot, now())
    end
  end

  describe "a live session at late-admission version 1" do
    test "resolves what it cannot deliver live as late admission required; version 0 keeps today's", ctx do
      {stale, stale_trust} = stale_record(ctx)
      expired = days_old_record(ctx)
      renewal = Factory.delivery_capability(expired, ctx.keys.private, spool_id: ctx.spool_id)
      foreign = Factory.record(ctx.keys.private, principal: "agent-2")

      cases = [
        # A stale fence with no grant: today's dead end.
        {stale, [snapshot: stale_trust], {:permanent, :fence_stale}},
        # A missing fence, with no grant and with a renewal: today's forever-withhold.
        {expired, [snapshot: snapshot(ctx, fences: [])], {:retryable, :fence_not_ready}},
        {expired, [snapshot: snapshot(ctx, fences: []), delivery_capability: renewal], {:retryable, :fence_not_ready}},
        # A scope no longer bound to the agent: today's withhold.
        {expired, [snapshot: snapshot(ctx, scopes: [])], {:retryable, :scope_unbound}},
        # Another principal's bytes: today's identity conflict.
        {foreign, [], {:permanent, :identity_conflict}}
      ]

      # Every case must run: a generator pattern silently skips what it does not match.
      assert length(cases) == 5

      for {record, opts, {class, reason}} <- cases do
        assert {:error, :permanent, :late_admission_required, event_id} = live(ctx, record, 1, opts)
        assert event_id == record.event_id
        assert {:error, ^class, ^reason, _} = live(ctx, record, 0, opts)
      end
    end

    test "keeps the grant-backed audit paths and a not-yet-learned fence as they are", ctx do
      {stale, stale_trust} = stale_record(ctx)
      replay = Factory.delivery_capability(stale, ctx.keys.private, spool_id: ctx.spool_id)

      assert {:ok, %{publication: :audit, delivery_mode: @mode_late_fenced}} =
               live(ctx, stale, 1, snapshot: stale_trust, delivery_capability: replay)

      expired = days_old_record(ctx)
      renewal = Factory.delivery_capability(expired, ctx.keys.private, spool_id: ctx.spool_id)
      {:delivery, claims} = renewal.claims

      rollover =
        Factory.sign(
          %{
            renewal
            | claims:
                {:delivery,
                 %{
                   claims
                   | transition:
                       {:rollover,
                        %EdgeDeliveryRolloverV1{
                          recovery_id: Factory.uuidv7(),
                          prior_spool_id: Factory.uuidv7(),
                          prior_sequence: 1
                        }}
                 }}
          },
          ctx.keys.private
        )

      assert {:ok, %{publication: :audit, grant: :rollover}} =
               live(ctx, expired, 1, snapshot: snapshot(ctx, fences: []), delivery_capability: rollover)

      ahead = snapshot(ctx, fences: [{expired.network_scope_id, expired.producer_context.producer_assignment_id, 0, 0}])
      assert {:error, :retryable, :fence_not_ready, _} = live(ctx, expired, 1, snapshot: ahead)
    end

    test "never accepts a late-admission grant on a live session", ctx do
      record = days_old_record(ctx)

      assert {:error, :permanent, {:delivery_capability, :transition}, _} =
               live(ctx, record, 1, delivery_capability: grant(ctx, record))
    end
  end

  defp snapshot(ctx, opts \\ []) do
    {:ok, snapshot} = EdgeRecordTrust.new(Factory.trust_document(ctx.keys.public, opts))
    snapshot
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
