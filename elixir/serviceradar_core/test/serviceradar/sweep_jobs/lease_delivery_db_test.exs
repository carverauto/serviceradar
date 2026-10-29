defmodule ServiceRadar.SweepJobs.LeaseDeliveryDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.IssuerKey
  alias Serviceradar.Edge.V1.SweepLeaseV1
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseDelivery
  alias ServiceRadar.SweepJobs.LeasePass
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepLeaseSetting

  @moduletag :integration

  @key IssuerKey.from_seed(:binary.copy(<<0x5A>>, 32))
  @contract %{
    contract_id: "serviceradar.sweep.observation",
    contract_version: 1,
    contract_bundle_sha256: :crypto.hash(:sha256, "bundle"),
    registry_epoch: 1,
    registry_snapshot_sha256: :crypto.hash(:sha256, "snapshot"),
    cost_model_version: 1,
    max_projected_row_count: 10_000,
    max_projected_write_bytes: 20_480_000
  }

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    admin = %{id: Ash.UUID.generate(), email: "admin-#{suffix}@example.test", role: :admin}
    partition = partition!(admin, "lease-#{suffix}")
    agent = agent_with_device!(admin, "agent-#{suffix}", partition.slug, "192.0.2.10")
    test_pid = self()

    sender = fn agent_id, group_id, payload ->
      send(test_pid, {:pushed, agent_id, group_id, SweepLeaseV1.decode(payload), payload})
      :ok
    end

    delivery = %{authority: %{key: @key, contract: @contract}, sender: sender}

    {:ok, admin: admin, suffix: suffix, partition: partition, agent: agent, delivery: delivery}
  end

  test "the first pass pushes the whole lease, signed, and a second pass pushes nothing", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, agent_id, group_id, lease, payload}
    assert {agent_id, group_id} == {ctx.agent, group.id}

    assignment = assignment!(group, ctx.agent)
    slots = unrun!(assignment, now)

    assert lease.lease_id == Ecto.UUID.dump!(LeasePass.lease_id(assignment))
    assert lease.authority_epoch == assignment.authority_epoch
    assert lease.window_start_unix_nano == DateTime.to_unix(now, :nanosecond)
    refute lease.revoked
    assert Enum.map(lease.slots, & &1.execution_id) == Enum.map(slots, &Ecto.UUID.dump!(&1.id))

    cap = lease.production_capability
    assert CapabilitySigning.verify(cap, :production, @key.public_key)
    assert cap.not_before_unix_nano == DateTime.to_unix(now, :nanosecond)

    for slot <- lease.slots do
      assert length(slot.source_authorizations) == 2

      assert Enum.all?(
               slot.source_authorizations,
               &CapabilitySigning.verify(&1.capability, :source, @key.public_key)
             )

      assert slot.plan_header.execution_plan_sha256 != ""
      assert lease.window_start_unix_nano < slot.slot_start_unix_nano
      assert slot.slot_start_unix_nano < lease.window_end_unix_nano
    end

    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)

    assert row.delivered_payload_sha256 ==
             Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: row.delivered_payload_sha256,
               installed: true
             })

    assert %{pushed: 0} = LeasePass.reconcile_group(group, now, ctx.delivery)
    refute_receive {:pushed, _, _, _, _}, 50
  end

  test "shrinking the horizon and growing it back delivers the re-minted slots as a tail",
       ctx do
    lease_on!(ctx, 7_200)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, payload}

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    # Ahead of the drop's wall clock, so the shrink is the delivery those drops are
    # since, and growing the horizon back is a tail from the short cursor.
    later = DateTime.shift(now, minute: 2)

    setting!(ctx.admin, :partition, ctx.partition.id,
      leasing_enabled: true,
      horizon_seconds: 1_800
    )

    assert %{pushed: 1} = LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, shrunk, shrunk_payload}
    assert shrunk.window_start_unix_nano == DateTime.to_unix(later, :nanosecond)
    assert shrunk.slots != []
    assert length(shrunk.slots) < length(first.slots)
    assert shrunk.window_end_unix_nano == first.window_end_unix_nano

    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)
    cursor = DateTime.to_unix(row.delivered_window_end, :nanosecond)
    assert cursor == List.last(shrunk.slots).slot_start_unix_nano + 1_000
    assert cursor < shrunk.window_end_unix_nano

    assert DateTime.to_unix(row.delivered_high_water, :nanosecond) ==
             shrunk.window_end_unix_nano

    # The shrink has to be installed before a tail is allowed. While it is
    # unacked and the cursor sits behind the high water, the next pass resends
    # the full window.
    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(shrunk_payload),
               installed: true
             })

    setting!(ctx.admin, :partition, ctx.partition.id,
      leasing_enabled: true,
      horizon_seconds: 7_200
    )

    assert %{pushed: 1} = LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, tail, _}

    assert tail.slots != []
    assert tail.window_start_unix_nano == cursor
    refute tail.window_start_unix_nano == DateTime.to_unix(later, :nanosecond)
    assert Enum.all?(tail.slots, &(&1.slot_start_unix_nano >= cursor))
    assert MapSet.disjoint?(starts(tail.slots), starts(shrunk.slots))
    assert Enum.any?(tail.slots, &(&1.slot_start_unix_nano < first.window_end_unix_nano))

    assert tail.window_end_unix_nano ==
             List.last(tail.slots).slot_start_unix_nano + 1_000
  end

  test "a refused shrink is retried out to the window the agent already holds", ctx do
    lease_on!(ctx, 7_200)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, payload}

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    setting!(ctx.admin, :partition, ctx.partition.id,
      leasing_enabled: true,
      horizon_seconds: 1_800
    )

    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, shrunk, shrunk_payload}
    assert shrunk.slots != []
    assert length(shrunk.slots) < length(first.slots)
    assert shrunk.window_end_unix_nano == first.window_end_unix_nano

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(shrunk_payload),
               installed: false,
               error: "plan rejected"
             })

    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, retry, _}
    assert retry.lease_id == first.lease_id
    assert retry.slots != []
    assert length(retry.slots) < length(first.slots)
    assert retry.window_end_unix_nano == first.window_end_unix_nano
    assert List.last(retry.slots).slot_start_unix_nano + 1_000 < retry.window_end_unix_nano

    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)

    assert DateTime.to_unix(row.delivered_window_end, :nanosecond) ==
             List.last(retry.slots).slot_start_unix_nano + 1_000

    assert DateTime.to_unix(row.delivered_high_water, :nanosecond) ==
             first.window_end_unix_nano
  end

  test "an unacked shrink is resent in full out to the high water", ctx do
    lease_on!(ctx, 7_200)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, payload}

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    later = DateTime.shift(now, minute: 2)

    setting!(ctx.admin, :partition, ctx.partition.id,
      leasing_enabled: true,
      horizon_seconds: 1_800
    )

    assert %{pushed: 1} = LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, shrunk, _}
    assert shrunk.slots != []
    assert shrunk.window_end_unix_nano == first.window_end_unix_nano

    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)
    cursor = row.delivered_window_end
    assert DateTime.before?(cursor, row.delivered_high_water)
    assert row.acked_payload_sha256 != row.delivered_payload_sha256

    assignment = assignment!(group, ctx.agent)
    [carried | _] = unrun!(assignment, later)
    minted_start = DateTime.shift(cursor, minute: 1)

    assert {:ok, minted} =
             ExecutionSlots.schedule(
               assignment,
               minted_start,
               DateTime.shift(minted_start, minute: 15),
               targets: group.static_targets,
               check_set_sha256: carried.check_set_sha256,
               lease_id: LeasePass.lease_id(assignment)
             )

    # Still inside the ack grace, so only the short cursor forces this resend.
    assert {:ok, :pushed} =
             LeaseDelivery.deliver(assignment, ctx.delivery.authority, later, ctx.delivery.sender)

    assert_receive {:pushed, _, _, resent, _}
    assert resent.lease_id == first.lease_id
    assert resent.window_start_unix_nano == DateTime.to_unix(later, :nanosecond)
    assert resent.window_end_unix_nano == first.window_end_unix_nano
    refute resent.window_start_unix_nano == DateTime.to_unix(cursor, :nanosecond)

    resent_ids = MapSet.new(resent.slots, & &1.execution_id)
    assert Ecto.UUID.dump!(minted.id) in resent_ids
    assert Ecto.UUID.dump!(carried.id) in resent_ids
    assert DateTime.before?(carried.slot_start, cursor)

    assert {:ok, [after_row]} = LeaseDelivery.list_for_group(group.id)

    assert DateTime.to_unix(after_row.delivered_window_end, :nanosecond) ==
             DateTime.to_unix(minted_start, :nanosecond) + 1_000

    assert DateTime.to_unix(after_row.delivered_high_water, :nanosecond) ==
             first.window_end_unix_nano
  end

  test "an empty horizon replaces the delivered window with no slots and no capability",
       ctx do
    lease_on!(ctx, 7_200)
    group = leased_group!(ctx)
    now = clear_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, payload}
    assert first.slots != []

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    setting!(ctx.admin, :partition, ctx.partition.id,
      leasing_enabled: true,
      horizon_seconds: 1
    )

    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, cleared, _}
    assert cleared.lease_id == first.lease_id
    refute cleared.revoked
    assert cleared.slots == []
    assert cleared.production_capability == nil
    assert cleared.window_start_unix_nano == DateTime.to_unix(now, :nanosecond)
    assert cleared.window_end_unix_nano == first.window_end_unix_nano

    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)

    assert DateTime.to_unix(row.delivered_window_end, :nanosecond) ==
             cleared.window_start_unix_nano

    assert DateTime.to_unix(row.delivered_high_water, :nanosecond) ==
             cleared.window_end_unix_nano
  end

  test "restoring the horizon after an empty clear delivers the re-minted slots", ctx do
    lease_on!(ctx, 7_200)
    group = leased_group!(ctx)
    now = clear_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, payload}
    assert first.slots != []

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    # Ahead of the drops' wall clock, so the clear is the delivery those drops
    # are since and the restore is judged on the cursor alone.
    later = clear_at(DateTime.shift(now, minute: 2))

    setting!(ctx.admin, :partition, ctx.partition.id,
      leasing_enabled: true,
      horizon_seconds: 1
    )

    assert %{pushed: 1} = LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, cleared, cleared_payload}
    assert cleared.slots == []

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(cleared_payload),
               installed: true
             })

    setting!(ctx.admin, :partition, ctx.partition.id,
      leasing_enabled: true,
      horizon_seconds: 7_200
    )

    assert %{pushed: 1} = LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, restored, _}

    assignment = assignment!(group, ctx.agent)
    slots = unrun!(assignment, later)

    assert restored.slots != []
    assert restored.window_start_unix_nano == DateTime.to_unix(later, :nanosecond)

    assert Enum.map(restored.slots, & &1.execution_id) ==
             Enum.map(slots, &Ecto.UUID.dump!(&1.id))

    # The earliest re-minted slots start inside the window the first push
    # delivered, behind where its cursor sat.
    assert hd(restored.slots).slot_start_unix_nano < first.window_end_unix_nano
  end

  test "a slot minted behind the cursor is carried by a full push, not passed by", ctx do
    lease_on!(ctx, 7_200)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, _first, payload}

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    assignment = assignment!(group, ctx.agent)
    [first_slot | _] = unrun!(assignment, now)
    interior_start = DateTime.shift(first_slot.slot_start, minute: 1)

    assert {:ok, interior} =
             ExecutionSlots.schedule(
               assignment,
               interior_start,
               DateTime.shift(interior_start, minute: 15),
               targets: group.static_targets,
               check_set_sha256: first_slot.check_set_sha256,
               lease_id: LeasePass.lease_id(assignment)
             )

    assert {:ok, :pushed} =
             LeaseDelivery.deliver(assignment, ctx.delivery.authority, now, ctx.delivery.sender)

    assert_receive {:pushed, _, _, lease, payload}
    assert lease.window_start_unix_nano == DateTime.to_unix(now, :nanosecond)
    assert Ecto.UUID.dump!(interior.id) in Enum.map(lease.slots, & &1.execution_id)

    assert %{} = marked = Enum.find(unrun!(assignment, now), &(&1.id == interior.id))
    assert marked.delivered_at

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    assert {:ok, :up_to_date} =
             LeaseDelivery.deliver(assignment, ctx.delivery.authority, now, ctx.delivery.sender)
  end

  test "an unacknowledged full window is resent before the acknowledgement grace", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, _}

    later = DateTime.shift(now, minute: 5)
    assert %{pushed: 1} = LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, resent, _}

    assert resent.window_start_unix_nano == DateTime.to_unix(later, :nanosecond)
    assert resent.lease_id == first.lease_id

    remaining =
      first.slots
      |> Enum.filter(&(&1.slot_start_unix_nano > DateTime.to_unix(later, :nanosecond)))
      |> MapSet.new(& &1.execution_id)

    assert MapSet.size(remaining) > 0
    assert MapSet.subset?(remaining, MapSet.new(resent.slots, & &1.execution_id))
  end

  test "a later pass pushes only the newly minted tail under the first issuance time", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, payload}

    # The agent installed it; an unacknowledged push would be resent whole instead.
    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: Base.encode16(:crypto.hash(:sha256, payload), case: :lower),
               installed: true
             })

    later = DateTime.shift(now, minute: 30)
    assert %{pushed: 1} = LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, tail, _}

    assert tail.lease_id == first.lease_id
    assert tail.window_start_unix_nano == first.window_end_unix_nano
    assert tail.slots != []

    assert Enum.all?(tail.slots, &(&1.slot_start_unix_nano >= first.window_end_unix_nano))

    assert MapSet.disjoint?(
             MapSet.new(tail.slots, & &1.execution_id),
             MapSet.new(first.slots, & &1.execution_id)
           )

    assert tail.production_capability.not_before_unix_nano ==
             first.production_capability.not_before_unix_nano

    assert tail.production_capability.expires_at_unix_nano >
             first.production_capability.expires_at_unix_nano
  end

  test "a refused push, a fence bump and a lost ack each resend the whole window", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, _}
    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)

    # The agent refused it: the next pass starts again from now.
    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: row.delivered_payload_sha256,
               installed: false,
               error: "plan rejected"
             })

    retry = DateTime.shift(now, minute: 1)
    LeasePass.reconcile_group(group, retry, ctx.delivery)
    assert_receive {:pushed, _, _, resent, _}
    assert resent.lease_id == first.lease_id
    assert resent.window_start_unix_nano == DateTime.to_unix(retry, :nanosecond)

    # A fence bump is a new lease.
    assert {:ok, 1} = ProducerAssignments.bump_group(group.id)
    LeasePass.reconcile_group(group, retry, ctx.delivery)
    assert_receive {:pushed, _, _, bumped, _}
    refute bumped.lease_id == first.lease_id
    assert bumped.authority_epoch == first.authority_epoch + 1

    # No ack within the grace period: the window goes out again.
    late = DateTime.shift(retry, second: LeaseDelivery.ack_grace_seconds() + 60)
    LeasePass.reconcile_group(group, late, ctx.delivery)
    assert_receive {:pushed, _, _, again, _}
    assert again.lease_id == bumped.lease_id
    assert again.window_start_unix_nano == DateTime.to_unix(late, :nanosecond)
  end

  test "an installed ack records how far the agent can run", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    LeasePass.reconcile_group(group, DateTime.utc_now(), ctx.delivery)
    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)
    through = DateTime.shift(DateTime.utc_now(), hour: 1)

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: row.delivered_payload_sha256,
               installed: true,
               installed_through_unix_nano: DateTime.to_unix(through, :nanosecond),
               installed_slot_count: 4
             })

    assert {:ok, [acked]} = LeaseDelivery.list_for_group(group.id)
    assert acked.ack_installed
    assert acked.acked_slot_count == 4

    assert DateTime.to_unix(acked.acked_through, :microsecond) ==
             DateTime.to_unix(through, :microsecond)

    # An ack for a group the agent was never given is ignored.
    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{sweep_group_id: Ecto.UUID.generate()})
  end

  test "horizons show the acknowledged run time left and track an unacked resend", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)
    through = DateTime.shift(now, hour: 1)

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: row.delivered_payload_sha256,
               installed: true,
               installed_through_unix_nano: DateTime.to_unix(through, :nanosecond),
               installed_slot_count: 4
             })

    assert {:ok, horizons} =
             LeaseDelivery.horizons_for_groups([group.id, Ecto.UUID.generate()], now)

    assert map_size(horizons) == 1
    assert [horizon] = horizons[group.id]
    assert horizon.agent_id == ctx.agent
    assert horizon.status == :acknowledged
    assert horizon.acknowledged_slot_count == 4
    assert horizon.remaining_seconds == 3_600

    assert DateTime.to_unix(horizon.acknowledged_through, :microsecond) ==
             DateTime.to_unix(through, :microsecond)

    # A newer push keeps the installed horizon visible while the latest push is unacked.
    later = DateTime.shift(now, minute: 30)
    LeasePass.reconcile_group(group, later, ctx.delivery)
    group_id = group.id

    assert {:ok, %{^group_id => [waiting]}} =
             LeaseDelivery.horizons_for_groups([group.id], later)

    assert waiting.status == :awaiting_acknowledgement
    assert waiting.remaining_seconds == 1_800
    assert waiting.acknowledged_slot_count == 4

    for offset <- [300, 600] do
      assert %{pushed: 1} =
               LeasePass.reconcile_group(
                 group,
                 DateTime.shift(later, second: offset),
                 ctx.delivery
               )

      assert_receive {:pushed, _, _, _, _}
    end

    overdue_at = DateTime.shift(later, second: LeaseDelivery.ack_grace_seconds() + 1)

    assert {:ok, %{^group_id => [overdue]}} =
             LeaseDelivery.horizons_for_groups([group.id], overdue_at)

    assert overdue.status == :acknowledgement_overdue
    assert overdue.remaining_seconds == 1_800 - LeaseDelivery.ack_grace_seconds() - 1
  end

  test "a late ack for an older push does not overwrite the current push's ack", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, _, first_payload}
    first_digest = digest(first_payload)

    later = DateTime.shift(now, minute: 30)
    LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, _, second_payload}
    second_digest = digest(second_payload)
    refute second_digest == first_digest

    through = DateTime.shift(later, hour: 1)

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: second_digest,
               installed: true,
               installed_through_unix_nano: DateTime.to_unix(through, :nanosecond),
               installed_slot_count: 9
             })

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: first_digest,
               installed: false,
               error: "stale",
               installed_slot_count: 1
             })

    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)
    assert row.acked_payload_sha256 == second_digest
    assert row.ack_installed
    assert row.acked_slot_count == 9
    assert is_nil(row.ack_error)

    assert DateTime.to_unix(row.acked_through, :microsecond) ==
             DateTime.to_unix(through, :microsecond)
  end

  test "destroying a leased group revokes the delivery on the next pass", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, _}
    assert {:ok, [_row]} = LeaseDelivery.list_for_group(group.id)

    assert :ok = Ash.destroy(group, actor: ctx.admin)

    setting!(ctx.admin, :partition, ctx.partition.id,
      leasing_enabled: false,
      horizon_seconds: 3_600
    )

    assert {:ok, %{withdrawn: 1, pushed: 0, errors: 0}} =
             LeasePass.run(now, ctx.delivery)

    assert_receive {:pushed, _, group_id, revocation, payload}
    assert group_id == group.id
    assert revocation.revoked
    assert revocation.lease_id == first.lease_id
    assert revocation.slots == []
    assert revocation.production_capability == nil
    assert {:ok, [pending]} = LeaseDelivery.list_for_group(group.id)
    assert pending.revoked_at

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    assert {:ok, []} = LeaseDelivery.list_for_group(group.id)
  end

  test "an agent the group stops leasing to gets a revocation and loses its delivery", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, _}

    setting!(ctx.admin, :agent, ctx.agent, leasing_enabled: false)
    assert %{withdrawn: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, revocation, payload}

    assert revocation.revoked
    assert revocation.lease_id == first.lease_id
    assert revocation.slots == []
    assert revocation.production_capability == nil
    assert {:ok, [pending]} = LeaseDelivery.list_for_group(group.id)
    assert pending.revoked_at
    retry = DateTime.shift(now, minute: 5)
    assert %{withdrawn: 1} = LeasePass.reconcile_group(group, retry, ctx.delivery)
    assert_receive {:pushed, _, _, _, unacknowledged_payload}
    assert unacknowledged_payload == payload

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest("older synthetic push"),
               installed: true
             })

    assert {:ok, [_]} = LeaseDelivery.list_for_group(group.id)

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: false,
               error: "installation failed"
             })

    assert {:ok, [_]} = LeaseDelivery.list_for_group(group.id)

    retry = DateTime.shift(now, minute: 10)
    assert %{withdrawn: 1} = LeasePass.reconcile_group(group, retry, ctx.delivery)
    assert_receive {:pushed, _, _, repeated, repeated_payload}
    assert repeated.revoked
    assert repeated_payload == payload

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    assert {:ok, []} = LeaseDelivery.list_for_group(group.id)
  end

  test "resuming leasing supersedes a pending revocation and ignores its late acknowledgement",
       ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()
    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, _, _}

    assert {:ok, 1} = LeaseDelivery.withdraw_except(group.id, [], now, ctx.delivery.sender)
    assert_receive {:pushed, _, _, revocation, payload}
    assert revocation.revoked

    later = DateTime.shift(now, minute: 1)
    assert %{pushed: 1} = LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, resumed, _}
    refute resumed.revoked
    assert resumed.window_start_unix_nano == DateTime.to_unix(later, :nanosecond)

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(payload),
               installed: true
             })

    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)
    assert is_nil(row.revoked_at)
    assert DateTime.compare(row.ack_pending_since, later) == :eq
  end

  test "an agent that cannot be reached is sent the whole window once it can", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    unreachable = %{
      ctx.delivery
      | sender: fn _agent, _group, _payload -> {:error, :no_session} end
    }

    assert %{pushed: 0, errors: 0} = LeasePass.reconcile_group(group, now, unreachable)
    assert {:ok, []} = LeaseDelivery.list_for_group(group.id)

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, lease, _}
    assert lease.window_start_unix_nano == DateTime.to_unix(now, :nanosecond)
  end

  test "without a delivery context the pass plans leases and sends nothing", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)

    assert %{leases: 1, pushed: 0} = LeasePass.reconcile_group(group, DateTime.utc_now())
    refute_receive {:pushed, _, _, _, _}, 50
    assert {:ok, []} = LeaseDelivery.list_for_group(group.id)
  end

  # The group row is created disabled, so it schedules no Oban worker and the test can run
  # async; the pass is handed the enabled struct, which is what it evaluates.
  defp leased_group!(ctx, overrides \\ []) do
    unique = System.unique_integer([:positive, :monotonic])

    assert {:ok, group} =
             SweepGroup
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Lease pass #{ctx.suffix}-#{unique}",
                 partition: ctx.partition.slug,
                 interval: "15m",
                 enabled: false,
                 agent_ids: Keyword.get(overrides, :agent_ids, [ctx.agent]),
                 static_targets: ["192.0.2.0/28", "198.51.100.7"],
                 sweep_modes: ["icmp"]
               },
               actor: ctx.admin
             )
             |> Ash.create()

    %{group | enabled: true}
  end

  defp lease_on!(ctx, horizon) do
    setting!(ctx.admin, :partition, ctx.partition.id,
      leasing_enabled: true,
      horizon_seconds: horizon
    )
  end

  defp setting!(admin, scope, scope_key, attrs) do
    assert {:ok, _row} =
             SweepLeaseSetting
             |> Ash.Changeset.for_create(
               :upsert,
               Map.merge(%{scope: scope, scope_key: scope_key}, Map.new(attrs)),
               actor: admin
             )
             |> Ash.create()
  end

  defp partition!(admin, slug) do
    assert {:ok, partition} =
             Partition
             |> Ash.Changeset.for_create(:create, %{name: slug, slug: slug}, actor: admin)
             |> Ash.create()

    partition
  end

  defp agent_with_device!(admin, uid, partition, ip) do
    device_uid = "device-#{uid}"

    assert {:ok, _device} =
             Device
             |> Ash.Changeset.for_create(
               :create,
               %{uid: device_uid, ip: ip, partition: partition, hostname: uid},
               actor: admin
             )
             |> Ash.create()

    assert {:ok, _agent} =
             Agent
             |> Ash.Changeset.for_create(:register, %{uid: uid, device_uid: device_uid},
               actor: admin
             )
             |> Ash.create()

    uid
  end

  # A one-second horizon contains a fire only in the last second before a 15-minute
  # boundary. Step back from that second so the horizon holds no slot.
  defp clear_now, do: clear_at(DateTime.utc_now())

  defp clear_at(%DateTime{} = time) do
    if rem(DateTime.to_unix(time), 900) >= 899 do
      DateTime.shift(time, second: -2)
    else
      time
    end
  end

  defp digest(payload), do: Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

  defp starts(slots), do: MapSet.new(slots, & &1.slot_start_unix_nano)

  defp assignment!(group, agent_id) do
    assert {:ok, %{} = assignment} = ProducerAssignments.get(group.id, agent_id)
    assignment
  end

  defp unrun!(assignment, now) do
    assert {:ok, slots} = ExecutionSlots.list_unrun(assignment.id, now)
    slots
  end
end
