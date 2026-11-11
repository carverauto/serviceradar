defmodule ServiceRadar.Camera.LocalStorageQualificationConcurrencyTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.LocalStorageQualification
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.LocalStorageFixtures, as: Fixtures

  @moduletag :integration
  @moduletag sandbox: :unboxed

  setup do
    storage_id = Ecto.UUID.generate()

    actor =
      Map.merge(SystemActor.system(:synthetic_storage_qualifier), %{
        nvr_storage_purpose: :qualify,
        nvr_storage_id: storage_id
      })

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "DELETE FROM platform.camera_local_storage_qualifications WHERE storage_id = $1",
          [
            Ecto.UUID.dump!(storage_id)
          ]
        )

        Repo.query!(
          "DELETE FROM platform.camera_local_storage_qualification_reports WHERE local_storage_binding_id IN (SELECT id FROM platform.camera_local_storage_bindings WHERE storage_id = $1)",
          [Ecto.UUID.dump!(storage_id)]
        )

        Repo.query!("DELETE FROM platform.camera_local_storage_bindings WHERE storage_id = $1", [
          Ecto.UUID.dump!(storage_id)
        ])

        assert %{rows: [[0]]} =
                 Repo.query!(
                   "SELECT (SELECT count(*) FROM platform.camera_local_storage_qualifications WHERE storage_id = $1) + (SELECT count(*) FROM platform.camera_local_storage_bindings WHERE storage_id = $1)",
                   [
                     Ecto.UUID.dump!(storage_id)
                   ]
                 )
      end)
    end)

    %{actor: actor, storage_id: storage_id}
  end

  test "a queued stale decision cannot overwrite a newer uncommitted decision", ctx do
    assert {:ok, _} = LocalStorageQualification.withdraw(1, "initial", actor: ctx.actor)
    parent = self()
    holder = hold_decision(ctx, 3, "newer")
    assert_receive {:holding, holder_backend}, 10_000

    contender =
      client(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:contending, backend})
        LocalStorageQualification.withdraw(2, "stale", actor: ctx.actor)
      end)

    assert_receive {:contending, contender_backend}, 10_000
    assert blocked_by?(contender_backend, holder_backend)
    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, 10_000)
    assert {:error, error} = Task.await(contender, 10_000)
    assert Exception.message(error) =~ "decision_conflict"
    assert {:ok, retained} = Ash.get(LocalStorageQualification, ctx.storage_id, actor: ctx.actor)
    assert retained.revision == 3
    assert retained.reason == "newer"
  end

  test "activation that waits past health expiry rolls back after obtaining the row lock", ctx do
    evidence = Fixtures.context(ctx.storage_id)
    {report, health, actor} = Fixtures.current_evidence(evidence)
    actor = put_in(actor.nvr_storage_policy.max_health_age_ms, 10_000)
    health = Map.put(health, "observed_at_ms", System.system_time(:millisecond))
    assert {:ok, _} = LocalStorageQualification.withdraw(1, "initial", actor: actor)
    parent = self()
    holder = hold_decision(ctx, 2, "maintenance")
    assert_receive {:holding, holder_backend}, 10_000

    contender =
      client(fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:contending, backend})
        LocalStorageQualification.activate(3, report.id, health, actor: actor)
      end)

    assert_receive {:contending, contender_backend}, 10_000
    assert blocked_by?(contender_backend, holder_backend)
    deadline = health["observed_at_ms"] + actor.nvr_storage_policy.max_health_age_ms
    Process.sleep(max(0, deadline - System.system_time(:millisecond) + 1))
    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, 10_000)
    assert {:error, error} = Task.await(contender, 10_000)
    assert Exception.message(error) =~ "health_expired"
    assert {:ok, retained} = Ash.get(LocalStorageQualification, ctx.storage_id, actor: actor)
    assert retained.revision == 2
    assert retained.state == :withdrawn
    assert retained.reason == "maintenance"

    assert {:ok, historical} =
             Ash.get(ServiceRadar.Camera.LocalStorageQualificationReport, report.id, actor: actor)

    assert historical.report == report.report
  end

  defp hold_decision(ctx, revision, reason) do
    parent = self()

    client(fn ->
      Repo.transaction(fn ->
        assert {:ok, _} = LocalStorageQualification.withdraw(revision, reason, actor: ctx.actor)
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:holding, backend})

        receive do
          :release -> :released
        after
          20_000 -> flunk("decision lock was not released")
        end
      end)
    end)
  end

  defp client(fun) do
    task = Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
    on_exit(fn -> Process.exit(task.pid, :kill) end)
    task
  end

  defp blocked_by?(backend, holder, attempts \\ 500) do
    case Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [backend, holder]).rows do
      [[true]] ->
        true

      _ when attempts > 0 ->
        Process.sleep(10)
        blocked_by?(backend, holder, attempts - 1)

      _ ->
        false
    end
  end
end
