defmodule ServiceRadar.SweepJobs.ExecutionSlotsDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Edge.PlanValidate
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup

  @moduletag :integration

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    actor = %{id: Ash.UUID.generate(), email: "operator-#{suffix}@example.test", role: :operator}
    {:ok, actor: actor, suffix: suffix}
  end

  test "a slot stores the plan its execution binds, under an id that carries the slot time",
       ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    slot_start = DateTime.add(DateTime.utc_now(), 3600, :second)

    slot = schedule!(assignment, slot_start)

    assert slot.state == :scheduled
    assert slot.authority_epoch == assignment.authority_epoch
    assert slot.producer_assignment_id == assignment.id
    assert <<ms::48, 7::4, _::12, _::64>> = Ecto.UUID.dump!(slot.id)
    assert ms == DateTime.to_unix(slot_start, :millisecond)

    # The stored bytes decode to a plan the validator accepts, and it is the plan the slot names.
    header = ScheduledPlanHeaderV1.decode(slot.plan_header)
    pages = Enum.map(slot.plan_pages, &ScheduledPlanPageV1.decode/1)

    assert {:ok, _windows} = PlanValidate.validate(header, pages)
    assert header.execution_plan_sha256 == slot.plan_sha256
    assert Ecto.UUID.cast!(header.execution_plan_id) == slot.plan_id
    assert Ecto.UUID.cast!(header.network_scope_id) == assignment.network_scope_id
    assert Enum.map(hd(pages).ranges, & &1.cidr) == ["192.0.2.0/24", "198.51.100.5/32"]
  end

  test "an assignment has one scheduled slot per start time", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    slot_start = DateTime.add(DateTime.utc_now(), 3600, :second)

    schedule!(assignment, slot_start)

    assert {:error, _} = do_schedule(assignment, slot_start)
    assert {:ok, [_only]} = ExecutionSlots.list_for_group(group.id)
  end

  test "a target the plan cannot carry makes no slot", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")

    assert {:error, {:target_too_wide, _}} =
             ExecutionSlots.schedule(
               assignment,
               DateTime.add(DateTime.utc_now(), 60, :second),
               DateTime.add(DateTime.utc_now(), 360, :second),
               targets: ["2001:db8::/48"],
               check_set_sha256: :crypto.hash(:sha256, "checks"),
               lease_id: Ash.UUID.generate()
             )

    assert {:ok, []} = ExecutionSlots.list_for_group(group.id)
  end

  test "revoking an agent withdraws its unrun slots and leaves what has started", ctx do
    group = create_group!(ctx)
    a = assign!(group, "agent-a")
    b = assign!(group, "agent-b")
    now = DateTime.utc_now()

    past = schedule!(a, DateTime.add(now, -3600, :second))
    future_a = schedule!(a, DateTime.add(now, 3600, :second))
    future_b = schedule!(b, DateTime.add(now, 3600, :second))

    assert {:ok, 1} = ProducerAssignments.revoke_agents(group.id, ["agent-a"])

    assert state(group, past.id) == :scheduled
    assert state(group, future_a.id) == :dropped
    assert state(group, future_b.id) == :scheduled
  end

  test "keeping only some agents withdraws the unrun slots of the rest", ctx do
    group = create_group!(ctx)
    keep = assign!(group, "agent-keep")
    drop = assign!(group, "agent-drop")
    at = DateTime.add(DateTime.utc_now(), 3600, :second)

    kept = schedule!(keep, at)
    dropped = schedule!(drop, at)

    assert {:ok, 1} = ProducerAssignments.revoke_all_except(group.id, ["agent-keep"])

    assert state(group, kept.id) == :scheduled
    assert state(group, dropped.id) == :dropped
  end

  test "a reissued assignment schedules the same start after its slot was dropped", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    slot_start = DateTime.add(DateTime.utc_now(), 3600, :second)
    dropped = schedule!(assignment, slot_start)

    assert {:ok, 1} = ProducerAssignments.revoke_agents(group.id, ["agent-a"])
    assert state(group, dropped.id) == :dropped

    assert {:ok, reissued} =
             ProducerAssignments.ensure(group.id, "agent-a", assignment.network_scope_id)

    assert reissued.id == assignment.id
    scheduled = schedule!(reissued, slot_start)

    assert scheduled.id != dropped.id
    assert scheduled.state == :scheduled
    assert scheduled.producer_assignment_id == assignment.id
    assert DateTime.compare(scheduled.slot_start, dropped.slot_start) == :eq

    assert {:ok, slots} = ExecutionSlots.list_for_group(group.id)
    assert Enum.sort(Enum.map(slots, & &1.state)) == [:dropped, :scheduled]
  end

  defp create_group!(%{actor: actor, suffix: suffix}) do
    unique = System.unique_integer([:positive, :monotonic])

    # Disabled, so creating it schedules no Oban worker and the test can run async.
    assert {:ok, group} =
             SweepGroup
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Execution slots #{suffix}-#{unique}",
                 partition: "default",
                 interval: "15m",
                 enabled: false,
                 agent_ids: [],
                 static_targets: ["192.0.2.0/24"]
               },
               actor: actor
             )
             |> Ash.create()

    group
  end

  defp assign!(group, agent_id) do
    assert {:ok, assignment} = ProducerAssignments.ensure(group.id, agent_id, Ash.UUID.generate())
    assignment
  end

  defp do_schedule(assignment, slot_start) do
    ExecutionSlots.schedule(assignment, slot_start, DateTime.add(slot_start, 300, :second),
      targets: ["198.51.100.5", "192.0.2.9/24"],
      check_set_sha256: :crypto.hash(:sha256, "checks"),
      lease_id: Ash.UUID.generate()
    )
  end

  defp schedule!(assignment, slot_start) do
    assert {:ok, slot} = do_schedule(assignment, slot_start)
    slot
  end

  defp state(group, slot_id) do
    assert {:ok, slots} = ExecutionSlots.list_for_group(group.id)
    Enum.find(slots, &(&1.id == slot_id)).state
  end
end
