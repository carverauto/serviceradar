defmodule ServiceRadar.Edge.LateAdmissionTest do
  @moduledoc """
  Core's production-time decision for a late record (openspec add-edge-production-time-admission,
  design Decision 3, checks 6 to 9). The oracle is the design's table: a record its own agent
  produced while the epoch it names was live, inside the late window, still covered by the ledger
  and under an admitted registry epoch is PRIMARY; any other verified record is AUDIT with the
  failing check's reason; only a terminal interval and a production time still in core's future
  get no grant.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.LateAdmission
  alias ServiceRadar.Edge.PublicationIdentity
  alias Serviceradar.Edge.V1.EdgeDeliveryClaimsV1
  alias Serviceradar.Edge.V1.EdgeDeliveryLateAdmissionV1
  alias Serviceradar.Edge.V1.EdgeProducerContext
  alias Serviceradar.Edge.V1.EdgeRecordV1

  @agent "agent-late-synthetic"
  @scope <<0x5C0E::16, 0::112>>
  @assignment <<0xA551::16, 0::112>>
  @spool <<0x0190_0000_0001::48, 7::4, 0x0AB::12, 2::2, 0xCD::62>>
  @now ~U[2026-11-10 12:00:00.000000Z]
  @day 86_400

  defp at(days_ago), do: DateTime.shift(@now, second: -round(days_ago * @day))

  # A UUIDv7 whose embedded time is `produced_at`, as an edge producer mints it.
  defp event_id(%DateTime{} = produced_at) do
    millis = DateTime.to_unix(produced_at, :millisecond)
    <<millis::48, 7::4, 0x123::12, 2::2, 0x0F0F::62>>
  end

  defp item(produced_at, overrides \\ []) do
    Map.merge(
      %{
        sequence: 5,
        spool_id: @spool,
        event_id: event_id(produced_at),
        record_sha256: :crypto.hash(:sha256, "synthetic late record"),
        network_scope_id: @scope,
        producer_assignment_id: @assignment,
        run_shard: 0,
        authority_epoch: 3,
        registry_epoch: 2
      },
      Map.new(overrides)
    )
  end

  defp interval(from_days_ago, until_days_ago, reason \\ nil, overrides \\ []) do
    Map.merge(
      %{
        agent_id: @agent,
        network_scope_id: @scope,
        run_shard: 0,
        active_from: at(from_days_ago),
        active_until: until_days_ago && at(until_days_ago),
        ended_reason: reason
      },
      Map.new(overrides)
    )
  end

  defp context(intervals, overrides \\ []) do
    Map.merge(
      %{
        intervals: %{{@assignment, 3} => intervals},
        max_age_seconds: 14 * @day,
        complete_since: at(30),
        admitted_registry_epochs: MapSet.new([2])
      },
      Map.new(overrides)
    )
  end

  defp decide(item, context), do: LateAdmission.decide(item, @agent, context, @now)

  test "a record its agent produced while its epoch was live is PRIMARY, days later" do
    assert decide(item(at(3)), context([interval(10, nil)])) == {:grant, :primary, :admitted}
    # An epoch that has since ended still covers what was produced while it was live.
    assert decide(item(at(3)), context([interval(10, 1, "epoch_changed")])) ==
             {:grant, :primary, :admitted}
  end

  test "an epoch that was not live when the record was produced makes it AUDIT" do
    ended_before = context([interval(10, 5, "epoch_changed")])
    assert decide(item(at(3)), ended_before) == {:grant, :audit, :fenced_at_production}

    started_after = context([interval(2, nil)])
    assert decide(item(at(3)), started_after) == {:grant, :audit, :fenced_at_production}

    other_binding = context([interval(10, nil, nil, agent_id: "agent-other")])
    assert decide(item(at(3)), other_binding) == {:grant, :audit, :fenced_at_production}
  end

  test "the clock tolerance is honoured at both ends of an interval" do
    four_minutes = 4 * 60
    starts = context([interval(3, nil)])
    produced = DateTime.shift(at(3), second: -four_minutes)
    assert decide(item(produced), starts) == {:grant, :primary, :admitted}

    ends = context([interval(10, 3, "epoch_changed")])
    produced = DateTime.shift(at(3), second: four_minutes)
    assert decide(item(produced), ends) == {:grant, :primary, :admitted}
  end

  test "an epoch core has no interval for is AUDIT, never invented" do
    assert decide(item(at(3)), context([])) == {:grant, :audit, :history_unknown}
  end

  test "an explicitly compromised interval is AUDIT" do
    assert decide(item(at(3)), context([interval(10, 1, "compromised")])) ==
             {:grant, :audit, :compromise_ended}
  end

  test "a terminal interval gets no grant whoever presents it, even before revocation" do
    for reason <- ["certificate_revoked", "revoked_cause_unknown"] do
      revoked = context([interval(10, 1, reason)])
      assert decide(item(at(3)), revoked) == {:refuse, :certificate_revoked_interval}

      assert LateAdmission.decide(item(at(3)), "agent-other", revoked, @now) ==
               {:refuse, :certificate_revoked_interval}
    end
  end

  test "the late window, ledger coverage and registry epoch each make a record AUDIT" do
    live = [interval(40, nil)]

    assert decide(item(at(20)), context(live)) == {:grant, :audit, :beyond_late_window}

    assert decide(item(at(5)), context(live, complete_since: at(4))) ==
             {:grant, :audit, :ledger_pruned}

    assert decide(item(at(5)), context(live, complete_since: nil)) ==
             {:grant, :primary, :admitted}

    assert decide(item(at(5), registry_epoch: 1), context(live)) ==
             {:grant, :audit, :contract_retired}
  end

  test "a production time still in core's future gets no grant yet" do
    future = DateTime.shift(@now, minute: 10)
    assert decide(item(future), context([interval(1, nil)])) == {:refuse, :not_yet}

    # A future production time does not suppress the terminal-interval refusal.
    assert decide(item(future), context([interval(10, 1, "certificate_revoked")])) ==
             {:refuse, :certificate_revoked_interval}

    # Within the clock tolerance it is judged normally.
    near = DateTime.shift(@now, minute: 4)
    assert decide(item(near), context([interval(1, nil)])) == {:grant, :primary, :admitted}
  end

  test "a grant binds the record, its production time and epoch, and verifies as a delivery capability" do
    key = IssuerKey.from_seed(:binary.copy(<<0x37>>, 32))
    produced_at = at(3)
    item = item(produced_at)

    capability = LateAdmission.grant(item, {:grant, :audit, :ledger_pruned}, key, @now)

    assert CapabilitySigning.verify(capability, :delivery, key.public_key)
    assert {:delivery, %EdgeDeliveryClaimsV1{} = claims} = capability.claims

    assert %{
             event_id: event_id,
             record_sha256: sha,
             spool_id: @spool,
             sequence: 5,
             transition: {:late_admission, %EdgeDeliveryLateAdmissionV1{} = late}
           } = claims

    assert {event_id, sha} == {item.event_id, item.record_sha256}
    assert late.produced_at_unix_nano == DateTime.to_unix(produced_at, :nanosecond)
    assert late.authority_epoch == 3
    assert late.publication == :EDGE_LATE_PUBLICATION_AUDIT
    assert late.reason == :EDGE_LATE_DECISION_REASON_LEDGER_PRUNED

    # Short-lived: it authorizes a drain happening now, like a renewal grant.
    assert capability.not_before_unix_nano == DateTime.to_unix(@now, :nanosecond)
    assert capability.expires_at_unix_nano > capability.not_before_unix_nano
  end

  # EventWriter acts on a late record only under the decision core signed for exactly that record
  # (Decision 7), so the gateway cannot restate it.
  test "a delivered grant verifies only when core signed it for exactly this record and proof" do
    key = IssuerKey.from_seed(:binary.copy(<<0x37>>, 32))
    produced_at = at(3)
    item = item(produced_at)
    grant = LateAdmission.grant(item, {:grant, :audit, :ledger_pruned}, key, @now)

    {:ok, proof} =
      PublicationIdentity.delivery_proof_digest(grant, PublicationIdentity.mode_late_admission())

    delivery = %{
      record: %EdgeRecordV1{
        event_id: item.event_id,
        producer_context: %EdgeProducerContext{authority_epoch: 3}
      },
      record_sha256: item.record_sha256,
      slot: %{spool_id: @spool, sequence: 5},
      proof: proof
    }

    assert LateAdmission.verify_delivered(grant, delivery, key) ==
             {:ok,
              %{
                produced_at:
                  DateTime.from_unix!(
                    DateTime.to_unix(produced_at, :millisecond) * 1_000,
                    :microsecond
                  ),
                publication: :audit,
                reason: :ledger_pruned,
                issuer_key_id: key.key_id
              }}

    other_key = IssuerKey.from_seed(:binary.copy(<<0x38>>, 32))
    forged = %{grant | signature: :binary.copy(<<0>>, 64)}

    {:ok, forged_proof} =
      PublicationIdentity.delivery_proof_digest(forged, PublicationIdentity.mode_late_admission())

    other_epoch = put_in(delivery.record.producer_context.authority_epoch, 4)

    for {candidate, delivery, verifier, reason} <- [
          {grant, %{delivery | proof: :crypto.hash(:sha256, "another grant")}, key, :proof},
          {grant, delivery, other_key, :issuer},
          {forged, %{delivery | proof: forged_proof}, key, :signature},
          {grant, %{delivery | record_sha256: :crypto.hash(:sha256, "other bytes")}, key,
           :binding},
          {grant, %{delivery | slot: %{spool_id: @spool, sequence: 6}}, key, :binding},
          {grant, other_epoch, key, :binding},
          {grant, put_in(delivery.record.event_id, binary_part(item.event_id, 0, 15)), key,
           :binding},
          {grant, put_in(delivery.record.producer_context.authority_epoch, -1), key, :binding},
          {grant, put_in(delivery.record.producer_context.authority_epoch, nil), key, :binding}
        ] do
      assert LateAdmission.verify_delivered(candidate, delivery, verifier) ==
               {:error, {:late_admission_grant, reason}}
    end
  end
end
