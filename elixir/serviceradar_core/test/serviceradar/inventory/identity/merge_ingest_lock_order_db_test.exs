defmodule ServiceRadar.Inventory.Identity.MergeIngestLockOrderDbTest do
  @moduledoc """
  The device merge and the sweep ingest lock the same rows in opposite order.
  The ingest takes per-agent availability rows in `(device_uid, agent_id)`
  order and then the device rows in uid order (#6450), while the merge locks
  the device rows first and only then writes the availability rows it
  reassigns to the survivor. A merge and an ingest over the same devices
  interleave into a cycle -- the merge holds the devices and wants the
  availability rows, the ingest holds the availability rows and wants the
  devices -- and Postgres aborts one side with a deadlock.

  Each case stages the cycle deterministically rather than racing it. An
  advisory holder parks the merge after its device locks (the
  source-authority guard takes the same per-device advisory key,
  `maybe_lock_ownership/2`), the ingest then takes the availability rows and
  parks on the merge's device locks, and releasing the holder lets the merge
  run into the ingest's availability locks. Both holdings are observed
  through `pg_stat_activity` before the release, so the cycle does not
  depend on timing. On the fixed code the merge takes the availability rows
  first, in the ingest's order, so the same staging serializes and both
  commit.

  Unboxed with independent connections; `on_exit` deletes everything created.
  """

  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepResultsIngestor
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @wait_ms 15_000

  # The advisory key the source-authority guard locks per device
  # (`maybe_lock_ownership/2`); the holder below takes the same key.
  @advisory_key "SELECT pg_advisory_xact_lock(hashtextextended('serviceradar:armis-identifier-owner:' || $1, 0))"

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:merge_ingest_lock_order_test)
    unique = System.unique_integer([:positive])
    partition = "merge-lock-order-#{unique}"
    agent_id = "agent-merge-lock-order-#{unique}"
    ip_a = TestSupport.unique_device_ip()
    ip_b = TestSupport.unique_device_ip()

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Merge Ingest Lock Order #{unique}",
          partition: partition,
          agent_ids: [],
          static_targets: [ip_a, ip_b],
          enabled: false
        },
        actor: actor
      )
      |> Ash.create()

    on_exit(fn -> cleanup!(group.id, partition, [ip_a, ip_b]) end)

    # A serial first ingest creates both devices with this agent's
    # availability rows, through the same path the concurrent ingest uses.
    assert {:ok, _stats} =
             ingest(group, actor, agent_id, partition, available_results([ip_a, ip_b]))

    [from_uid, to_uid] =
      [ip_a, ip_b]
      |> device_uids_for_ips()
      |> Enum.sort()

    {:ok,
     actor: actor,
     group: group,
     agent_id: agent_id,
     partition: partition,
     ip_a: ip_a,
     ip_b: ip_b,
     from_uid: from_uid,
     to_uid: to_uid}
  end

  # A merge of one device into the other while a sweep ingest reports both:
  # the merge holds the device rows and wants the availability rows, the
  # ingest holds the availability rows and wants the device rows. Both must
  # commit; on the unfixed code Postgres aborts one side with a deadlock.
  @tag timeout: 300_000
  test "a merge and an ingest over the same devices in opposing order both commit", ctx do
    holder = hold_merge_advisory(ctx.from_uid)
    assert_receive {:advisory_held, holder_pid, holder_backend}, @wait_ms
    assert holder_pid == holder.pid

    merge = start_merge(ctx.from_uid, ctx.to_uid, ctx.actor)

    # The merge holds both device rows once it waits on the guard's advisory
    # key: lock_device_rows/2 runs before the guard in the transaction.
    await_blocked!(merge.backend, holder_backend, "%pg_advisory_xact_lock%")

    ingest =
      start_ingest_transaction(ctx, ctx.agent_id,
        hold?: false,
        results: available_results([ctx.ip_a, ctx.ip_b])
      )

    send(ingest.task.pid, :go)

    # Where the ingest parks depends on the merge's lock order. On the fixed
    # code the merge holds the availability rows from its first statement, so
    # the ingest waits on the merge there while holding nothing. On the
    # unfixed code the availability rows are free, so the ingest takes them
    # (the upsert runs before lock_observed_devices/1) and waits on the
    # merge's device locks instead. Either way it is parked before the
    # release; on the unfixed code the release completes the cycle and
    # Postgres aborts one side with a deadlock.
    if blocked_on?(ingest.backend, merge.backend, "%device_agent_availability%") do
      :ok
    else
      await_blocked!(ingest.backend, merge.backend, "%ocsf_devices%")
    end

    send(holder.pid, :release)
    Task.await(holder, @wait_ms)

    assert {:ok, :ok} = Task.await(merge.task, @wait_ms)
    assert {:ok, {:ok, _stats}} = Task.await(ingest.task, @wait_ms)

    assert {merged_at, "merged"} = tombstone(ctx.from_uid)
    assert merged_at
    assert live?(ctx.to_uid)
    assert merge_audited?(ctx.from_uid, ctx.to_uid)
  end

  # Parks the merge after its device locks: takes the same advisory key the
  # source-authority guard takes, and holds the transaction until :release.
  defp hold_merge_advisory(device_uid) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        Repo.query!(@advisory_key, [device_uid])
        send(parent, {:advisory_held, self(), backend})
        receive do: (:release -> :ok)
      end)
    end)
  end

  defp start_merge(from_uid, to_uid, actor) do
    parent = self()

    task =
      Task.async(fn ->
        # One pinned connection, so the backend reported is the one the transaction runs on.
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, self(), backend})

          try do
            Repo.transaction(fn ->
              MergeEngine.merge_devices(from_uid, to_uid,
                actor: actor,
                reason: "identifier_backfill"
              )
            end)
          rescue
            # An aborted transaction (a deadlock) is returned, so the assertion names it.
            error in Postgrex.Error -> {:raised, error.postgres.code}
          end
        after
          Sandbox.checkin(Repo)
        end
      end)

    pid = task.pid
    assert_receive {:backend, ^pid, backend}, @wait_ms
    %{task: task, backend: backend}
  end

  # The caller's transaction runs the whole ingest. The ingest starts on :go.
  defp start_ingest_transaction(ctx, agent_id, opts) do
    results = Keyword.fetch!(opts, :results)
    parent = self()

    task =
      Task.async(fn ->
        # One pinned connection, so the backend reported is the one the transaction runs on.
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, self(), backend})
          receive do: (:go -> :ok)

          try do
            Repo.transaction(fn ->
              ingest(ctx.group, ctx.actor, agent_id, ctx.partition, results)
            end)
          rescue
            # An aborted transaction (a deadlock) is returned, so the assertion names it.
            error in Postgrex.Error -> {:raised, error.postgres.code}
          end
        after
          Sandbox.checkin(Repo)
        end
      end)

    pid = task.pid
    assert_receive {:backend, ^pid, backend}, @wait_ms
    %{task: task, backend: backend}
  end

  defp available_results(ips), do: Enum.map(ips, &%{"host_ip" => &1, "available" => true})

  defp ingest(group, actor, agent_id, partition, results) do
    SweepResultsIngestor.ingest_results(results, Ash.UUID.generate(),
      actor: actor,
      sweep_group_id: group.id,
      agent_id: agent_id,
      authenticated_agent_id: agent_id,
      authenticated_partition_id: partition
    )
  end

  defp device_uids_for_ips(ips) do
    %{rows: rows} =
      Repo.query!("SELECT uid FROM platform.ocsf_devices WHERE ip = ANY($1)", [ips])

    Enum.map(rows, &hd/1)
  end

  defp tombstone(uid) do
    %{rows: [[deleted_at, reason]]} =
      Repo.query!(
        "SELECT deleted_at, deleted_reason FROM platform.ocsf_devices WHERE uid = $1",
        [uid]
      )

    {deleted_at, reason}
  end

  defp live?(uid) do
    %{rows: [[deleted_at]]} =
      Repo.query!("SELECT deleted_at FROM platform.ocsf_devices WHERE uid = $1", [uid])

    deleted_at == nil
  end

  defp merge_audited?(from_uid, to_uid) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM platform.merge_audit WHERE from_device_id = $1 AND to_device_id = $2",
        [from_uid, to_uid]
      )

    rows != []
  end

  # Whether backend `waiter` is waiting on backend `holder` in a statement
  # LIKE `statement` within `wait_ms`, without failing when it never does.
  defp blocked_on?(waiter, holder, statement, wait_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + wait_ms
    do_blocked_on?(waiter, holder, statement, deadline)
  end

  defp do_blocked_on?(waiter, holder, statement, deadline) do
    %{rows: [[blocked]]} =
      Repo.query!(
        """
        SELECT $2::int = ANY(pg_blocking_pids($1::int)) AND query LIKE $3
        FROM pg_stat_activity
        WHERE pid = $1::int
        """,
        [waiter, holder, statement]
      )

    cond do
      blocked ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        do_blocked_on?(waiter, holder, statement, deadline)
    end
  end

  # Waits until backend `waiter` waits on backend `holder` in a statement LIKE `statement`, not
  # on anything taken earlier.
  defp await_blocked!(waiter, holder, statement, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wait_ms

    %{rows: [[blocked]]} =
      Repo.query!(
        """
        SELECT $2::int = ANY(pg_blocking_pids($1::int)) AND query LIKE $3
        FROM pg_stat_activity
        WHERE pid = $1::int
        """,
        [waiter, holder, statement]
      )

    if !blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "backend #{waiter} never waited on #{holder} in #{statement}"

      Process.sleep(10)
      await_blocked!(waiter, holder, statement, deadline)
    end
  end

  # Everything the case commits hangs off its own partition, so cleanup needs no state from a
  # setup that may have failed part way.
  defp cleanup!(group_id, _partition, ips) do
    group_id = Ecto.UUID.dump!(group_id)

    executions =
      List.flatten(
        Repo.query!("SELECT id FROM platform.sweep_group_executions WHERE sweep_group_id = $1", [
          group_id
        ]).rows
      )

    Repo.query!("DELETE FROM platform.sweep_host_results WHERE execution_id = ANY($1)", [
      executions
    ])

    Repo.query!(
      "DELETE FROM platform.sweep_group_execution_versions WHERE version_source_id = ANY($1)",
      [executions]
    )

    Repo.query!("DELETE FROM platform.sweep_group_executions WHERE id = ANY($1)", [executions])

    Repo.query!("DELETE FROM platform.sweep_group_versions WHERE version_source_id = $1", [
      group_id
    ])

    Repo.query!("DELETE FROM platform.sweep_groups WHERE id = $1", [group_id])

    uids =
      List.flatten(
        Repo.query!("SELECT uid FROM platform.ocsf_devices WHERE ip = ANY($1)", [ips]).rows
      )

    Repo.query!("DELETE FROM platform.device_agent_availability WHERE device_uid = ANY($1)", [
      uids
    ])

    Repo.query!("DELETE FROM platform.merge_audit WHERE from_device_id = ANY($1)", [uids])
    Repo.query!("DELETE FROM platform.merge_audit WHERE to_device_id = ANY($1)", [uids])

    TestSupport.delete_device_fixtures!(uids)
    Enum.each(ips, &IdentityCache.delete/1)
  end
end
