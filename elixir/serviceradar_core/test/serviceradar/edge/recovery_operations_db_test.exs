defmodule ServiceRadar.Edge.RecoveryOperationsDbTest do
  use ServiceRadar.DataCase, async: true

  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.HashGrammar
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.RecoveryControl
  alias ServiceRadar.Edge.RecoveryGeneration
  alias ServiceRadar.Edge.RecoveryOperations
  alias ServiceRadar.Edge.RecoveryReceivedPage
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeLossManifestPageV1
  alias Serviceradar.Edge.V1.EdgeRecoveryControlPayloadV1
  alias Serviceradar.Edge.V1.EdgeUnattributableV1
  alias Serviceradar.Edge.V1.SpoolLossTombstoneV1

  require Ash.Query

  @moduletag :integration

  setup do
    {:ok, agent: "synthetic-recovery-#{System.unique_integer([:positive])}", plan: plan()}
  end

  test "registration replay retains intent without manufacturing a JetStream receipt", ctx do
    assert {:ok, first} = RecoveryOperations.register(ctx.agent, ctx.plan)
    assert {:ok, replay} = RecoveryOperations.register(ctx.agent, ctx.plan)
    assert replay.id == first.id
    assert replay.registration == first.registration
    refute replay.tombstone_received
    assert pages(ctx) == []

    assert {:ok, nil} =
             RecoveryOperations.fetch(
               ctx.plan.network_scope_id,
               ctx.agent <> "-other",
               ctx.plan.recovery_id
             )

    assert {:ok, nil} = RecoveryOperations.fetch(uuid(), ctx.agent, ctx.plan.recovery_id)
  end

  test "same-key changed root or destination blocks and preserves the original intent", ctx do
    for changed <- [change_destination(ctx.plan), change_loss(ctx.plan)] do
      agent = ctx.agent <> "-#{System.unique_integer([:positive])}"
      assert {:ok, first} = RecoveryOperations.register(agent, ctx.plan)
      assert {:ok, blocked} = RecoveryOperations.register(agent, changed)
      assert blocked.id == first.id
      assert blocked.blocked_reason == "registration_conflict"
      assert blocked.registration == first.registration
      assert {:ok, replay} = RecoveryOperations.register(agent, ctx.plan)
      assert replay.blocked_reason == "registration_conflict"
    end
  end

  test "page receipt is idempotent and a different digest fences the same recovery", ctx do
    assert {:ok, _} = RecoveryOperations.register(ctx.agent, ctx.plan)
    raw = payload(ctx.plan, :manifest_page)
    assert {:ok, %{blocked_reason: nil}} = receive(ctx, raw)
    assert {:ok, %{blocked_reason: nil}} = receive(ctx, raw)
    assert [first] = pages(ctx)
    assert first.payload == raw

    assert {:ok, %{blocked_reason: "page_conflict"}} =
             receive(ctx, payload(change_loss(ctx.plan), :manifest_page))

    assert [retained] = pages(ctx)
    assert retained.id == first.id
    assert retained.page_sha256 == first.page_sha256
    assert retained.payload == first.payload
  end

  test "tombstone receipt binds destination and cannot cross an authenticated namespace", ctx do
    assert {:error, :registration_missing} = receive(ctx, payload(ctx.plan, :tombstone))
    assert {:ok, _} = RecoveryOperations.register(ctx.agent, ctx.plan)

    assert {:error, :registration_missing} =
             RecoveryOperations.consume_control(
               uuid(),
               ctx.agent,
               payload(ctx.plan, :tombstone),
               cost()
             )

    assert {:ok, %{tombstone_received: true}} = receive(ctx, payload(ctx.plan, :tombstone))

    assert {:ok, %{blocked_reason: "tombstone_conflict", tombstone_received: true}} =
             receive(ctx, payload(change_destination(ctx.plan), :tombstone))
  end

  test "split intervals cannot overlap or replace the source's frozen allocation bounds", ctx do
    whole = %{ctx.plan | source_high_water: 20}
    first = interval(whole, 1, 10)
    assert {:ok, %{interval_registered: true}} = RecoveryOperations.register(ctx.agent, first)

    # A rejected short interval must not hide an earlier, wider admitted one
    # from the next overlap query.
    for {from, through} <- [{3, 4}, {5, 6}] do
      assert {:ok, %{blocked_reason: "source_interval_overlap", interval_registered: false}} =
               RecoveryOperations.register(ctx.agent, interval(whole, from, through))
    end

    assert {:ok, %{interval_registered: true}} =
             RecoveryOperations.register(ctx.agent, interval(whole, 11, 20))

    changed = interval(%{whole | source_high_water: 21}, 21, 21)

    assert {:ok, %{blocked_reason: "source_generation_conflict", interval_registered: false}} =
             RecoveryOperations.register(ctx.agent, changed)
  end

  test "allocation coordinates retain the full unsigned 64-bit range", ctx do
    high = 18_446_744_073_709_551_615

    plan =
      interval(
        %{ctx.plan | source_reclaim_watermark: high - 2, source_high_water: high},
        high - 1,
        high
      )

    assert {:ok, stored} = RecoveryOperations.register(ctx.agent, plan)
    assert Decimal.to_integer(stored.from_sequence) == high - 1
    assert Decimal.to_integer(stored.through_sequence) == high
    assert {:ok, replay} = RecoveryOperations.register(ctx.agent, plan)
    assert replay.id == stored.id
    assert replay.registration == stored.registration
  end

  test "received later intervals cannot resolve an earlier unknown hole", ctx do
    first = interval(%{ctx.plan | source_high_water: 4}, 1, 2)
    later = interval(%{ctx.plan | source_high_water: 4}, 3, 4)
    assert {:ok, _} = RecoveryOperations.register(ctx.agent, later)
    assert {:ok, :received} = consume(ctx, later, :manifest_page)
    assert {:ok, :applied} = consume(ctx, later, :tombstone)
    assert generation_prefix(ctx) == 0
    assert {:ok, %{state: :EDGE_RECOVERY_STATE_PENDING, resolved: nil}} = status(ctx, later)

    assert {:ok, _} = RecoveryOperations.register(ctx.agent, first)
    assert {:ok, :received} = consume(ctx, first, :tombstone)
    assert generation_prefix(ctx) == 0
    assert {:ok, :applied} = consume(ctx, first, :manifest_page)
    assert generation_prefix(ctx) == 4
    assert {:ok, :applied} = consume(ctx, later, :manifest_page)
    assert generation_prefix(ctx) == 4
  end

  test "completion retains its original signed prefix after a later interval applies", ctx do
    first = interval(%{ctx.plan | source_high_water: 4}, 1, 2)
    later = interval(%{ctx.plan | source_high_water: 4}, 3, 4)
    assert {:ok, _} = RecoveryOperations.register(ctx.agent, first)
    assert {:ok, :received} = consume(ctx, first, :tombstone)
    assert {:ok, %{state: :EDGE_RECOVERY_STATE_PENDING, resolved: nil}} = status(ctx, first)
    assert {:ok, :applied} = consume(ctx, first, :manifest_page)
    assert {:ok, completed} = status(ctx, first)
    assert completed.state == :EDGE_RECOVERY_STATE_RESOLVED
    assert completed.resolved.applied_through_sequence == 2
    assert completed.resolved.recovery_id == first.recovery_id

    assert completed.resolved.manifest_root_sha256 ==
             SpoolLossTombstoneV1.decode(first.tombstone).manifest_root_sha256

    assert completed.resolved.resolved_at_unix_nano > 0
    assert {:ok, issuer} = IssuerKey.configured()
    assert CapabilitySigning.verify(completed.resolution_capability, :source, issuer.public_key)
    {:source, claims} = completed.resolution_capability.claims
    assert claims.network_scope_id == first.network_scope_id
    assert claims.origin_principal_id == ctx.agent
    assert claims.scope_sha256 == HashGrammar.resolved_scope_digest(completed.resolved)

    assert {:ok, _} = RecoveryOperations.register(ctx.agent, later)
    assert {:ok, :received} = consume(ctx, later, :manifest_page)
    assert {:ok, :applied} = consume(ctx, later, :tombstone)
    assert {:ok, %{resolved: %{applied_through_sequence: 4}}} = status(ctx, later)
    assert {:ok, ^completed} = status(ctx, first)
    assert {:ok, ^completed} = RecoveryControl.register(ctx.agent, first)
  end

  test "underdeclared manifest work cannot commit a receipt or repair effects", ctx do
    assert {:ok, _} = RecoveryOperations.register(ctx.agent, ctx.plan)

    assert {:error, _} =
             RecoveryOperations.consume_control(
               ctx.plan.network_scope_id,
               ctx.agent,
               payload(ctx.plan, :manifest_page),
               %{rows: 1, bytes: 1}
             )

    assert pages(ctx) == []
    assert generation_prefix(ctx) == 0
  end

  defp consume(ctx, plan, kind),
    do:
      RecoveryOperations.consume_control(
        plan.network_scope_id,
        ctx.agent,
        payload(plan, kind),
        cost()
      )

  defp status(ctx, plan),
    do:
      RecoveryControl.get(ctx.agent, %Monitoring.EdgeRecoveryQuery{
        network_scope_id: plan.network_scope_id,
        recovery_id: plan.recovery_id
      })

  defp generation_prefix(ctx) do
    scope = Ecto.UUID.cast!(ctx.plan.network_scope_id)
    prior = Ecto.UUID.cast!(ctx.plan.prior_spool_id)

    generation =
      RecoveryGeneration
      |> Ash.Query.filter(
        network_scope_id == ^scope and agent_id == ^ctx.agent and prior_spool_id == ^prior
      )
      |> Ash.read_one!(actor: SystemActor.system(:recovery_operations_test))

    Decimal.to_integer(generation.applied_through)
  end

  defp interval(plan, first, last) do
    recovery_id = uuid()
    [raw] = plan.manifest_pages
    page = EdgeLossManifestPageV1.decode(raw)
    [span] = page.classification_spans

    page = %{
      page
      | recovery_id: recovery_id,
        classification_spans: [%{span | from_sequence: first, through_sequence: last}]
    }

    tombstone = %{SpoolLossTombstoneV1.decode(plan.tombstone) | recovery_id: recovery_id}

    with_manifest(
      %{plan | recovery_id: recovery_id, from_sequence: first, through_sequence: last},
      page,
      tombstone
    )
  end

  defp receive(ctx, raw) do
    with {:ok, _state} <-
           RecoveryOperations.consume_control(ctx.plan.network_scope_id, ctx.agent, raw, cost()),
         do: RecoveryOperations.fetch(ctx.plan.network_scope_id, ctx.agent, ctx.plan.recovery_id)
  end

  defp cost, do: %{rows: 22, bytes: 1_081_344}

  defp pages(ctx) do
    recovery_id = Ecto.UUID.cast!(ctx.plan.recovery_id)
    scope = Ecto.UUID.cast!(ctx.plan.network_scope_id)

    RecoveryReceivedPage
    |> Ash.Query.filter(
      recovery_id == ^recovery_id and network_scope_id == ^scope and agent_id == ^ctx.agent
    )
    |> Ash.read!(actor: SystemActor.system(:recovery_operations_test))
  end

  defp plan do
    recovery_id = uuid()

    page = %EdgeLossManifestPageV1{
      recovery_id: recovery_id,
      page_index: 0,
      page_count: 1,
      terminal: true,
      digest_version: 1,
      classification_spans: [loss(:EDGE_UNATTRIBUTABLE_REASON_TORN_TAIL)]
    }

    tombstone = %SpoolLossTombstoneV1{
      recovery_id: recovery_id,
      prior_spool_id: uuid(),
      new_spool_id: uuid(),
      manifest_page_count: 1,
      detected_at_unix_nano: 1_800_000_000_000_000_000,
      reason: "synthetic_crash",
      digest_version: 1
    }

    with_manifest(
      %EdgeRecoveryRegistration{
        protocol_version: 1,
        network_scope_id: uuid(),
        recovery_id: recovery_id,
        prior_spool_id: tombstone.prior_spool_id,
        new_spool_id: tombstone.new_spool_id,
        route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
        traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
        source_high_water: 2,
        from_sequence: 1,
        through_sequence: 2
      },
      page,
      tombstone
    )
  end

  defp change_loss(plan) do
    [raw] = plan.manifest_pages
    page = EdgeLossManifestPageV1.decode(raw)
    tombstone = SpoolLossTombstoneV1.decode(plan.tombstone)
    page = %{page | classification_spans: [loss(:EDGE_UNATTRIBUTABLE_REASON_BINDING_CORRUPT)]}
    with_manifest(plan, page, tombstone)
  end

  defp change_destination(plan) do
    destination = uuid()
    tombstone = %{SpoolLossTombstoneV1.decode(plan.tombstone) | new_spool_id: destination}
    %{plan | new_spool_id: destination, tombstone: SpoolLossTombstoneV1.encode(tombstone)}
  end

  defp with_manifest(plan, page, tombstone) do
    page = %{page | page_sha256: HashGrammar.manifest_page_digest(page)}
    tombstone = %{tombstone | manifest_root_sha256: HashGrammar.manifest_root([page])}

    %{
      plan
      | manifest_pages: [EdgeLossManifestPageV1.encode(page)],
        tombstone: SpoolLossTombstoneV1.encode(tombstone)
    }
  end

  defp payload(plan, :manifest_page) do
    [raw] = plan.manifest_pages

    EdgeRecoveryControlPayloadV1.encode(%EdgeRecoveryControlPayloadV1{
      body: {:manifest_page, EdgeLossManifestPageV1.decode(raw)}
    })
  end

  defp payload(plan, :tombstone),
    do:
      EdgeRecoveryControlPayloadV1.encode(%EdgeRecoveryControlPayloadV1{
        body: {:tombstone, SpoolLossTombstoneV1.decode(plan.tombstone)}
      })

  defp loss(reason),
    do: %EdgeClassificationSpanV1{
      from_sequence: 1,
      through_sequence: 2,
      classification: {:unattributable, %EdgeUnattributableV1{reason: reason}}
    }

  defp uuid, do: Ecto.UUID.dump!(Ash.UUIDv7.generate())
end
