defmodule ServiceRadar.SweepJobs.ExecutionSlotsDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.PlanValidate
  alias Serviceradar.Edge.V1.ScheduledPlanHeaderV1
  alias Serviceradar.Edge.V1.ScheduledPlanPageV1
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseMisses
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
    slot_start = DateTime.shift(DateTime.utc_now(), hour: 1)

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
    slot_start = DateTime.shift(DateTime.utc_now(), hour: 1)

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
               DateTime.shift(DateTime.utc_now(), minute: 1),
               DateTime.shift(DateTime.utc_now(), minute: 6),
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

    past = schedule!(a, DateTime.shift(now, hour: -1))
    future_a = schedule!(a, DateTime.shift(now, hour: 1))
    future_b = schedule!(b, DateTime.shift(now, hour: 1))

    assert {:ok, 1} = ProducerAssignments.revoke_agents(group.id, ["agent-a"])

    assert state(group, past.id) == :scheduled
    assert state(group, future_a.id) == :dropped
    assert state(group, future_b.id) == :scheduled
  end

  test "keeping only some agents withdraws the unrun slots of the rest", ctx do
    group = create_group!(ctx)
    keep = assign!(group, "agent-keep")
    drop = assign!(group, "agent-drop")
    at = DateTime.shift(DateTime.utc_now(), hour: 1)

    kept = schedule!(keep, at)
    dropped = schedule!(drop, at)

    assert {:ok, 1} = ProducerAssignments.revoke_all_except(group.id, ["agent-keep"])

    assert state(group, kept.id) == :scheduled
    assert state(group, dropped.id) == :dropped
  end

  test "a reissued assignment schedules the same start after its slot was dropped", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    slot_start = DateTime.shift(DateTime.utc_now(), hour: 1)
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

  test "a closed slot whose lease still has a later slot is offline", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    now = DateTime.utc_now()
    grace = LeaseMisses.grace_seconds()
    assert grace == 300

    closed =
      schedule_window!(
        assignment,
        DateTime.shift(now, hour: -1),
        DateTime.shift(now, second: -(grace + 1))
      )

    later =
      schedule_window!(
        assignment,
        DateTime.shift(now, hour: 1),
        DateTime.shift(now, minute: 65)
      )

    assert {:ok, _} = LeaseMisses.mark(now)
    assert state(group, closed.id) == :missed_offline
    assert state(group, later.id) == :scheduled

    assert {:ok, _} = LeaseMisses.mark(now)
    assert state(group, closed.id) == :missed_offline
    assert state(group, later.id) == :scheduled
  end

  test "when several slots close, the earlier ones are offline and the last is exhausted", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    now = DateTime.utc_now()
    grace = LeaseMisses.grace_seconds()

    earlier =
      schedule_window!(
        assignment,
        DateTime.shift(now, hour: -2),
        DateTime.shift(now, hour: -1)
      )

    last =
      schedule_window!(
        assignment,
        DateTime.shift(now, hour: -1),
        DateTime.shift(now, second: -(grace + 1))
      )

    assert {:ok, _} = LeaseMisses.mark(now)
    assert state(group, earlier.id) == :missed_offline
    assert state(group, last.id) == :missed_exhausted
  end

  test "the last closed slot of an active assignment is exhausted", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    now = DateTime.utc_now()

    closed =
      schedule_window!(
        assignment,
        DateTime.shift(now, hour: -1),
        DateTime.shift(now, second: -LeaseMisses.grace_seconds())
      )

    assert {:ok, _} = LeaseMisses.mark(now)
    assert state(group, closed.id) == :missed_exhausted
  end

  test "a slot that closed before the lookback stays scheduled", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    now = DateTime.utc_now()
    lookback = LeaseMisses.lookback_seconds()

    # A completed slot stays scheduled, and execution retention later deletes its
    # execution row. Without the lookback, this slot would be relabelled missed.
    old =
      schedule_window!(
        assignment,
        DateTime.shift(now, second: -(lookback + 3600)),
        DateTime.shift(now, second: -(lookback + 1))
      )

    assert {:ok, _} = LeaseMisses.mark(now)
    assert state(group, old.id) == :scheduled
  end

  test "a slot still inside the grace stays scheduled", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    now = DateTime.utc_now()

    inside =
      schedule_window!(
        assignment,
        DateTime.shift(now, hour: -1),
        DateTime.shift(now, second: -(LeaseMisses.grace_seconds() - 1))
      )

    assert {:ok, _} = LeaseMisses.mark(now)
    assert state(group, inside.id) == :scheduled
  end

  test "a revoked assignment's closed slot is exhausted while a later started slot remains",
       ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    now = DateTime.utc_now()

    closed =
      schedule_window!(
        assignment,
        DateTime.shift(now, hour: -2),
        DateTime.shift(now, hour: -1)
      )

    started =
      schedule_window!(
        assignment,
        DateTime.shift(now, second: -30),
        DateTime.shift(now, minute: 5)
      )

    assert {:ok, 1} = ProducerAssignments.revoke_agents(group.id, ["agent-a"])
    assert {:ok, _} = LeaseMisses.mark(now)

    assert state(group, closed.id) == :missed_exhausted
    assert state(group, started.id) == :scheduled
  end

  test "a ledger-only batch does not keep the closed slot scheduled, and a sweep execution does",
       ctx do
    group = create_group!(ctx)
    batched = assign!(group, "agent-batch")
    executed = assign!(group, "agent-exec")
    now = DateTime.utc_now()
    start = DateTime.shift(now, hour: -1)
    expires = DateTime.shift(now, second: -(LeaseMisses.grace_seconds() + 1))

    batch_slot = schedule_window!(batched, start, expires)
    execution_slot = schedule_window!(executed, start, expires)
    insert_batch!(batched, batch_slot)
    insert_execution!(group, executed, execution_slot)

    assert {:ok, _} = LeaseMisses.mark(now)
    assert state(group, batch_slot.id) == :missed_exhausted
    assert state(group, execution_slot.id) == :scheduled
  end

  test "a dropped slot stays dropped", ctx do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-a")
    now = DateTime.utc_now()

    slot =
      schedule_window!(
        assignment,
        DateTime.shift(now, hour: -1),
        DateTime.shift(now, second: -LeaseMisses.grace_seconds())
      )

    slot
    |> Ash.Changeset.for_update(:drop, %{}, actor: SystemActor.system(:sweep_execution_slots))
    |> Ash.update!()

    assert {:ok, _} = LeaseMisses.mark(now)
    assert state(group, slot.id) == :dropped
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
    ExecutionSlots.schedule(assignment, slot_start, DateTime.shift(slot_start, minute: 5),
      targets: ["198.51.100.5", "192.0.2.9/24"],
      check_set_sha256: :crypto.hash(:sha256, "checks"),
      lease_id: Ash.UUID.generate()
    )
  end

  defp schedule!(assignment, slot_start) do
    assert {:ok, slot} = do_schedule(assignment, slot_start)
    slot
  end

  defp schedule_window!(assignment, slot_start, expires) do
    assert {:ok, slot} =
             ExecutionSlots.schedule(assignment, slot_start, expires,
               targets: ["198.51.100.5", "192.0.2.9/24"],
               check_set_sha256: :crypto.hash(:sha256, "checks"),
               lease_id: Ash.UUID.generate()
             )

    slot
  end

  defp insert_batch!(assignment, slot) do
    Repo.query!(
      """
      INSERT INTO platform.edge_sweep_batch_slots (
        network_scope_id, execution_id, execution_shard, assignment_epoch, batch_sequence,
        event_id, semantic_envelope_sha256, projected_row_count, committed_row_count
      ) VALUES ($1::uuid, $2::uuid, 0, 1, 0, $3::uuid, $4::bytea, 0, 0)
      """,
      [
        Ecto.UUID.dump!(assignment.network_scope_id),
        Ecto.UUID.dump!(slot.id),
        Ecto.UUID.dump!(Ash.UUID.generate()),
        :crypto.strong_rand_bytes(32)
      ]
    )
  end

  defp insert_execution!(group, assignment, slot) do
    Repo.query!(
      """
      INSERT INTO platform.sweep_group_executions (
        id, status, sweep_group_id, agent_id, inserted_at, updated_at
      ) VALUES ($1::uuid, 'running', $2::uuid, $3, now(), now())
      """,
      [Ecto.UUID.dump!(slot.id), Ecto.UUID.dump!(group.id), assignment.agent_id]
    )
  end

  defp state(group, slot_id) do
    assert {:ok, slots} = ExecutionSlots.list_for_group(group.id)
    Enum.find(slots, &(&1.id == slot_id)).state
  end
end
