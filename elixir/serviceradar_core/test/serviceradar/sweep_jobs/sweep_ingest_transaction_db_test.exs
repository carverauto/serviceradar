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
    await_blocked!(second.backend, first.backend)
    send(first.task.pid, :commit)

    assert {:ok, {:ok, _stats}} = Task.await(first.task, @wait_ms)
    assert {:ok, {:ok, _stats}} = Task.await(second.task, @wait_ms)

    assert [[uid, nil]] = device_rows(ctx.ip)
    assert uid == ctx.seed_uid
    assert availability_agents(uid) == Enum.sort([first_agent, second_agent])
  end

  # The caller's transaction runs the whole ingest. `hold?` keeps it open after the ingest until
  # the test sends `:commit`; otherwise the ingest starts on `:go`.
  defp start_ingest_transaction(ctx, agent_id, hold?: hold?) do
    parent = self()

    task =
      Task.async(fn ->
        # One pinned connection, so the backend reported is the one the transaction runs on.
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, self(), backend})
          if !hold?, do: receive(do: (:go -> :ok))

          Repo.transaction(fn ->
            result = ingest(ctx, agent_id)

            if hold? do
              send(parent, {:ingested, self()})
              receive(do: (:commit -> :ok))
            end

            result
          end)
        after
          Sandbox.checkin(Repo)
        end
      end)

    pid = task.pid
    assert_receive {:backend, ^pid, backend}, @wait_ms
    %{task: task, backend: backend}
  end

  defp ingest(ctx, agent_id) do
    results = [%{"host_ip" => ctx.ip, "available" => true}]

    SweepResultsIngestor.ingest_results(results, Ash.UUID.generate(),
      actor: ctx.actor,
      sweep_group_id: ctx.group.id,
      agent_id: agent_id,
      authenticated_agent_id: agent_id,
      authenticated_partition_id: "default"
    )
  end

  defp await_blocked!(waiter, holder, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @wait_ms

    # Waiting on the first transaction, in the device insert: not on anything taken earlier.
    %{rows: [[blocked]]} =
      Repo.query!(
        """
        SELECT $2::int = ANY(pg_blocking_pids($1::int))
          AND query LIKE 'INSERT INTO %ocsf_devices%'
        FROM pg_stat_activity
        WHERE pid = $1::int
        """,
        [waiter, holder]
      )

    if !blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "the second ingest never waited on the first one's uncommitted device"

      Process.sleep(10)
      await_blocked!(waiter, holder, deadline)
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
end
