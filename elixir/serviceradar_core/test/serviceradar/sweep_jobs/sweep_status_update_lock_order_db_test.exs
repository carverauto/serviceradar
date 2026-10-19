defmodule ServiceRadar.SweepJobs.SweepStatusUpdateLockOrderDbTest do
  @moduledoc """
  The sweep ingestor's device-status UPDATEs and the identity fence lock the same
  `ocsf_devices` rows, and the fence locks them in uid order. A status UPDATE that locks in
  the order its plan visits rows can hold a higher uid while it waits for a lower one the
  fence holds; the fence then asks for that higher uid and Postgres aborts one side with a
  deadlock (issue #5634). Each case here holds the lower row the way the fence does, lets
  the sweep run into it, then asks for the higher row without waiting: if the sweep took it
  first the request fails at once instead of forming the cycle.
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepResultsIngestor
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @wait_ms 15_000

  # A multi-row UPDATE locks rows in the order its plan emits them: physical order for a
  # sequential or bitmap scan, bucket order for a hash join. On a small test table the planner
  # tends to pick an index scan, which visits `uid = ANY($1)` in sorted order and hides the
  # bug, or a hash join, whose order depends on the uids' hash values. Sequential scans
  # joined by nested loops emit rows in physical order, which the setup arranges, so the
  # sweep's session is planned that way.
  @physical_order_planner [
    "SET enable_indexscan = off",
    "SET enable_indexonlyscan = off",
    "SET enable_bitmapscan = off",
    "SET enable_hashjoin = off",
    "SET enable_mergejoin = off"
  ]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sweep_status_update_lock_order_test)
    unique = System.unique_integer([:positive])
    partition = "lock-order-#{unique}"
    agent_id = "agent-lock-order-#{unique}"

    on_exit(fn -> cleanup!(partition) end)

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Lock Order #{unique}",
          partition: partition,
          agent_ids: [],
          interval: "1h",
          enabled: false
        },
        actor: actor
      )
      |> Ash.create()

    {devices, _reversed_pairs} =
      insert_high_uid_before_low_uid!(
        "platform.ocsf_devices",
        &create_lock_order_device!(unique, partition, actor, &1)
      )

    uids = Enum.map(devices, & &1.uid)

    [low_uid, high_uid] =
      Enum.map(
        Repo.query!("SELECT uid FROM platform.ocsf_devices WHERE uid = ANY($1) ORDER BY uid", [
          uids
        ]).rows,
        &hd/1
      )

    # Without this the sweep would reach the lower row first under any plan, and the case
    # could not tell ordered locking from plan-ordered locking.
    physical_order = physical_uid_order("platform.ocsf_devices", uids)

    assert physical_order == [[high_uid], [low_uid]],
           "setup must place the higher uid ahead of the lower one in physical order, got #{inspect(physical_order)}"

    {:ok,
     actor: actor,
     group: group,
     agent_id: agent_id,
     partition: partition,
     devices: devices,
     low_uid: low_uid,
     high_uid: high_uid}
  end

  for {kind, available?} <- [{"failure (hysteresis)", false}, {"success (available)", true}] do
    @tag available: available?
    test "a sweep #{kind} status update holds no higher uid while it waits for a lower one",
         %{available: available?} = context do
      ref = make_ref()
      holder = start_fence_holder(context.low_uid, ref)
      assert_receive {:fence_locked, ^ref, holder_backend}, @wait_ms

      sweeper = start_sweep(context, available?, ref)
      assert_receive {:sweep_backend, ^ref, sweep_backend}, @wait_ms

      try do
        waiting_on = await_sweep_blocked_by(sweeper, sweep_backend, holder_backend)

        assert waiting_on =~ "UPDATE ocsf_devices" and
                 waiting_on =~ "sweep_consecutive_failures",
               "the sweep must be waiting in a device-status update, got: #{waiting_on}"

        # The fence's next lock, in uid order. It must not find the row already taken.
        send(holder.pid, {:lock_next, ref, context.high_uid})
        assert_receive {:fence_next_lock, ^ref, next_lock}, @wait_ms
        assert {:ok, _locked} = next_lock

        assert {:ok, :committed} = Task.await(holder, @wait_ms)
        assert {:ok, _stats} = Task.await(sweeper, @wait_ms)
      after
        stop_task(holder, ref)
        stop_task(sweeper, ref)
      end

      for device <- context.devices do
        {:ok, reloaded} = Device.get_by_uid(device.uid, false, actor: context.actor)

        if available? do
          assert reloaded.is_available
          assert reloaded.metadata["sweep_consecutive_failures"] == 0
        else
          assert reloaded.metadata["sweep_consecutive_failures"] == 1
        end
      end
    end
  end

  # A private temp table on one pinned connection gives a heap layout no other writer can
  # disturb. Block 0 keeps room for one small row but not a large one, so the large fillers
  # extend into block 1 and leave room for exactly one small row there. The first target
  # insert takes that slot; the second asks the FSM, whose only candidate is block 0.
  test "insert_high_uid_before_low_uid!/2 recovers when the FSM wraps from a later block to an earlier block" do
    Repo.checkout(fn ->
      Repo.query!("CREATE TEMP TABLE lock_order_fsm (uid text NOT NULL, pad text NOT NULL)")

      try do
        Repo.query!("ALTER TABLE lock_order_fsm ALTER COLUMN pad SET STORAGE PLAIN")

        for n <- 1..8, do: insert_fsm_row!("fill-#{n}", 900)
        Repo.query!("DELETE FROM lock_order_fsm WHERE uid = 'fill-1'")
        Repo.query!("VACUUM lock_order_fsm")

        for n <- 9..11, do: insert_fsm_row!("fill-#{n}", 1900)
        insert_fsm_row!("fill-12", 900)

        assert fsm_blocks() == %{0 => 7, 1 => 4},
               "setup must leave one small slot in block 0 and one in block 1, got #{inspect(fsm_blocks())}"

        {[high, low], reversed_pairs} =
          insert_high_uid_before_low_uid!("lock_order_fsm", fn seq ->
            uid = "target-#{seq}"
            insert_fsm_row!(uid, 900)
            %{uid: uid}
          end)

        assert reversed_pairs == 1,
               "the first target pair must land in reversed physical order, got #{reversed_pairs}"

        assert high.uid > low.uid

        assert Repo.query!(
                 "SELECT uid FROM lock_order_fsm WHERE uid LIKE 'target-%' ORDER BY uid"
               ).rows == [
                 [low.uid],
                 [high.uid]
               ]

        assert physical_uid_order("lock_order_fsm", [high.uid, low.uid]) == [
                 [high.uid],
                 [low.uid]
               ]
      after
        Repo.query!("DROP TABLE IF EXISTS lock_order_fsm")
      end
    end)
  end

  # Holds the lower row in its own transaction exactly as the identity fence does
  # (`FOR NO KEY UPDATE`, uid order), then takes the next row only when told to.
  defp start_fence_holder(low_uid, ref) do
    parent = self()

    Task.async(fn ->
      Repo.checkout(
        fn ->
          Repo.transaction(fn ->
            [[backend]] =
              Repo.query!(
                "SELECT pg_backend_pid() FROM platform.ocsf_devices WHERE uid = $1 FOR NO KEY UPDATE",
                [low_uid]
              ).rows

            send(parent, {:fence_locked, ref, backend})

            receive do
              {:lock_next, ^ref, next_uid} ->
                result =
                  Repo.query(
                    "SELECT uid FROM platform.ocsf_devices WHERE uid = $1 FOR NO KEY UPDATE NOWAIT",
                    [next_uid]
                  )

                send(parent, {:fence_next_lock, ref, result})

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

  defp start_sweep(context, available?, ref) do
    parent = self()

    results =
      Enum.map(context.devices, fn device ->
        %{
          "host_ip" => device.ip,
          "available" => available?,
          "port_results" => [],
          "icmp_status" => %{"available" => available?}
        }
      end)

    Task.async(fn ->
      Repo.checkout(
        fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          Enum.each(@physical_order_planner, &Repo.query!/1)
          send(parent, {:sweep_backend, ref, backend})

          try do
            SweepResultsIngestor.ingest_results(results, Ash.UUID.generate(),
              actor: context.actor,
              sweep_group_id: context.group.id,
              agent_id: context.agent_id,
              authenticated_agent_id: context.agent_id,
              authenticated_partition_id: context.partition,
              config_version: "lock-order-#{System.unique_integer([:positive])}"
            )
          after
            Repo.query!("RESET ALL")
          end
        end,
        timeout: @wait_ms * 2
      )
    end)
  end

  # Returns the statement the sweep is blocked in once it waits on the holder's lock. A sweep
  # that finishes first never reached the held row, so the case proves nothing and fails.
  defp await_sweep_blocked_by(sweeper, sweep_backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    do_await_sweep_blocked_by(sweeper, sweep_backend, holder_backend, deadline)
  end

  defp do_await_sweep_blocked_by(sweeper, sweep_backend, holder_backend, deadline) do
    blocked =
      Repo.query!(
        """
        SELECT query
        FROM pg_stat_activity
        WHERE pid = $1
          AND wait_event_type = 'Lock'
          AND $2 = ANY(pg_blocking_pids(pid))
        """,
        [sweep_backend, holder_backend]
      ).rows

    cond do
      match?([[_query]], blocked) ->
        [[query]] = blocked
        query

      not Process.alive?(sweeper.pid) ->
        flunk(
          "the sweep finished without waiting on the held row: #{inspect(Task.yield(sweeper, 0))}"
        )

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the sweep never waited on the held row within #{@wait_ms}ms")

      true ->
        Process.sleep(25)
        do_await_sweep_blocked_by(sweeper, sweep_backend, holder_backend, deadline)
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

  # Inserts descending-uid rows into `table` inside a single table-locked transaction until two
  # consecutive inserts satisfy `ctid(higher_uid) < ctid(lower_uid)`.
  #
  # Locking the table prevents concurrent transactions from interleaving,
  # but a single backend's first insert can still fill the last free slot on its cached
  # `smgr_targblock` (a higher block number) and force the second insert to query the
  # Free Space Map (FSM), which may return an earlier vacuumed block (`ctid(second) < ctid(first)`).
  # Keeping earlier attempts in the heap until a pair lands in increasing `ctid` order prevents
  # the FSM from reusing those slots and guarantees termination in well-founded `ctid` order.
  defp insert_high_uid_before_low_uid!(table, insert!) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("LOCK TABLE #{table} IN SHARE ROW EXCLUSIVE MODE")
        advance_until_high_before_low!(table, insert!, insert!.(999), 998, [])
      end)

    result
  end

  defp advance_until_high_before_low!(_table, _insert!, _prev, seq, _discarded) when seq < 1 do
    flunk("failed to place a higher uid before a lower uid in physical order after 999 attempts")
  end

  defp advance_until_high_before_low!(table, insert!, prev, seq, discarded) do
    curr = insert!.(seq)

    if physical_uid_order(table, [prev.uid, curr.uid]) == [[prev.uid], [curr.uid]] do
      if discarded != [] do
        discarded_uids = Enum.map(discarded, & &1.uid)
        Repo.query!("DELETE FROM #{table} WHERE uid = ANY($1)", [discarded_uids])
      end

      {[prev, curr], length(discarded)}
    else
      advance_until_high_before_low!(table, insert!, curr, seq - 1, [prev | discarded])
    end
  end

  defp create_lock_order_device!(unique, partition, actor, seq) do
    seq_tag = seq |> Integer.to_string() |> String.pad_leading(4, "0")
    third_octet = div(1000 - seq, 250)
    fourth_octet = rem(1000 - seq, 250) + 1

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: "sr:lock-order-#{unique}-#{seq_tag}",
        ip: "198.18.#{third_octet}.#{fourth_octet}",
        partition: partition,
        is_available: true,
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

  defp physical_uid_order(table, uids) do
    Repo.query!("SELECT uid FROM #{table} WHERE uid = ANY($1) ORDER BY ctid", [uids]).rows
  end

  defp insert_fsm_row!(uid, pad_bytes) do
    Repo.query!("INSERT INTO lock_order_fsm (uid, pad) VALUES ($1, repeat('x', $2))", [
      uid,
      pad_bytes
    ])
  end

  defp fsm_blocks do
    Map.new(
      Repo.query!("SELECT (ctid::text::point)[0]::int, count(*) FROM lock_order_fsm GROUP BY 1").rows,
      fn [
           block,
           count
         ] ->
        {block, count}
      end
    )
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
