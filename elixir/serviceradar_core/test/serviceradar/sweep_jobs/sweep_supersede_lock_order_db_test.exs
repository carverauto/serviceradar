defmodule ServiceRadar.SweepJobs.SweepSupersedeLockOrderDbTest do
  @moduledoc """
  The first batch of a new execution supersedes the sweep group's older running executions
  for the same agent, which locks their rows. A late batch of an older execution locks its
  device rows (and the inventory rollup lock) first and its execution row last. If the new
  batch locks the older execution row while creating its own and then waits on a device row
  the late batch holds, the late batch's request for its execution row closes a wait cycle
  and Postgres aborts one side with a deadlock.

  The new batch runs in one transaction, as the EventWriter runs each record, so any row lock
  it takes is held until it commits. The case holds a device row the way that late batch
  does, lets the new batch run into it, then asks for the older execution row without
  waiting: if the new batch took it first the request fails at once instead of forming the
  cycle.
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepResultsIngestor
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @wait_ms 15_000

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sweep_supersede_lock_order_test)
    unique = System.unique_integer([:positive])
    partition = "supersede-order-#{unique}"
    agent_id = "agent-supersede-order-#{unique}"

    on_exit(fn -> cleanup!(partition) end)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Supersede Order #{unique}",
          partition: partition,
          agent_ids: [],
          interval: "1h",
          enabled: false
        },
        actor: actor
      )
      |> Ash.create()

    device = create_device!(unique, partition, actor)
    older_execution_id = insert_running_execution!(group.id, agent_id)

    {:ok,
     actor: actor,
     group: group,
     agent_id: agent_id,
     partition: partition,
     device: device,
     older_execution_id: older_execution_id}
  end

  test "a new execution's first batch holds no older execution row while it waits on a device",
       context do
    ref = make_ref()
    holder = start_late_batch_holder(context.device.uid, ref)
    assert_receive {:device_locked, ^ref, holder_backend}, @wait_ms

    new_batch = start_new_execution_batch(context, ref)
    assert_receive {:batch_backend, ^ref, batch_backend}, @wait_ms

    try do
      await_blocked_by(new_batch, batch_backend, holder_backend)

      # The late batch's next lock: its own (older) execution row. It must not find it taken.
      send(holder.pid, {:lock_execution, ref, context.older_execution_id})
      assert_receive {:execution_lock, ^ref, execution_lock}, @wait_ms
      assert {:ok, _locked} = execution_lock

      assert {:ok, :committed} = Task.await(holder, @wait_ms)
      assert {:ok, _stats} = Task.await(new_batch, @wait_ms)
    after
      stop_task(holder, ref)
      stop_task(new_batch, ref)
    end

    # Superseding still happens, in the same ingest, once the device work is done.
    older = Repo.get!(SweepGroupExecution, context.older_execution_id)
    assert older.status == :failed
    assert older.error_message == "superseded by new execution"
  end

  # Holds the device row in its own transaction the way a late batch of the older execution
  # does, then asks for that execution's row only when told to.
  defp start_late_batch_holder(device_uid, ref) do
    parent = self()

    Task.async(fn ->
      Repo.checkout(
        fn ->
          Repo.transaction(fn ->
            [[backend]] =
              Repo.query!(
                "SELECT pg_backend_pid() FROM platform.ocsf_devices WHERE uid = $1 FOR NO KEY UPDATE",
                [device_uid]
              ).rows

            send(parent, {:device_locked, ref, backend})

            receive do
              {:lock_execution, ^ref, execution_id} ->
                result =
                  Repo.query(
                    "SELECT id FROM platform.sweep_group_executions WHERE id = $1 FOR UPDATE NOWAIT",
                    [Ecto.UUID.dump!(execution_id)]
                  )

                send(parent, {:execution_lock, ref, result})

                case result do
                  {:ok, _} -> :committed
                  {:error, error} -> Repo.rollback(error)
                end

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
  end

  defp start_new_execution_batch(context, ref) do
    parent = self()

    results = [
      %{
        "host_ip" => context.device.ip,
        "available" => true,
        "port_results" => [],
        "icmp_status" => %{"available" => true}
      }
    ]

    Task.async(fn ->
      Repo.checkout(
        fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:batch_backend, ref, backend})

          Repo.transaction(fn ->
            case SweepResultsIngestor.ingest_results(results, Ash.UUID.generate(),
                   actor: context.actor,
                   repo: Repo,
                   sweep_group_id: context.group.id,
                   agent_id: context.agent_id,
                   authenticated_agent_id: context.agent_id,
                   authenticated_partition_id: context.partition,
                   config_version: "supersede-order-#{System.unique_integer([:positive])}"
                 ) do
              {:ok, stats} -> stats
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
        end,
        timeout: @wait_ms * 2
      )
    end)
  end

  # A batch that finishes first never reached the held row, so the case proves nothing and fails.
  defp await_blocked_by(task, backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    do_await_blocked_by(task, backend, holder_backend, deadline)
  end

  defp do_await_blocked_by(task, backend, holder_backend, deadline) do
    blocked =
      Repo.query!(
        """
        SELECT 1
        FROM pg_stat_activity
        WHERE pid = $1
          AND wait_event_type = 'Lock'
          AND $2 = ANY(pg_blocking_pids(pid))
        """,
        [backend, holder_backend]
      ).rows

    cond do
      blocked != [] ->
        :ok

      not Process.alive?(task.pid) ->
        flunk(
          "the batch finished without waiting on the held device: #{inspect(Task.yield(task, 0))}"
        )

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the batch never waited on the held device within #{@wait_ms}ms")

      true ->
        Process.sleep(25)
        do_await_blocked_by(task, backend, holder_backend, deadline)
    end
  end

  defp stop_task(task, ref) do
    if Process.alive?(task.pid) do
      send(task.pid, {:release, ref})

      if is_nil(Task.yield(task, 1_000)) do
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  defp insert_running_execution!(sweep_group_id, agent_id) do
    id = Ash.UUID.generate()
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(SweepGroupExecution, [
        %{
          id: id,
          sweep_group_id: sweep_group_id,
          agent_id: agent_id,
          config_version: "older",
          status: :running,
          started_at: now |> DateTime.shift(minute: -10) |> DateTime.truncate(:second),
          hosts_total: 1,
          hosts_available: 0,
          hosts_failed: 0,
          inserted_at: DateTime.truncate(now, :microsecond),
          updated_at: DateTime.truncate(now, :microsecond)
        }
      ])

    id
  end

  defp create_device!(unique, partition, actor) do
    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: "sr:supersede-order-#{unique}",
        ip: "198.18.0.#{rem(unique, 250) + 1}",
        partition: partition,
        is_available: false,
        metadata: %{}
      },
      actor: actor
    )
    |> Ash.create!(return_notifications?: true)
    |> case do
      {device, _notifications} -> device
      device -> device
    end
  end

  # Everything the case commits hangs off its own partition, so cleanup needs no state from a
  # setup that may have failed part way.
  defp cleanup!(partition) do
    groups = "SELECT id FROM platform.sweep_groups WHERE partition = $1"
    devices = "SELECT uid FROM platform.ocsf_devices WHERE partition = $1"

    for sql <- [
          "DELETE FROM platform.sweep_host_results WHERE sweep_group_id IN (#{groups})",
          "DELETE FROM platform.sweep_group_executions WHERE sweep_group_id IN (#{groups})",
          "DELETE FROM platform.sweep_group_versions WHERE version_source_id IN (#{groups})",
          "DELETE FROM platform.device_agent_availability WHERE device_uid IN (#{devices})"
        ] do
      Repo.query!(sql, [partition])
    end

    %{rows: rows} = Repo.query!(devices, [partition])
    TestSupport.delete_device_fixtures!(Enum.map(rows, fn [uid] -> uid end))
    Repo.query!("DELETE FROM platform.sweep_groups WHERE partition = $1", [partition])
  end
end
