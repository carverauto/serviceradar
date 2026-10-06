defmodule ServiceRadar.Observability.AdvisoryLocksTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.AdvisoryLocks
  alias ServiceRadar.Repo

  @moduletag sandbox: :unboxed

  test "blocking acquisition preserves order and modes until transaction completion" do
    parent = self()
    prefix = "ordered-lock-#{System.unique_integer([:positive])}"
    first = prefix <> "-first"
    second = prefix <> "-second"

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [first])
          send(parent, :first_held)
          await_release!()
        end)
      end)

    on_exit(fn -> stop_task(holder) end)
    assert_receive :first_held, 5_000

    waiter =
      Task.async(fn ->
        Repo.transaction(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {:waiter_backend, pid})
          assert :ok = AdvisoryLocks.acquire_ordered([{:shared, first}, {:exclusive, second}])
          send(parent, :sequence_acquired)
          await_release!()
        end)
      end)

    on_exit(fn -> stop_task(waiter) end)
    assert_receive {:waiter_backend, backend}, 5_000
    await_blocked!(backend, System.monotonic_time(:millisecond) + 5_000)

    # Once the first acquisition is waiting in PostgreSQL, the later lock must
    # still be available. Rollback releases the probe before the waiter resumes.
    assert {:error, :probe_complete} =
             Repo.transaction(fn ->
               assert :ok = AdvisoryLocks.try_acquire_ordered([second])
               Repo.rollback(:probe_complete)
             end)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert_receive :sequence_acquired, 5_000

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert :ok = AdvisoryLocks.acquire_ordered!([{:shared, first}])

               assert {:error, {:advisory_locks_busy, [^first, ^second]}} =
                        AdvisoryLocks.try_acquire_ordered([first, second])

               :ok
             end)

    send(waiter.pid, :release)
    assert {:ok, :ok} = Task.await(waiter, 5_000)

    assert {:ok, :ok} =
             Repo.transaction(fn -> AdvisoryLocks.try_acquire_ordered([first, second]) end)
  end

  defp await_blocked!(backend, deadline) do
    [[blocked]] =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = $1 AND locktype = 'advisory' AND NOT granted)",
        [backend]
      ).rows

    cond do
      blocked ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("waiter never reached the first lock")

      true ->
        Process.sleep(10)
        await_blocked!(backend, deadline)
    end
  end

  defp await_release! do
    receive do
      :release -> :ok
    after
      10_000 -> flunk("lock holder was not released")
    end
  end

  defp stop_task(task) do
    if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
  end
end
