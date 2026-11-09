defmodule ServiceRadar.Edge.RecoveryOperationsDbTest do
  use ServiceRadar.DataCase, async: true

  alias Monitoring.EdgeRecoveryRegistration
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.HashGrammar
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
             RecoveryOperations.receive_control(uuid(), ctx.agent, payload(ctx.plan, :tombstone))

    assert {:ok, %{tombstone_received: true}} = receive(ctx, payload(ctx.plan, :tombstone))

    assert {:ok, %{blocked_reason: "tombstone_conflict", tombstone_received: true}} =
             receive(ctx, payload(change_destination(ctx.plan), :tombstone))
  end

  defp receive(ctx, raw),
    do: RecoveryOperations.receive_control(ctx.plan.network_scope_id, ctx.agent, raw)

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
