defmodule ServiceRadar.SweepJobs.LeaseDeliveryDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.CapabilitySigning
  alias ServiceRadar.Edge.IssuerKey
  alias ServiceRadar.Edge.PipelineSetting
  alias ServiceRadar.Edge.RecoveryAssignmentEvidence
  alias ServiceRadar.Edge.RecoveryAssignments
  alias Serviceradar.Edge.V1.EdgeAttributedActiveV1
  alias Serviceradar.Edge.V1.EdgeAttributedSpanIdentityV1
  alias Serviceradar.Edge.V1.EdgeClassificationSpanV1
  alias Serviceradar.Edge.V1.EdgeSourceSpanIdentityV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias Serviceradar.Edge.V1.SweepLeaseV1
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseDelivery
  alias ServiceRadar.SweepJobs.LeaseEligibility
  alias ServiceRadar.SweepJobs.LeasePass
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup

  @moduletag :integration

  # Go sweepCheckSetDigest (domain serviceradar.edge.check_set.v1) for ICMP alone.
  # Not computed by SweepPlan.
  @icmp_check_set "5f6c98de96c9219b10bd509a42e23615a44ad939481c1dc4178f2650dfacfd13"

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
    horizon!(ctx, 3_600)
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

    # A push with slots carries the one check set their plan headers name.
    assert lease.lease_version == 2

    assert [
             %{
               digest_version: 1,
               checks: [%{mode: :SWEEP_MODE_ICMP, protocol: :TRANSPORT_PROTOCOL_ICMP, port: 0}]
             } = carried
           ] = lease.check_sets

    assert Base.encode16(carried.check_set_sha256, case: :lower) == @icmp_check_set
    assert Enum.all?(lease.slots, &(&1.plan_header.check_set_sha256 == carried.check_set_sha256))

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

  test "a new control session gets the full window even when core holds a matching ack", ctx do
    horizon!(ctx, 3_600)
    group = leased_group!(ctx)

    ServiceRadar.Repo.query!(
      "UPDATE platform.sweep_groups SET enabled = true WHERE id = $1::uuid",
      [
        Ecto.UUID.dump!(group.id)
      ]
    )

    now = DateTime.utc_now()
    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, _}
    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: row.delivered_payload_sha256,
               installed: true
             })

    assert %{pushed: 0} = LeasePass.reconcile_group(group, now, ctx.delivery)
    refute_receive {:pushed, _, _, _, _}, 50

    test_pid = self()

    session = fn agent_id, group_id, payload ->
      lease = SweepLeaseV1.decode(payload)

      mapped? =
        Enum.all?(lease.slots, fn slot ->
          {:ok, entries} =
            RecoveryAssignmentEvidence.sweep(lease.production_capability, slot, @key.public_key)

          Enum.all?(entries, fn entry ->
            %{rows: [[count]]} =
              ServiceRadar.Repo.query!(
                "SELECT count(*) FROM platform.edge_recovery_assignment_issuances WHERE mapping_key = $1::jsonb AND mapping_value = $2::jsonb",
                [entry.key, entry.value]
              )

            count == 1
          end)
        end)

      send(test_pid, {:session_push, agent_id, group_id, lease, mapped?})
      :ok
    end

    later = DateTime.shift(now, second: 1)

    assert {:error, :lease_authority_unavailable} = LeasePass.refresh_agent(ctx.agent, nil, later)

    closed = fn _agent_id, _group_id, _payload -> {:error, :control_session_unavailable} end

    assert {:error, {:lease_refresh_incomplete, 1}} =
             LeasePass.refresh_agent(ctx.agent, %{ctx.delivery | sender: closed}, later)

    assert {:ok, %{pushed: 1, errors: 0}} =
             LeasePass.refresh_agent(ctx.agent, %{ctx.delivery | sender: session}, later)

    assert_receive {:session_push, agent_id, group_id, lease, true}
    assert {agent_id, group_id} == {ctx.agent, group.id}
    refute_receive {:pushed, _, _, _, _}, 50

    assert lease.window_start_unix_nano == DateTime.to_unix(later, :nanosecond)
    assert lease.lease_id == first.lease_id
    assert lease.slots != []

    assert MapSet.new(lease.slots, & &1.execution_id) ==
             MapSet.new(unrun!(assignment!(group, ctx.agent), later), &Ecto.UUID.dump!(&1.id))
  end

  test "a refresh leaves the group's other agents, their slots and their deliveries alone", ctx do
    horizon!(ctx, 3_600)
    peer = agent_with_device!(ctx.admin, "peer-#{ctx.suffix}", ctx.partition.slug, "192.0.2.11")
    group = leased_group!(ctx, agent_ids: [ctx.agent, peer])
    enable!(group)
    now = DateTime.utc_now()

    assert %{pushed: 2} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, _, _}
    assert_receive {:pushed, _, _, _, _}
    peer_assignment = assignment!(group, peer)
    peer_slots = unrun!(peer_assignment, now)
    assert peer_slots != []

    ServiceRadar.Repo.query!(
      "UPDATE platform.sweep_groups SET agent_ids = $1 WHERE id = $2::uuid",
      [[ctx.agent], Ecto.UUID.dump!(group.id)]
    )

    assert {:ok, %{pushed: 1, revoked: 0, withdrawn: 0, errors: 0}} =
             LeasePass.refresh_agent(ctx.agent, ctx.delivery, now)

    assert_receive {:pushed, agent_id, _, _, _}
    assert agent_id == ctx.agent
    refute_receive {:pushed, _, _, _, _}, 50

    assert assignment!(group, peer).state == :active
    assert assignment!(group, peer).authority_epoch == peer_assignment.authority_epoch
    assert MapSet.new(unrun!(peer_assignment, now), & &1.id) == MapSet.new(peer_slots, & &1.id)
    assert {:ok, rows} = LeaseDelivery.list_for_group(group.id)
    assert Enum.any?(rows, &(&1.agent_id == peer and is_nil(&1.revoked_at)))
  end

  test "a pass started from a group read before an update removed the agent leaves it revoked",
       ctx do
    horizon!(ctx, 3_600)
    peer = agent_with_device!(ctx.admin, "peer-#{ctx.suffix}", ctx.partition.slug, "192.0.2.13")
    stale = leased_group!(ctx)
    now = DateTime.utc_now()

    assert %{pushed: 1} = LeasePass.reconcile_group(stale, now, ctx.delivery)
    assert_receive {:pushed, _, _, _, _}
    assignment = assignment!(stale, ctx.agent)

    assert {:ok, _updated} =
             stale
             |> Ash.Changeset.for_update(:update, %{agent_ids: [peer]}, actor: ctx.admin)
             |> Ash.update()

    revoked = assignment!(stale, ctx.agent)
    assert revoked.state == :revoked
    issuances = issuance_count(assignment)

    assert %{errors: 0} = LeasePass.reconcile_group(stale, now, ctx.delivery)

    current = assignment!(stale, ctx.agent)
    assert current.state == :revoked
    assert current.authority_epoch == revoked.authority_epoch
    assert unrun!(current, now) == []
    assert issuance_count(assignment) == issuances
    agent = ctx.agent
    refute_receive {:pushed, ^agent, _, %{revoked: false}, _}, 50
  end

  test "a refresh queued behind a send does not revive an agent revoked while it waited",
       ctx do
    assert_queued_run_keeps_revocation(ctx, fn _group, delivery ->
      assert {:ok, %{pushed: 0, errors: 0}} = LeasePass.refresh_agent(ctx.agent, delivery)
    end)
  end

  test "a pass queued behind a send does not revive an agent revoked after it read the group",
       ctx do
    assert_queued_run_keeps_revocation(ctx, fn group, delivery ->
      assert %{pushed: 0, errors: 0} =
               LeasePass.reconcile_group(group, DateTime.utc_now(), delivery)
    end)
  end

  test "two refreshes of one agent never send its lease at the same time", ctx do
    assert_serialized_sends(ctx, fn _group, delivery, now ->
      [
        fn -> LeasePass.refresh_agent(ctx.agent, delivery, now) end,
        fn -> LeasePass.refresh_agent(ctx.agent, delivery, DateTime.shift(now, second: 1)) end
      ]
    end)
  end

  test "a refresh and a lease pass never send one agent's lease at the same time", ctx do
    assert_serialized_sends(ctx, fn group, delivery, now ->
      [
        fn -> LeasePass.refresh_agent(ctx.agent, delivery, now) end,
        fn -> LeasePass.reconcile_group(group, now, delivery) end
      ]
    end)
  end

  test "shrinking the horizon and growing it back delivers the re-minted slots as a tail",
       ctx do
    horizon!(ctx, 7_200)
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

    setting!(ctx.admin, :partition, ctx.partition.id, horizon_seconds: 1_800)

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

    setting!(ctx.admin, :partition, ctx.partition.id, horizon_seconds: 7_200)

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

  test "lease sender sees original mapping evidence, and a damaged original blocks redelivery",
       ctx do
    horizon!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()
    test_pid = self()

    sender = fn _agent, _group, payload ->
      lease = SweepLeaseV1.decode(payload)

      for slot <- lease.slots do
        {:ok, entries} =
          RecoveryAssignmentEvidence.sweep(lease.production_capability, slot, @key.public_key)

        for entry <- entries do
          assert %{rows: [[1]]} =
                   ServiceRadar.Repo.query!(
                     "SELECT count(*) FROM platform.edge_recovery_assignment_candidates c JOIN platform.edge_recovery_assignment_issuances i ON i.id = c.issuance_id WHERE i.mapping_key = $1::jsonb AND i.mapping_value = $2::jsonb",
                     [entry.key, entry.value]
                   )
        end
      end

      send(test_pid, {:mapped_lease, lease})
      :ok
    end

    delivery = %{ctx.delivery | sender: sender}
    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, delivery)
    assert_receive {:mapped_lease, lease}

    {:ok, [entry | _]} =
      RecoveryAssignmentEvidence.sweep(
        lease.production_capability,
        hd(lease.slots),
        @key.public_key
      )

    assert %{num_rows: 1} =
             ServiceRadar.Repo.query!(
               "UPDATE platform.edge_recovery_assignment_issuances SET evidence = '{}' WHERE mapping_key = $1::jsonb",
               [entry.key]
             )

    assert %{pushed: 0} = LeasePass.reconcile_group(group, now, delivery)
    refute_receive {:mapped_lease, _}
  end

  test "a refused shrink is retried out to the window the agent already holds", ctx do
    horizon!(ctx, 7_200)
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

    setting!(ctx.admin, :partition, ctx.partition.id, horizon_seconds: 1_800)

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
    horizon!(ctx, 7_200)
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

    setting!(ctx.admin, :partition, ctx.partition.id, horizon_seconds: 1_800)

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
             LeaseDelivery.deliver(
               assignment,
               ctx.delivery.authority,
               later,
               ctx.delivery.sender,
               checks!(group)
             )

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
    horizon!(ctx, 7_200)
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

    setting!(ctx.admin, :partition, ctx.partition.id, horizon_seconds: 1)

    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, cleared, _}
    assert cleared.lease_id == first.lease_id
    refute cleared.revoked
    assert cleared.slots == []
    assert {cleared.lease_version, cleared.check_sets} == {1, []}
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
    horizon!(ctx, 7_200)
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

    setting!(ctx.admin, :partition, ctx.partition.id, horizon_seconds: 1)

    assert %{pushed: 1} = LeasePass.reconcile_group(group, later, ctx.delivery)
    assert_receive {:pushed, _, _, cleared, cleared_payload}
    assert cleared.slots == []

    assert :ok =
             LeaseDelivery.record_ack(ctx.agent, %{
               sweep_group_id: group.id,
               payload_sha256: digest(cleared_payload),
               installed: true
             })

    setting!(ctx.admin, :partition, ctx.partition.id, horizon_seconds: 7_200)

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
    horizon!(ctx, 7_200)
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
             LeaseDelivery.deliver(
               assignment,
               ctx.delivery.authority,
               now,
               ctx.delivery.sender,
               checks!(group)
             )

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
             LeaseDelivery.deliver(
               assignment,
               ctx.delivery.authority,
               now,
               ctx.delivery.sender,
               checks!(group)
             )
  end

  test "an unacknowledged full window is resent before the acknowledgement grace", ctx do
    horizon!(ctx, 3_600)
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
    horizon!(ctx, 3_600)
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
    horizon!(ctx, 3_600)
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
    horizon!(ctx, 3_600)
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
    horizon!(ctx, 3_600)
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
    horizon!(ctx, 3_600)
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
    horizon!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, _}
    assert {:ok, [_row]} = LeaseDelivery.list_for_group(group.id)

    [slot | _] = first.slots
    [source | _] = slot.source_authorizations
    {:production, production} = first.production_capability.claims
    span = historical_span(production, source)

    assert {:found, original} =
             RecoveryAssignments.lookup(production.network_scope_id, ctx.agent, span)

    assert original["execution_id"] == Base.encode16(slot.execution_id, case: :lower)

    assert original["plan"]["id"] ==
             Base.encode16(slot.plan_header.execution_plan_id, case: :lower)

    assert original["range"]["sha256"] == Base.encode16(source.scope_sha256, case: :lower)
    assert :ok = Ash.destroy(group, actor: ctx.admin)
    assert {:ok, []} = ProducerAssignments.list_for_group(group.id)

    assert %{rows: [[0]]} =
             ServiceRadar.Repo.query!(
               "SELECT count(*) FROM platform.sweep_execution_slots WHERE id = $1",
               [slot.execution_id]
             )

    assert {:found, ^original} =
             RecoveryAssignments.lookup(production.network_scope_id, ctx.agent, span)

    group_id = group.id
    assert {:ok, %{withdrawn: withdrawn}} = LeasePass.run(now, ctx.delivery)
    assert withdrawn >= 1

    assert_receive {:pushed, _, ^group_id, revocation, payload}
    refute_received {:pushed, _, ^group_id, _, _}
    assert revocation.revoked
    assert revocation.lease_id == first.lease_id
    assert revocation.slots == []
    assert {revocation.lease_version, revocation.check_sets} == {1, []}
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

    assert {:found, ^original} =
             RecoveryAssignments.lookup(production.network_scope_id, ctx.agent, span)
  end

  test "an agent the group stops leasing to gets a revocation and loses its delivery", ctx do
    horizon!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, _}

    # Moved to an agent with no device, which core cannot lease to.
    elsewhere = "agent-elsewhere-#{ctx.suffix}"

    Agent
    |> Ash.Changeset.for_create(:register, %{uid: elsewhere})
    |> Ash.create!(actor: ctx.admin)

    assert {:ok, group} =
             group
             |> Ash.Changeset.for_update(:update, %{agent_ids: [elsewhere]}, actor: ctx.admin)
             |> Ash.update()

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
    horizon!(ctx, 3_600)
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
    horizon!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    unreachable = %{
      ctx.delivery
      | sender: fn _agent, _group, _payload -> {:error, :no_session} end
    }

    assert %{pushed: 0, errors: 0} = LeasePass.reconcile_group(group, now, unreachable)
    assert {:ok, [pending]} = LeaseDelivery.list_for_group(group.id)
    refute pending.ack_installed == true
    refute pending.acked_payload_sha256 == pending.delivered_payload_sha256

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, lease, _}
    assert lease.window_start_unix_nano == DateTime.to_unix(now, :nanosecond)
  end

  test "an installation ack that arrives while the push is being sent is kept", ctx do
    horizon!(ctx, 3_600)
    group = leased_group!(ctx)
    test_pid = self()

    acking = %{
      ctx.delivery
      | sender: fn agent_id, group_id, payload ->
          send(
            test_pid,
            {:ack_result,
             LeaseDelivery.record_ack(agent_id, %{
               sweep_group_id: group_id,
               payload_sha256: digest(payload),
               installed: true
             })}
          )

          :ok
        end
    }

    assert %{pushed: 1, errors: 0} = LeasePass.reconcile_group(group, DateTime.utc_now(), acking)
    assert_receive {:ack_result, :ok}
    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)
    assert row.ack_installed
    assert row.acked_payload_sha256 == row.delivered_payload_sha256
  end

  test "without a delivery context the pass plans leases and sends nothing", ctx do
    horizon!(ctx, 3_600)
    group = leased_group!(ctx)

    assert %{leases: 1, pushed: 0} = LeasePass.reconcile_group(group, DateTime.utc_now())
    refute_receive {:pushed, _, _, _, _}, 50
    assert {:ok, []} = LeaseDelivery.list_for_group(group.id)
  end

  test "a target update through the group action re-plans, re-signs, and re-delivers", ctx do
    horizon!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    assert %{pushed: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, _}
    before = assignment!(group, ctx.agent)
    old = unrun!(before, now)
    count = length(old)
    assert count > 0

    assert {:ok, stored} =
             group
             |> Ash.Changeset.for_update(
               :update,
               %{static_targets: ["203.0.113.129", "203.0.113.0/25"]},
               actor: ctx.admin
             )
             |> Ash.update()

    fenced = assignment!(stored, ctx.agent)
    assert fenced.state == :active
    assert fenced.authority_epoch == before.authority_epoch + 1

    assert %{dropped: ^count, scheduled: ^count, pushed: 1, errors: 0} =
             LeasePass.reconcile_group(stored, now, ctx.delivery)

    assert_receive {:pushed, _, _, resent, _}
    new = unrun!(fenced, now)

    assert MapSet.new(new, &DateTime.to_unix(&1.slot_start)) ==
             MapSet.new(old, &DateTime.to_unix(&1.slot_start))

    assert MapSet.disjoint?(MapSet.new(new, & &1.id), MapSet.new(old, & &1.id))
    assert Enum.all?(new, &(&1.authority_epoch == fenced.authority_epoch))
    assert Enum.all?(new, &(&1.lease_id == LeasePass.lease_id(fenced)))
    refute LeasePass.lease_id(fenced) == LeasePass.lease_id(before)
    assert range_cidrs(new) == [["203.0.113.0/25", "203.0.113.129/32"]]

    assert resent.lease_id == Ecto.UUID.dump!(LeasePass.lease_id(fenced))
    assert resent.authority_epoch == fenced.authority_epoch
    refute resent.lease_id == first.lease_id
    assert CapabilitySigning.verify(resent.production_capability, :production, @key.public_key)
    refute resent.production_capability.signature == first.production_capability.signature

    assert Enum.map(resent.slots, & &1.plan_header.execution_plan_sha256) !=
             Enum.map(first.slots, & &1.plan_header.execution_plan_sha256)

    for slot <- resent.slots do
      assert Enum.all?(
               slot.source_authorizations,
               &CapabilitySigning.verify(&1.capability, :source, @key.public_key)
             )
    end
  end

  test "an agent the group update no longer selects has its unrun slots dropped", ctx do
    horizon!(ctx, 3_600)

    other =
      agent_with_device!(ctx.admin, "other-#{ctx.suffix}", ctx.partition.slug, "198.51.100.10")

    group = leased_group!(ctx, agent_ids: [ctx.agent, other])
    now = DateTime.utc_now()

    assert %{leases: 2, pushed: 2} =
             LeasePass.reconcile_group(group, now, ctx.delivery)

    assert_receive {:pushed, _, _, _, _}
    assert_receive {:pushed, _, _, _, _}

    kept = assignment!(group, ctx.agent)
    removed = assignment!(group, other)
    old_kept = unrun!(kept, now)
    old_removed = unrun!(removed, now)
    assert old_kept != []
    assert old_removed != []
    removed_ids = MapSet.new(old_removed, & &1.id)

    assert {:ok, stored} =
             group
             |> Ash.Changeset.for_update(:update, %{agent_ids: [ctx.agent]}, actor: ctx.admin)
             |> Ash.update()

    assert %{state: :revoked} = assignment!(stored, other)
    assert [] = unrun!(removed, now)

    assert {:ok, rows} = ExecutionSlots.list_for_group(stored.id)

    removed_rows = Enum.filter(rows, &(&1.id in removed_ids))
    assert removed_rows != []
    assert Enum.all?(removed_rows, &(&1.state == :dropped))

    kept_now = assignment!(stored, ctx.agent)
    assert kept_now.state == :active
    assert kept_now.authority_epoch == kept.authority_epoch + 1
    count = length(old_kept)

    assert %{dropped: ^count, scheduled: ^count, pushed: 1, withdrawn: 1, errors: 0} =
             LeasePass.reconcile_group(stored, now, ctx.delivery)

    assert_receive {:pushed, first_agent, _, first_msg, _}
    assert_receive {:pushed, second_agent, _, second_msg, _}
    pushes = %{first_agent => first_msg, second_agent => second_msg}

    assert pushes[other].revoked
    assert pushes[other].slots == []
    assert pushes[other].production_capability == nil

    resent = pushes[ctx.agent]
    refute resent.revoked
    assert resent.authority_epoch == kept_now.authority_epoch
    assert CapabilitySigning.verify(resent.production_capability, :production, @key.public_key)
    assert [] = unrun!(removed, now)
    assert length(unrun!(kept_now, now)) == count
    assert Enum.all?(unrun!(kept_now, now), &(&1.authority_epoch == kept_now.authority_epoch))
  end

  # The group row is created disabled, so it schedules no Oban worker and the test can run
  # async; the pass is handed the enabled struct, which is what it evaluates.
  # Construct the historical lookup from the authority actually delivered before
  # deletion, independently of the current assignment/slot tables.
  defp historical_span(production, source) do
    %EdgeClassificationSpanV1{
      from_sequence: 1,
      through_sequence: 1,
      classification:
        {:attributed_active,
         %EdgeAttributedActiveV1{
           range_sha256: source.scope_sha256,
           identity: %EdgeAttributedSpanIdentityV1{
             producer_assignment_id: production.producer_assignment_id,
             run_id: production.run_id,
             run_shard: production.run_shard,
             authority_epoch: production.authority_epoch,
             production_scope_id: production.scope_id,
             scope_sha256: production.scope_sha256,
             contract_bundle_sha256: production.contract_bundle_sha256,
             source: %EdgeSourceSpanIdentityV1{
               kind: source.kind,
               context_id: source.context_id,
               source_scope_id: source.scope_id,
               source_scope_sha256: source.scope_sha256
             }
           }
         }}
    }
  end

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

    enable!(group)
    %{group | enabled: true}
  end

  defp horizon!(ctx, horizon) do
    setting!(ctx.admin, :partition, ctx.partition.id, horizon_seconds: horizon)
  end

  defp setting!(admin, scope, scope_key, attrs) do
    assert {:ok, _row} =
             PipelineSetting
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
             |> Ash.Changeset.for_create(
               :register,
               %{uid: uid, device_uid: device_uid, capabilities: ["sweep_lease_plan_checks:v1"]},
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

  defp range_cidrs(slots) do
    slots
    |> Enum.map(fn slot ->
      Enum.flat_map(slot.plan_pages, fn page ->
        page |> ScheduledPlanPageV1.decode() |> Map.fetch!(:ranges) |> Enum.map(& &1.cidr)
      end)
    end)
    |> Enum.uniq()
  end

  defp checks!(group) do
    assert {:ok, %{checks: checks}} =
             LeaseEligibility.agent_checks(group, nil, ["sweep_lease_plan_checks:v1"])

    checks
  end

  # Both runs push this agent's lease through a sender that takes 200 ms. Under the delivery
  # lock one send finishes before the next starts, and the delivery row records the payload
  # that was sent last.
  defp assert_serialized_sends(ctx, runs) do
    horizon!(ctx, 3_600)
    group = leased_group!(ctx)
    enable!(group)
    now = DateTime.utc_now()
    assert %{pushed: 0} = LeasePass.reconcile_group(group, now, nil)
    test_pid = self()

    slow = fn _agent_id, _group_id, payload ->
      send(test_pid, {:send, :started, self()})
      Process.sleep(200)
      send(test_pid, {:send, :finished, self(), payload})
      :ok
    end

    group
    |> runs.(%{ctx.delivery | sender: slow}, now)
    |> Enum.map(&Task.async/1)
    |> Task.await_many(10_000)

    assert [
             {:started, first},
             {:finished, first, _},
             {:started, second},
             {:finished, second, last}
           ] =
             Enum.map(1..4, fn _ -> next_send_event() end)

    refute first == second
    assert {:ok, [row]} = LeaseDelivery.list_for_group(group.id)
    assert row.delivered_payload_sha256 == digest(last)
  end

  # A real send holds the agent's delivery lock while `queued` reads the group and then waits
  # on that lock. A group update removes the agent meanwhile, revoking it in the update's own
  # transaction. Once the lock is released, the queued run must leave the revocation, its epoch
  # and its dropped slots as they are, mint no issuance for the agent and send nothing.
  defp assert_queued_run_keeps_revocation(ctx, queued) do
    horizon!(ctx, 3_600)
    peer = agent_with_device!(ctx.admin, "peer-#{ctx.suffix}", ctx.partition.slug, "192.0.2.12")
    group = leased_group!(ctx)
    enable!(group)
    now = DateTime.utc_now()
    assert %{pushed: 0} = LeasePass.reconcile_group(group, now, nil)
    assignment = assignment!(group, ctx.agent)
    test_pid = self()

    holder = fn _agent_id, _group_id, _payload ->
      send(test_pid, {:holding, self()})

      receive do
        :release -> :ok
      end
    end

    holding =
      Task.async(fn ->
        LeasePass.reconcile_group(group, DateTime.utc_now(), %{ctx.delivery | sender: holder})
      end)

    assert_receive {:holding, holder_pid}, 5_000

    try do
      late = fn agent_id, group_id, _payload ->
        send(test_pid, {:late_push, agent_id, group_id})
        :ok
      end

      waiting = Task.async(fn -> queued.(group, %{ctx.delivery | sender: late}) end)
      await_delivery_lock_wait(waiting.pid, System.monotonic_time(:millisecond) + 5_000)

      assert {:ok, _updated} =
               group
               |> Ash.Changeset.for_update(:update, %{agent_ids: [peer]}, actor: ctx.admin)
               |> Ash.update()

      revoked = assignment!(group, ctx.agent)
      assert revoked.state == :revoked
      issuances = issuance_count(assignment)

      send(holder_pid, :release)
      Task.await(holding, 10_000)
      Task.await(waiting, 10_000)

      refute_receive {:late_push, _, _}, 50
      current = assignment!(group, ctx.agent)
      assert current.state == :revoked
      assert current.authority_epoch == revoked.authority_epoch
      assert unrun!(current, now) == []
      assert issuance_count(assignment) == issuances
    after
      send(holder_pid, :release)
    end
  end

  defp await_delivery_lock_wait(pid, deadline) do
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)

    cond do
      Enum.any?(stack, &match?({:global, _, _, _}, &1)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the queued run never waited on the agent's delivery lock")

      true ->
        receive do
        after
          5 -> await_delivery_lock_wait(pid, deadline)
        end
    end
  end

  # Issuance recorded for any slot the fixture assignment has had, across all of its epochs.
  defp issuance_count(assignment) do
    %{rows: [[count]]} =
      ServiceRadar.Repo.query!(
        "SELECT count(*) FROM platform.edge_recovery_assignment_issuances WHERE " <>
          "mapping_value->>'execution_id' IN (SELECT replace(id::text, '-', '') FROM " <>
          "platform.sweep_execution_slots WHERE producer_assignment_id = $1::uuid)",
        [Ecto.UUID.dump!(assignment.id)]
      )

    count
  end

  defp next_send_event do
    receive do
      {:send, :started, pid} -> {:started, pid}
      {:send, :finished, pid, payload} -> {:finished, pid, payload}
    after
      5_000 -> flunk("a lease send did not happen")
    end
  end

  defp enable!(group) do
    ServiceRadar.Repo.query!(
      "UPDATE platform.sweep_groups SET enabled = true WHERE id = $1::uuid",
      [Ecto.UUID.dump!(group.id)]
    )
  end

  defp assignment!(group, agent_id) do
    assert {:ok, %{} = assignment} = ProducerAssignments.get(group.id, agent_id)
    assignment
  end

  defp unrun!(assignment, now) do
    assert {:ok, slots} = ExecutionSlots.list_unrun(assignment.id, now)
    slots
  end
end
