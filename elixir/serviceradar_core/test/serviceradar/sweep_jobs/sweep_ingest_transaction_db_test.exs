defmodule ServiceRadar.SweepJobs.SweepIngestTransactionDbTest do
  @moduledoc """
  The sweep results ingest inside a caller's transaction, as the edge-record ledger transaction
  runs it. There a failed statement aborts the whole transaction, so the ingest must never
  raise a constraint error it could have avoided, and must never swallow a database error that
  aborted the transaction: either way the caller loses the batch.

  Each case commits its rows from independent connections, so the module is unboxed and
  deletes everything it created in `on_exit`.
  """
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.IdentityCache
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepResultsIngestor
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @wait_ms 15_000
  # An ingest of a thousand results, which may first wait for another of the same size.
  @large_ingest_wait_ms 120_000

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sweep_ingest_transaction_test)
    unique = System.unique_integer([:positive])
    ip = TestSupport.unique_device_ip()

    # Two groups sweeping the same address: each batch records its own group's execution, so
    # neither waits on the other before it reaches the device.
    [group, other_group] =
      for name <- ["a", "b"] do
        {:ok, group} =
          SweepGroup
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Sweep Ingest Transaction #{unique} #{name}",
              partition: "default",
              agent_ids: [],
              static_targets: [ip],
              enabled: false
            },
            actor: actor
          )
          |> Ash.create()

        group
      end

    on_exit(fn -> cleanup!([group.id, other_group.id], ip) end)

    {:ok, actor: actor, group: group, other_group: other_group, ip: ip, seed_uid: seed_uid(ip)}
  end

  # Two agents' batches answer the same unknown address at once. Both derive the same seed uid;
  # the second waits on the first's uncommitted row. A plain create then raised a unique
  # violation that Ash rolled the caller's transaction back with, and the second batch was lost.
  test "two transactions seeding the same address both commit, with one device", ctx do
    first_agent = "agent-seed-race-a-#{System.unique_integer([:positive])}"
    second_agent = "agent-seed-race-b-#{System.unique_integer([:positive])}"

    first = start_ingest_transaction(ctx, first_agent, hold?: true)
    assert_receive {:ingested, first_pid}, @wait_ms
    assert first_pid == first.task.pid

    second = start_ingest_transaction(%{ctx | group: ctx.other_group}, second_agent, hold?: false)
    send(second.task.pid, :go)
    await_blocked!(second.backend, first.backend, "INSERT INTO %ocsf_devices%")
    send(first.task.pid, :commit)

    assert {:ok, {:ok, _stats}} = Task.await(first.task, @wait_ms)
    assert {:ok, {:ok, _stats}} = Task.await(second.task, @wait_ms)

    assert [[uid, nil]] = device_rows(ctx.ip)
    assert uid == ctx.seed_uid
    assert availability_agents(uid) == Enum.sort([first_agent, second_agent])
  end

  # A deadlock (here a lock timeout, which takes the same path and does not depend on timing)
  # aborts the caller's transaction. Logging it and carrying on left the transaction to fail
  # later under an unrelated cause, and the caller acknowledged the record.
  test "a database error from the availability upsert propagates out of the transaction", ctx do
    agent_id = "agent-availability-lock-#{System.unique_integer([:positive])}"
    assert {:ok, _stats} = ingest(ctx, agent_id)
    assert [[uid, nil]] = device_rows(ctx.ip)

    holder = hold_availability_rows([uid], agent_id)
    assert_receive {:availability_locked, holder_pid, _backend}, @wait_ms
    assert holder_pid == holder.pid

    try do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL lock_timeout = '200ms'")
            ingest(ctx, agent_id)
          end)
        end

      assert error.postgres.code == :lock_not_available
    after
      send(holder.pid, :release)
      Task.await(holder, @wait_ms)
    end
  end

  test "a batch that reports one address twice records it once, answered", ctx do
    agent_id = "agent-duplicate-host-#{System.unique_integer([:positive])}"
    execution_id = Ash.UUID.generate()

    results = [
      %{"host_ip" => ctx.ip, "available" => false},
      %{"host_ip" => ctx.ip, "available" => true}
    ]

    assert {:ok, _stats} = ingest(ctx, agent_id, results, execution_id)

    assert %{rows: [["available"]]} =
             Repo.query!(
               "SELECT status FROM platform.sweep_host_results WHERE execution_id = $1::text::uuid",
               [execution_id]
             )
  end

  # Two ingests for one agent, each larger than one internal batch of 500 results, share their
  # hosts in the opposite batch order: `a` then `b` for one, `b` then `a` for the other. When
  # each batch locked its own availability rows before the next batch's, each ingest held one
  # half while it waited for the other's, and Postgres aborted one of them with a deadlock. An
  # ingest takes all its availability rows in one key order, so the second waits for the first.
  #
  # A third transaction holds the availability row each ingest has ahead of the shared hosts in
  # its second batch, so both have finished their first batch before either goes on.
  @tag timeout: 300_000
  test "two ingests sharing hosts in a different batch order both commit", ctx do
    agent_id = "agent-lock-order-#{System.unique_integer([:positive])}"

    ip_by_uid =
      Map.new(1..1_002, fn _ -> {"sr:#{Ash.UUID.generate()}", TestSupport.unique_device_ip()} end)

    ips = Map.values(ip_by_uid)
    on_exit(fn -> cleanup_devices!(ips) end)
    insert_devices!(ip_by_uid)

    [first_held, second_held | shared_uids] = ip_by_uid |> Map.keys() |> Enum.sort()
    {a, b} = shared_uids |> Enum.map(&ip_by_uid[&1]) |> Enum.split(500)
    held_uids = [first_held, second_held]

    # Only the held hosts have the agent's availability rows, so both ingests insert the shared
    # rows, as two concurrent first sightings do.
    assert {:ok, _stats} =
             ingest(ctx, agent_id, available_results(Enum.map(held_uids, &ip_by_uid[&1])))

    holder = hold_availability_rows(held_uids, agent_id)
    assert_receive {:availability_locked, holder_pid, holder_backend}, @wait_ms
    assert holder_pid == holder.pid

    first =
      start_ingest_transaction(ctx, agent_id,
        hold?: false,
        results: available_results(a ++ [ip_by_uid[first_held]] ++ b)
      )

    send(first.task.pid, :go)
    await_blocked!(first.backend, holder_backend, "INSERT INTO %device_agent_availability%")

    second =
      start_ingest_transaction(%{ctx | group: ctx.other_group}, agent_id,
        hold?: false,
        results: available_results(b ++ [ip_by_uid[second_held]] ++ a)
      )

    send(second.task.pid, :go)
    await_blocked!(second.backend, holder_backend, "INSERT INTO %device_agent_availability%")

    send(holder.pid, :release)
    Task.await(holder, @wait_ms)

    assert {:ok, {:ok, _stats}} = Task.await(first.task, @large_ingest_wait_ms)
    assert {:ok, {:ok, _stats}} = Task.await(second.task, @large_ingest_wait_ms)

    all_uids = Enum.sort(Map.keys(ip_by_uid))

    %{rows: rows} =
      Repo.query!(
        """
        SELECT device_uid FROM platform.device_agent_availability
        WHERE agent_id = $1 AND device_uid = ANY($2)
        """,
        [agent_id, all_uids]
      )

    assert rows |> List.flatten() |> Enum.sort() == all_uids
  end

  # The caller's transaction runs the whole ingest. `hold?` keeps it open after the ingest until
  # the test sends `:commit`; otherwise the ingest starts on `:go`. `results` defaults to one
  # answer from the test's address.
  defp start_ingest_transaction(ctx, agent_id, opts) do
    hold? = Keyword.fetch!(opts, :hold?)
    results = Keyword.get(opts, :results)
    parent = self()

    task =
      Task.async(fn ->
        # One pinned connection, so the backend reported is the one the transaction runs on.
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, self(), backend})
          if !hold?, do: receive(do: (:go -> :ok))

          try do
            Repo.transaction(fn ->
              result = ingest(ctx, agent_id, results)

              if hold? do
                send(parent, {:ingested, self()})
                receive(do: (:commit -> :ok))
              end

              result
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

  defp hold_availability_rows(uids, agent_id) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

        %{num_rows: locked} =
          Repo.query!(
            """
            SELECT 1 FROM platform.device_agent_availability
            WHERE device_uid = ANY($1) AND agent_id = $2
            ORDER BY device_uid
            FOR UPDATE
            """,
            [uids, agent_id]
          )

        if locked != length(uids), do: raise("locked #{locked} of #{length(uids)} rows")

        send(parent, {:availability_locked, self(), backend})
        receive(do: (:release -> :ok))
      end)
    end)
  end

  defp available_results(ips), do: Enum.map(ips, &%{"host_ip" => &1, "available" => true})

  defp insert_devices!(ip_by_uid) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices (uid, ip, partition)
      SELECT uid, ip, 'default' FROM unnest($1::text[], $2::text[]) AS seeded(uid, ip)
      """,
      [Map.keys(ip_by_uid), Map.values(ip_by_uid)]
    )
  end

  defp ingest(ctx, agent_id, results \\ nil, execution_id \\ Ash.UUID.generate()) do
    results = results || [%{"host_ip" => ctx.ip, "available" => true}]

    SweepResultsIngestor.ingest_results(results, execution_id,
      actor: ctx.actor,
      sweep_group_id: ctx.group.id,
      agent_id: agent_id,
      authenticated_agent_id: agent_id,
      authenticated_partition_id: "default"
    )
  end

  # Waits until backend `waiter` waits on backend `holder` in a statement LIKE `statement`, not
  # on anything taken earlier.
  defp await_blocked!(waiter, holder, statement, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @large_ingest_wait_ms

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

  defp device_rows(ip) do
    Repo.query!(
      "SELECT uid, deleted_at FROM platform.ocsf_devices WHERE ip = $1 AND partition = 'default'",
      [ip]
    ).rows
  end

  defp availability_agents(uid) do
    List.flatten(
      Repo.query!(
        "SELECT agent_id FROM platform.device_agent_availability WHERE device_uid = $1 ORDER BY agent_id",
        [uid]
      ).rows
    )
  end

  defp seed_uid(ip) do
    IdentityReconciler.generate_deterministic_device_id(%{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: nil,
      ip: ip,
      partition: "default"
    })
  end

  defp cleanup!(group_ids, ip) do
    group_ids = Enum.map(group_ids, &Ecto.UUID.dump!/1)

    executions =
      List.flatten(
        Repo.query!(
          "SELECT id FROM platform.sweep_group_executions WHERE sweep_group_id = ANY($1)",
          [group_ids]
        ).rows
      )

    Repo.query!("DELETE FROM platform.sweep_host_results WHERE execution_id = ANY($1)", [
      executions
    ])

    Repo.query!(
      "DELETE FROM platform.sweep_group_execution_versions WHERE version_source_id = ANY($1)",
      [executions]
    )

    Repo.query!("DELETE FROM platform.sweep_group_executions WHERE id = ANY($1)", [executions])

    Repo.query!("DELETE FROM platform.sweep_group_versions WHERE version_source_id = ANY($1)", [
      group_ids
    ])

    Repo.query!("DELETE FROM platform.sweep_groups WHERE id = ANY($1)", [group_ids])

    uids =
      List.flatten(Repo.query!("SELECT uid FROM platform.ocsf_devices WHERE ip = $1", [ip]).rows)

    Repo.query!("DELETE FROM platform.device_agent_availability WHERE device_uid = ANY($1)", [
      uids
    ])

    TestSupport.delete_device_fixtures!(uids)
    IdentityCache.delete(ip)
  end

  # The devices a test seeded at `ips`, with their host results and availability rows, whatever
  # order the `on_exit` callbacks run in.
  defp cleanup_devices!(ips) do
    uids =
      List.flatten(
        Repo.query!("SELECT uid FROM platform.ocsf_devices WHERE ip = ANY($1)", [ips]).rows
      )

    Repo.query!("DELETE FROM platform.sweep_host_results WHERE device_id = ANY($1)", [uids])

    Repo.query!("DELETE FROM platform.device_agent_availability WHERE device_uid = ANY($1)", [
      uids
    ])

    TestSupport.delete_device_fixtures!(uids)
    Enum.each(ips, &IdentityCache.delete/1)
  end
end
