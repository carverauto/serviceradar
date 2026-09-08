defmodule ServiceRadar.SweepJobs.ObanSupportTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.ObanSupport

  test "available?/0 returns a boolean for the current process" do
    assert is_boolean(ObanSupport.available?())
  end

  test "safe_insert returns oban_unavailable when availability check fails" do
    assert {:error, :oban_unavailable} =
             ObanSupport.safe_insert(%Ecto.Changeset{}, available_fun: fn -> false end)
  end

  test "safe_insert retries after recovering a stale executing conflict" do
    Process.put(:test_pid, self())

    original_job = %Ecto.Changeset{}
    retried_job = %Oban.Job{id: 456, state: "available"}
    conflict_job = stale_conflict_job(123)

    Process.put(:insert_results, [
      {:ok, conflict_job},
      {:ok, retried_job}
    ])

    recover_fun = fn job, now, cutoff_seconds ->
      send(self(), {:recover_stale_conflict, job, now, cutoff_seconds})
      {1, nil}
    end

    assert {:ok, ^retried_job} =
             ObanSupport.safe_insert(original_job,
               available_fun: fn -> true end,
               insert_fun: &fake_insert/1,
               recover_stale_conflict_fun: recover_fun,
               now_fun: fn -> ~U[2026-07-06 17:00:00Z] end,
               stale_conflict_cutoff_seconds: 120
             )

    assert_received {:insert, ^original_job}
    assert_received {:insert, ^original_job}

    assert_received {:recover_stale_conflict, ^conflict_job, ~U[2026-07-06 17:00:00Z], 120}
  after
    Process.delete(:insert_results)
    Process.delete(:test_pid)
  end

  test "safe_insert reports a stale executing conflict when it cannot be recovered" do
    Process.put(:test_pid, self())

    original_job = %Ecto.Changeset{}
    conflict_job = stale_conflict_job(789)
    Process.put(:insert_results, [{:ok, conflict_job}])

    recover_fun = fn job, now, cutoff_seconds ->
      send(self(), {:recover_stale_conflict, job, now, cutoff_seconds})
      {0, nil}
    end

    assert {:error, {:stale_oban_job_conflict, 789}} =
             ObanSupport.safe_insert(original_job,
               available_fun: fn -> true end,
               insert_fun: &fake_insert/1,
               recover_stale_conflict_fun: recover_fun,
               now_fun: fn -> ~U[2026-07-06 17:00:00Z] end,
               stale_conflict_cutoff_seconds: 120
             )

    assert_received {:insert, ^original_job}
    refute_received {:insert, ^original_job}
    assert_received {:recover_stale_conflict, ^conflict_job, ~U[2026-07-06 17:00:00Z], 120}
  after
    Process.delete(:insert_results)
    Process.delete(:test_pid)
  end

  test "safe_insert leaves a fresh executing conflict unchanged" do
    Process.put(:test_pid, self())

    original_job = %Ecto.Changeset{}

    conflict_job =
      321
      |> stale_conflict_job()
      |> Map.put(:attempted_at, ~N[2026-07-06 16:59:30])

    Process.put(:insert_results, [{:ok, conflict_job}])

    recover_fun = fn job, now, cutoff_seconds ->
      send(self(), {:recover_stale_conflict, job, now, cutoff_seconds})
      {1, nil}
    end

    assert {:ok, ^conflict_job} =
             ObanSupport.safe_insert(original_job,
               available_fun: fn -> true end,
               insert_fun: &fake_insert/1,
               recover_stale_conflict_fun: recover_fun,
               now_fun: fn -> ~U[2026-07-06 17:00:00Z] end,
               stale_conflict_cutoff_seconds: 120
             )

    assert_received {:insert, ^original_job}
    refute_received {:recover_stale_conflict, _, _, _}
  after
    Process.delete(:insert_results)
    Process.delete(:test_pid)
  end

  defp fake_insert(job) do
    send(Process.get(:test_pid), {:insert, job})

    case Process.get(:insert_results) do
      [result | remaining] ->
        Process.put(:insert_results, remaining)
        result

      _ ->
        {:ok, job}
    end
  end

  defp stale_conflict_job(id) do
    %Oban.Job{
      id: id,
      worker: "ServiceRadar.TestWorker",
      queue: "maintenance",
      state: "executing",
      conflict?: true,
      attempt: 1,
      max_attempts: 3,
      attempted_at: ~N[2026-07-06 16:30:00]
    }
  end
end
