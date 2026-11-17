defmodule ServiceRadar.Edge.LateAdmissionDbTest do
  @moduledoc """
  Late-admission grants issued from what the database actually holds (openspec
  add-edge-production-time-admission, Decisions 3 to 5): the append-only authority history, the
  ledger coverage watermark and the late-window setting. Synthetic history rows stand in for
  authority that was live days ago, which is what a record from an upgraded agent's flat spool
  names.

  Also pins task 2.4 for the trust document: every key it has carried stays present as valid. Core
  has one issuer key and no rotation today; a future rotation must keep this green by keeping a
  retired key for the late window.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.LateAdmission
  alias ServiceRadar.Edge.RecordTrust
  alias ServiceRadar.Repo

  @moduletag :integration

  @key IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
  @registry %{epochs: [%{epoch: 2}], invalid: []}
  @spool <<0x0190_0000_0002::48, 7::4, 0x0AB::12, 2::2, 0xEF::62>>
  @day 86_400

  setup do
    suffix = System.unique_integer([:positive])

    {:ok,
     agent: "agent-late-db-#{suffix}",
     scope: Ecto.UUID.bingenerate(),
     assignment: Ecto.UUID.bingenerate(),
     now: DateTime.utc_now()}
  end

  defp at(ctx, days_ago), do: DateTime.shift(ctx.now, second: -round(days_ago * @day))

  defp event_id(%DateTime{} = produced_at) do
    millis = DateTime.to_unix(produced_at, :millisecond)
    <<millis::48, 7::4, 0x456::12, 2::2, 0x0A0A::62>>
  end

  defp insert_interval!(ctx, epoch, from, until, reason) do
    Repo.query!(
      """
      INSERT INTO platform.edge_authority_history
        (assignment_id, assignment_kind, agent_id, network_scope_id, run_shard,
         authority_epoch, active_from, active_until, ended_reason)
      VALUES ($1::uuid, 'output_grant', $2, $3::uuid, 0, $4, $5, $6, $7)
      """,
      [ctx.assignment, ctx.agent, ctx.scope, epoch, from, until, reason]
    )
  end

  defp item(ctx, sequence, produced_at, epoch) do
    %{
      sequence: sequence,
      spool_id: @spool,
      event_id: event_id(produced_at),
      record_sha256: :crypto.hash(:sha256, "synthetic late record #{sequence}"),
      network_scope_id: ctx.scope,
      producer_assignment_id: ctx.assignment,
      run_shard: 0,
      authority_epoch: epoch,
      registry_epoch: 2
    }
  end

  defp issue(ctx, items, agent \\ nil) do
    LateAdmission.issue(agent || ctx.agent, items, key: @key, registry: @registry, now: ctx.now)
  end

  defp decision(%{delivery_capability: nil, refusal: refusal}), do: {:refused, refusal}

  defp decision(%{delivery_capability: capability}) do
    assert CapabilitySigning.verify(capability, :delivery, @key.public_key)
    {:delivery, claims} = capability.claims
    {:late_admission, late} = claims.transition
    {late.publication, late.reason}
  end

  test "a days-old record its agent produced while its epoch was live is PRIMARY", ctx do
    # Epoch 1 was live from ten days ago until two days ago; epoch 2 is live now.
    insert_interval!(ctx, 1, at(ctx, 10), at(ctx, 2), "epoch_changed")
    insert_interval!(ctx, 2, at(ctx, 2), nil, nil)

    assert {:ok, [old, current, fenced]} =
             issue(ctx, [
               item(ctx, 1, at(ctx, 6), 1),
               item(ctx, 2, at(ctx, 1), 2),
               # Produced while epoch 2 was live, but naming epoch 1.
               item(ctx, 3, at(ctx, 1), 1)
             ])

    assert decision(old) == {:EDGE_LATE_PUBLICATION_PRIMARY, :EDGE_LATE_DECISION_REASON_ADMITTED}

    assert decision(current) ==
             {:EDGE_LATE_PUBLICATION_PRIMARY, :EDGE_LATE_DECISION_REASON_ADMITTED}

    assert decision(fenced) ==
             {:EDGE_LATE_PUBLICATION_AUDIT, :EDGE_LATE_DECISION_REASON_FENCED_AT_PRODUCTION}
  end

  test "an epoch with no retained history is AUDIT, and a compromised one is AUDIT", ctx do
    insert_interval!(ctx, 4, at(ctx, 10), at(ctx, 1), "compromised")

    assert {:ok, [unknown, compromised]} =
             issue(ctx, [item(ctx, 1, at(ctx, 3), 3), item(ctx, 2, at(ctx, 3), 4)])

    assert decision(unknown) ==
             {:EDGE_LATE_PUBLICATION_AUDIT, :EDGE_LATE_DECISION_REASON_HISTORY_UNKNOWN}

    assert decision(compromised) ==
             {:EDGE_LATE_PUBLICATION_AUDIT, :EDGE_LATE_DECISION_REASON_COMPROMISE_ENDED}
  end

  test "a revoked certificate's interval gets no grant, whoever presents it", ctx do
    insert_interval!(ctx, 1, at(ctx, 10), at(ctx, 1), "certificate_revoked")
    late = [item(ctx, 1, at(ctx, 3), 1)]

    assert {:ok, [result]} = issue(ctx, late)
    assert decision(result) == {:refused, :certificate_revoked_interval}

    assert {:ok, [result]} = issue(ctx, late, "agent-successor-#{ctx.agent}")
    assert decision(result) == {:refused, :certificate_revoked_interval}
  end

  test "the default 14-day window and the ledger watermark bound PRIMARY", ctx do
    insert_interval!(ctx, 1, at(ctx, 40), nil, nil)

    # Coverage begins four days ago: a record produced five days ago may have been applied
    # and pruned already. The watermark only moves forward, so set it to a later value.
    Repo.query!(
      """
      INSERT INTO platform.edge_ledger_coverage (id, complete_since) VALUES (1, $1)
      ON CONFLICT (id) DO UPDATE
        SET complete_since = GREATEST(edge_ledger_coverage.complete_since, EXCLUDED.complete_since)
      """,
      [at(ctx, 4)]
    )

    assert {:ok, [too_old, pruned, covered]} =
             issue(ctx, [
               item(ctx, 1, at(ctx, 20), 1),
               item(ctx, 2, at(ctx, 5), 1),
               item(ctx, 3, at(ctx, 3), 1)
             ])

    assert decision(too_old) ==
             {:EDGE_LATE_PUBLICATION_AUDIT, :EDGE_LATE_DECISION_REASON_BEYOND_LATE_WINDOW}

    assert decision(pruned) ==
             {:EDGE_LATE_PUBLICATION_AUDIT, :EDGE_LATE_DECISION_REASON_LEDGER_PRUNED}

    assert decision(covered) ==
             {:EDGE_LATE_PUBLICATION_PRIMARY, :EDGE_LATE_DECISION_REASON_ADMITTED}
  end

  test "a record produced in core's future waits for a grant", ctx do
    insert_interval!(ctx, 1, at(ctx, 1), nil, nil)
    future = DateTime.shift(ctx.now, hour: 1)

    assert {:ok, [result]} = issue(ctx, [item(ctx, 1, future, 1)])
    assert decision(result) == {:refused, :not_yet}
  end

  test "a call naming more records than one batch is refused", ctx do
    items = for n <- 1..(LateAdmission.max_items() + 1), do: item(ctx, n, at(ctx, 1), 1)
    assert {:error, :too_many_items} = issue(ctx, items)
  end

  test "every key the trust document has carried stays present as valid" do
    {:ok, key} = IssuerKey.configured()
    {:ok, trust} = RecordTrust.snapshot(key)

    present =
      Map.new(trust["keys"], fn entry -> {entry["issuer_key_id"], entry["status"]} end)

    # Every key that signs anything the document vouches for, today the one configured issuer
    # key and every contract-registry epoch it signed, resolves in the document as valid.
    signing_key_ids =
      [
        Base.encode64(key.key_id)
        | Enum.map(trust["contract_registry"]["epochs"], & &1["signing_key_id"])
      ]

    for id <- Enum.uniq(signing_key_ids) do
      assert present[id] == "valid",
             "key #{id} signed trust content but is not valid in the document"
    end
  end
end
