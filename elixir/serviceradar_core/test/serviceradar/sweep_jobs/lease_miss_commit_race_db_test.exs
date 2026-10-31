defmodule ServiceRadar.SweepJobs.LeaseMissCommitRaceDbTest do
  @moduledoc """
  A lease mark that is already waiting on a sweep slot must see a batch or
  execution committed by the lock holder. One statement would keep the
  snapshot from before the wait and mark the slot missed anyway.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ExecutionSlots
  alias ServiceRadar.SweepJobs.LeaseMisses
  alias ServiceRadar.SweepJobs.ProducerAssignments
  alias ServiceRadar.SweepJobs.SweepGroup

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @wait_ms 15_000

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    actor = %{id: Ash.UUID.generate(), email: "operator-#{suffix}@example.test", role: :operator}
    {:ok, actor: actor, suffix: suffix}
  end

  test "a batch committed while the mark waits on the slot stays scheduled", ctx do
    assert_commit_while_mark_waits(ctx, :batch)
  end

  test "an execution committed while the mark waits on the slot stays scheduled", ctx do
    assert_commit_while_mark_waits(ctx, :execution)
  end

  defp assert_commit_while_mark_waits(ctx, evidence) do
    group = create_group!(ctx)
    assignment = assign!(group, "agent-#{ctx.suffix}-#{evidence}")
    now = DateTime.utc_now()
    grace = LeaseMisses.grace_seconds()

    closed =
      schedule_window!(
        assignment,
        DateTime.shift(now, hour: -1),
        DateTime.shift(now, second: -(grace + 1))
      )

    on_exit(fn -> cleanup!(group.id, closed.id) end)

    ref = make_ref()
    parent = self()
    slot_id = Ecto.UUID.dump!(closed.id)

    holder =
      Task.async(fn ->
        Repo.checkout(
          fn ->
            Repo.transaction(fn ->
              [[holder_backend]] =
                Repo.query!(
                  "SELECT pg_backend_pid() FROM platform.sweep_execution_slots WHERE id = $1::uuid FOR UPDATE",
                  [slot_id]
                ).rows

              send(parent, {:held, ref, holder_backend})

              receive do
                {:commit_evidence, ^ref} ->
                  commit_evidence!(evidence, group, assignment, closed)
                  :committed

                {:release, ^ref} ->
                  Repo.rollback(:released)
              after
                @wait_ms -> Repo.rollback(:timed_out)
              end
            end)
          end,
          timeout: @wait_ms * 2
        )
      end)

    marker =
      Task.async(fn ->
        Repo.checkout(
          fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:mark_backend, ref, backend})

            receive do
              {:run_mark, ^ref} -> LeaseMisses.mark(now)
            after
              @wait_ms -> {:error, :timed_out}
            end
          end,
          timeout: @wait_ms * 2
        )
      end)

    try do
      assert_receive {:held, ^ref, holder_backend}, @wait_ms
      assert_receive {:mark_backend, ^ref, mark_backend}, @wait_ms
      send(marker.pid, {:run_mark, ref})
      assert :ok = await_blocked(mark_backend, holder_backend, @wait_ms)
      send(holder.pid, {:commit_evidence, ref})
      assert {:ok, :committed} = Task.await(holder, @wait_ms)

      assert {:ok, %{missed_offline: 0, missed_exhausted: 0}} = Task.await(marker, @wait_ms)
      assert slot_state(slot_id) == "scheduled"
    after
      if Process.alive?(holder.pid), do: send(holder.pid, {:release, ref})
      shutdown_task(holder)
      shutdown_task(marker)
    end
  end

  defp await_blocked(mark_backend, holder_backend, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_blocked(mark_backend, holder_backend, deadline)
  end

  defp do_await_blocked(mark_backend, holder_backend, deadline) do
    [[count]] =
      Repo.query!(
        """
        SELECT count(*)
        FROM pg_stat_activity
        WHERE pid = $1
          AND wait_event_type = 'Lock'
          AND $2 = ANY(pg_blocking_pids(pid))
        """,
        [mark_backend, holder_backend]
      ).rows

    cond do
      count == 1 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the lease mark never waited on the slot lock")

      true ->
        Process.sleep(25)
        do_await_blocked(mark_backend, holder_backend, deadline)
    end
  end

  defp commit_evidence!(:batch, _group, assignment, slot) do
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

  defp commit_evidence!(:execution, group, assignment, slot) do
    Repo.query!(
      """
      INSERT INTO platform.sweep_group_executions (
        id, status, sweep_group_id, agent_id, inserted_at, updated_at
      ) VALUES ($1::uuid, 'running', $2::uuid, $3, now(), now())
      """,
      [Ecto.UUID.dump!(slot.id), Ecto.UUID.dump!(group.id), assignment.agent_id]
    )
  end

  defp slot_state(slot_id) do
    [[state]] =
      Repo.query!("SELECT state FROM platform.sweep_execution_slots WHERE id = $1::uuid", [
        slot_id
      ]).rows

    state
  end

  defp cleanup!(group_id, slot_id) do
    group_id = Ecto.UUID.dump!(group_id)
    slot_id = Ecto.UUID.dump!(slot_id)

    Repo.query!("DELETE FROM platform.edge_sweep_batch_slots WHERE execution_id = $1::uuid", [
      slot_id
    ])

    Repo.query!("DELETE FROM platform.sweep_group_executions WHERE id = $1::uuid", [slot_id])
    Repo.query!("DELETE FROM platform.sweep_groups WHERE id = $1::uuid", [group_id])
  end

  defp shutdown_task(task) do
    if Process.alive?(task.pid) and is_nil(Task.yield(task, 1_000)) do
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp create_group!(%{actor: actor, suffix: suffix}) do
    unique = System.unique_integer([:positive, :monotonic])

    assert {:ok, group} =
             SweepGroup
             |> Ash.Changeset.for_create(
               :create,
               %{
                 name: "Lease miss race #{suffix}-#{unique}",
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

  defp schedule_window!(assignment, slot_start, expires) do
    assert {:ok, slot} =
             ExecutionSlots.schedule(assignment, slot_start, expires,
               targets: ["198.51.100.5", "192.0.2.9/24"],
               check_set_sha256: :crypto.hash(:sha256, "checks"),
               lease_id: Ash.UUID.generate()
             )

    slot
  end
end
