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

    assert %{pushed: 0} = LeasePass.reconcile_group(group, now, ctx.delivery)
    refute_receive {:pushed, _, _, _, _}, 50
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

    later = DateTime.add(now, 1_800, :second)
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

    retry = DateTime.add(now, 60, :second)
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
    late = DateTime.add(retry, LeaseDelivery.ack_grace_seconds() + 60, :second)
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
    through = DateTime.add(DateTime.utc_now(), 3_600, :second)

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

  test "an agent the group stops leasing to gets a revocation and loses its delivery", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, first, _}

    setting!(ctx.admin, :agent, ctx.agent, leasing_enabled: false)
    assert %{withdrawn: 1} = LeasePass.reconcile_group(group, now, ctx.delivery)
    assert_receive {:pushed, _, _, revocation, _}

    assert revocation.revoked
    assert revocation.lease_id == first.lease_id
    assert revocation.slots == []
    assert revocation.production_capability == nil
    assert {:ok, []} = LeaseDelivery.list_for_group(group.id)
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

  defp assignment!(group, agent_id) do
    assert {:ok, %{} = assignment} = ProducerAssignments.get(group.id, agent_id)
    assignment
  end

  defp unrun!(assignment, now) do
    assert {:ok, slots} = ExecutionSlots.list_unrun(assignment.id, now)
    slots
  end
end
