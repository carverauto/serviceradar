defmodule ServiceRadar.SweepJobs.LeasePassDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1

  # Go sweepCheckSetDigest (domain serviceradar.edge.check_set.v1) for TCP SYN on
  # ports 22 and 443. Not computed by SweepCompiler.
  @tcp_22_443_check_set "ef27b5a15eb570030ffae530ef5e67d3af0e3b988f5f7c10f9f2bad9b2379ca1"
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Partition
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeasePass
  alias ServiceRadar.SweepJobs.LeasePassWorker
  alias ServiceRadar.SweepJobs.LeaseSchedule
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepLeaseSetting

  @moduletag :integration

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    admin = %{id: Ash.UUID.generate(), email: "admin-#{suffix}@example.test", role: :admin}
    partition = partition!(admin, "lease-#{suffix}")
    agent = agent_with_device!(admin, "agent-#{suffix}", partition.slug, "192.0.2.10")

    {:ok, admin: admin, suffix: suffix, partition: partition, agent: agent}
  end

  test "with leasing off the pass leases nothing to the group's agent", ctx do
    group = leased_group!(ctx)

    assert %{leases: 0, scheduled: 0, errors: 0} =
             LeasePass.reconcile_group(group, DateTime.utc_now())

    assert {:ok, _summary} = LeasePass.run()
    assert :ok = LeasePassWorker.perform(%Oban.Job{args: %{}})
    assert {:ok, nil} = ProducerAssignments.get(group.id, ctx.agent)
  end

  test "an agent with leasing on gets the slots of its horizon, and a second pass changes nothing",
       ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    assert %{leases: 1, scheduled: scheduled, dropped: 0, errors: 0} =
             LeasePass.reconcile_group(group, now)

    expected = expected_starts({:interval, 900}, now, 3_600)
    assignment = assignment!(group, ctx.agent)
    slots = unrun!(assignment, now)

    assert scheduled == length(expected)
    assert starts(slots) == expected
    assert Enum.all?(slots, &(&1.authority_epoch == assignment.authority_epoch))
    assert Enum.all?(slots, &(&1.lease_id == LeasePass.lease_id(assignment)))
    assert Enum.all?(slots, &(&1.network_scope_id == ctx.partition.id))

    assert %{scheduled: 0, dropped: 0, errors: 0} = LeasePass.reconcile_group(group, now)
    assert ids(unrun!(assignment, now)) == ids(slots)
  end

  test "a fence bump re-plans every unrun slot under the new epoch and a new lease", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now)
    before = assignment!(group, ctx.agent)
    old = unrun!(before, now)

    assert {:ok, 1} = ProducerAssignments.bump_group(group.id)
    count = length(old)
    assert %{dropped: ^count, scheduled: ^count} = LeasePass.reconcile_group(group, now)

    bumped = assignment!(group, ctx.agent)
    new = unrun!(bumped, now)

    assert bumped.authority_epoch == before.authority_epoch + 1
    assert starts(new) == starts(old)
    assert MapSet.disjoint?(MapSet.new(ids(new)), MapSet.new(ids(old)))
    assert Enum.all?(new, &(&1.authority_epoch == bumped.authority_epoch))
    assert Enum.all?(new, &(&1.lease_id == LeasePass.lease_id(bumped)))
    refute LeasePass.lease_id(bumped) == LeasePass.lease_id(before)
  end

  test "turning leasing off for the agent revokes its lease, and turning it on is a new lease",
       ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now)
    first = assignment!(group, ctx.agent)

    setting!(ctx.admin, :agent, ctx.agent, leasing_enabled: false)
    assert %{revoked: 1, leases: 0} = LeasePass.reconcile_group(group, now)
    assert %{state: :revoked} = assignment!(group, ctx.agent)
    assert [] == unrun!(first, now)

    setting!(ctx.admin, :agent, ctx.agent, leasing_enabled: true)
    assert %{leases: 1} = LeasePass.reconcile_group(group, now)
    again = assignment!(group, ctx.agent)

    assert again.state == :active
    assert again.authority_epoch > first.authority_epoch
    assert starts(unrun!(again, now)) == expected_starts({:interval, 900}, now, 3_600)
  end

  test "a group that stops being eligible holds no lease", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now)
    assignment = assignment!(group, ctx.agent)

    assert %{revoked: 1} =
             LeasePass.reconcile_group(%{group | target_query: "in:devices"}, now)

    assert %{state: :revoked} = assignment!(group, ctx.agent)
    assert [] == unrun!(assignment, now)
  end

  # The agent refuses a slot whose plan check set differs from the check set of the sweep
  # config it was delivered for the group, so the two must come from the same checks.
  test "an agent that cannot run ICMP is planned the check set of the config it is delivered",
       ctx do
    lease_on!(ctx, 3_600)

    agent =
      agent_with_device!(
        ctx.admin,
        "agent-noicmp-#{ctx.suffix}",
        ctx.partition.slug,
        "192.0.2.11",
        ["sweep", "icmp.unavailable"]
      )

    group =
      leased_group!(ctx, agent_ids: [agent], sweep_modes: ["icmp", "tcp"], ports: [22, 443])

    enable_group!(group)
    now = DateTime.utc_now()

    assert %{leases: 1, errors: 0} = LeasePass.reconcile_group(group, now)
    slots = unrun!(assignment!(group, agent), now)

    assert {:ok, %{"groups" => compiled}} =
             SweepCompiler.compile(ctx.partition.slug, agent)

    delivered = Enum.find(compiled, &(&1["id"] == group.id))
    assert delivered["modes"] == ["tcp"]
    assert delivered["ports"] == [22, 443]
    assert slots != []

    for slot <- slots do
      digest =
        slot.plan_header
        |> ScheduledPlanHeaderV1.decode()
        |> Map.fetch!(:check_set_sha256)
        |> Base.encode16(case: :lower)

      assert digest == @tcp_22_443_check_set
    end
  end

  test "changed targets re-plan every unrun slot onto the new ranges without an epoch bump",
       ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now)
    assignment = assignment!(group, ctx.agent)
    before = unrun!(assignment, now)
    epoch = assignment.authority_epoch

    assert range_cidrs(before) == [["192.0.2.0/28", "198.51.100.7/32"]]

    changed = %{group | static_targets: ["203.0.113.129", "203.0.113.0/25"]}
    count = length(before)

    assert %{dropped: ^count, scheduled: ^count, errors: 0} =
             LeasePass.reconcile_group(changed, now)

    kept = assignment!(group, ctx.agent)
    slots = unrun!(kept, now)

    assert kept.authority_epoch == epoch
    assert length(slots) == count
    assert MapSet.disjoint?(MapSet.new(ids(slots)), MapSet.new(ids(before)))
    assert range_cidrs(slots) == [["203.0.113.0/25", "203.0.113.129/32"]]
    assert Enum.all?(slots, &(&1.lease_id == LeasePass.lease_id(kept)))

    equivalent = %{changed | static_targets: ["203.0.113.129/32", "203.0.113.1/25"]}
    assert %{dropped: 0, scheduled: 0, errors: 0} = LeasePass.reconcile_group(equivalent, now)
    assert ids(unrun!(kept, now)) == ids(slots)
  end

  test "contained static targets merge before planning and unmergeable ranges are refused on save",
       ctx do
    lease_on!(ctx, 3_600)

    group =
      leased_group!(ctx,
        static_targets: ["198.51.100.5/32", "198.51.100.0/24"]
      )

    assert group.static_targets == ["198.51.100.0/24"]

    now = DateTime.utc_now()

    assert %{scheduled: scheduled, errors: 0} =
             LeasePass.reconcile_group(
               %{group | static_targets: ["198.51.100.0/24", "198.51.100.5/32"]},
               now
             )

    assert scheduled > 0
    assignment = assignment!(group, ctx.agent)
    slots = unrun!(assignment, now)
    assert length(slots) == scheduled
    assert range_cidrs(slots) == [["198.51.100.0/24"]]

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             group
             |> Ash.Changeset.for_update(
               :update,
               %{static_targets: ["198.51.100.10-198.51.100.50", "198.51.100.30-198.51.100.80"]},
               actor: ctx.admin
             )
             |> Ash.update()

    assert Enum.any?(errors, fn error ->
             Map.get(error, :field) == :static_targets and
               Exception.message(error) =~ "cannot be merged"
           end)
  end

  test "a missing profile is no profile, and an unreadable profile leaves the lease untouched",
       ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    assert %{leases: 1, errors: 0} =
             LeasePass.reconcile_group(%{group | profile_id: Ash.UUID.generate()}, now)

    assignment = assignment!(group, ctx.agent)
    before = unrun!(assignment, now)
    assert before != []

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{groups: 1, errors: 1, leases: 0, revoked: 0, scheduled: 0, dropped: 0} =
                 LeasePass.reconcile_group(%{group | profile_id: %{}}, now)
      end)

    assert log =~ "Sweep lease pass: profile of group #{group.id}"
    refute log =~ "Sweep lease pass failed for group #{group.id}"

    epoch = assignment.authority_epoch
    assert %{state: :active, authority_epoch: ^epoch} = assignment!(group, ctx.agent)

    assert ids(unrun!(assignment, now)) == ids(before)
  end

  test "a shorter horizon or a new interval drops the slots that no longer fit", ctx do
    lease_on!(ctx, 7_200)
    group = leased_group!(ctx)
    now = DateTime.utc_now()

    LeasePass.reconcile_group(group, now)
    assignment = assignment!(group, ctx.agent)

    lease_on!(ctx, 3_600)
    LeasePass.reconcile_group(group, now)
    assert starts(unrun!(assignment, now)) == expected_starts({:interval, 900}, now, 3_600)

    LeasePass.reconcile_group(%{group | interval: "30m"}, now)
    assert starts(unrun!(assignment, now)) == expected_starts({:interval, 1_800}, now, 3_600)
  end

  test "a cron that fires more often than every five minutes is not leased", ctx do
    lease_on!(ctx, 3_600)
    group = leased_group!(ctx)

    assert %{leases: 0} =
             LeasePass.reconcile_group(
               %{group | schedule_type: :cron, cron_expression: "* * * * *"},
               DateTime.utc_now()
             )

    assert {:ok, nil} = ProducerAssignments.get(group.id, ctx.agent)
  end

  test "a partition-wide group leases only the agents whose device is in its partition", ctx do
    lease_on!(ctx, 3_600)
    elsewhere = partition!(ctx.admin, "lease-other-#{ctx.suffix}")

    outsider =
      agent_with_device!(ctx.admin, "outsider-#{ctx.suffix}", elsewhere.slug, "192.0.2.20")

    group = leased_group!(ctx, agent_ids: [])

    assert %{leases: 1} = LeasePass.reconcile_group(group, DateTime.utc_now())
    assert %{state: :active} = assignment!(group, ctx.agent)
    assert {:ok, nil} = ProducerAssignments.get(group.id, outsider)
  end

  test "a failed refill leaves the closed slot unmarked until the next pass has the later slot",
       ctx do
    import ExUnit.CaptureLog

    interval = 900
    horizon = 800
    lease_on!(ctx, horizon)
    group = leased_group!(ctx, static_targets: ["192.0.2.0/24"])
    enable_group!(group)

    assert {:ok, assignment} =
             ProducerAssignments.ensure(group.id, ctx.agent, ctx.partition.id)

    wall = DateTime.truncate(DateTime.utc_now(), :second)
    boundary = div(DateTime.to_unix(wall), interval) * interval
    desired_start = DateTime.from_unix!(boundary - interval)
    pass_now = DateTime.shift(desired_start, second: -30)

    [desired] =
      {:interval, interval}
      |> LeaseSchedule.slots(pass_now, DateTime.shift(pass_now, second: horizon))
      |> Enum.filter(&DateTime.after?(&1.start, pass_now))

    # The blocker has already started on the wall clock, so this pass cannot drop it.
    assert DateTime.before?(desired.start, wall)
    assert desired.start == desired_start

    closed_expires = DateTime.shift(pass_now, second: -301)

    closed =
      schedule_window!(
        assignment,
        DateTime.shift(closed_expires, second: -interval),
        closed_expires,
        ["192.0.2.0/24"]
      )

    blocker =
      schedule_window!(
        assignment,
        desired.start,
        desired.expires,
        ["198.51.100.0/24"]
      )

    log =
      capture_log(fn ->
        assert {:ok, _summary} = LeasePass.run(pass_now, nil)
        assert slot_state(group, closed.id) == :scheduled
      end)

    assert log =~ "planning failed for groups #{group.id}"

    blocker
    |> Ash.Changeset.for_update(:drop, %{}, actor: SystemActor.system(:sweep_execution_slots))
    |> Ash.update!()

    assert {:ok, _} = LeasePass.run(pass_now, nil)
    assert slot_state(group, closed.id) == :missed_offline

    assert {:ok, slots} = ExecutionSlots.list_for_group(group.id)

    assert Enum.any?(
             slots,
             &(&1.state == :scheduled and DateTime.after?(&1.slot_start, closed.slot_start))
           )
  end

  test "an agent without a device is not leased", ctx do
    lease_on!(ctx, 3_600)
    deviceless = "deviceless-#{ctx.suffix}"

    assert {:ok, _agent} =
             Agent
             |> Ash.Changeset.for_create(:register, %{uid: deviceless}, actor: ctx.admin)
             |> Ash.create()

    group = leased_group!(ctx, agent_ids: [deviceless])

    assert %{leases: 0} = LeasePass.reconcile_group(group, DateTime.utc_now())
    assert {:ok, nil} = ProducerAssignments.get(group.id, deviceless)
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
                 static_targets:
                   Keyword.get(overrides, :static_targets, ["192.0.2.0/28", "198.51.100.7"]),
                 sweep_modes: Keyword.get(overrides, :sweep_modes, ["icmp"]),
                 ports: Keyword.get(overrides, :ports, [])
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

  defp agent_with_device!(admin, uid, partition, ip, capabilities \\ []) do
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
               %{uid: uid, device_uid: device_uid, capabilities: capabilities},
               actor: admin
             )
             |> Ash.create()

    uid
  end

  defp enable_group!(group) do
    Repo.query!("UPDATE platform.sweep_groups SET enabled = true WHERE id = $1::uuid", [
      Ecto.UUID.dump!(group.id)
    ])
  end

  defp schedule_window!(assignment, slot_start, expires, targets) do
    assert {:ok, slot} =
             ExecutionSlots.schedule(assignment, slot_start, expires,
               targets: targets,
               check_set_sha256: :crypto.hash(:sha256, "checks"),
               lease_id: Ash.UUID.generate()
             )

    slot
  end

  defp slot_state(group, slot_id) do
    assert {:ok, slots} = ExecutionSlots.list_for_group(group.id)
    Enum.find(slots, &(&1.id == slot_id)).state
  end

  defp assignment!(group, agent_id) do
    assert {:ok, %{} = assignment} = ProducerAssignments.get(group.id, agent_id)
    assignment
  end

  defp unrun!(assignment, now) do
    assert {:ok, slots} = ExecutionSlots.list_unrun(assignment.id, now)
    slots
  end

  defp expected_starts(spec, now, horizon) do
    spec
    |> LeaseSchedule.slots(now, DateTime.shift(now, second: horizon))
    |> Enum.filter(&DateTime.after?(&1.start, now))
    |> Enum.map(&DateTime.to_unix(&1.start))
  end

  defp starts(slots), do: Enum.map(slots, &DateTime.to_unix(&1.slot_start))
  defp ids(slots), do: Enum.map(slots, & &1.id)

  defp range_cidrs(slots) do
    slots
    |> Enum.map(fn slot ->
      Enum.flat_map(slot.plan_pages, fn page ->
        page |> ScheduledPlanPageV1.decode() |> Map.fetch!(:ranges) |> Enum.map(& &1.cidr)
      end)
    end)
    |> Enum.uniq()
  end
end
