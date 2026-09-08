defmodule ServiceRadar.Observability.NetflowDatasetRefreshWorkerTest do
  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Oban.Job
  alias ServiceRadar.Observability.NetflowOuiDatasetRefreshWorker
  alias ServiceRadar.Observability.NetflowProviderDatasetRefreshWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  describe "ensure_scheduled/0" do
    test "provider worker reports unavailable or schedules against the running Oban instance" do
      assert_expected_schedule_result(NetflowProviderDatasetRefreshWorker.ensure_scheduled())
    end

    test "oui worker reports unavailable or schedules against the running Oban instance" do
      assert_expected_schedule_result(NetflowOuiDatasetRefreshWorker.ensure_scheduled())
    end
  end

  describe "perform/1 failure path" do
    test "provider worker handles unreachable source and returns :ok" do
      Application.put_env(
        :serviceradar_core,
        NetflowProviderDatasetRefreshWorker,
        source_url: "https://127.0.0.1/provider.json",
        timeout_ms: 50,
        failure_reschedule_seconds: 60,
        reschedule_seconds: 60
      )

      on_exit(fn ->
        Application.delete_env(:serviceradar_core, NetflowProviderDatasetRefreshWorker)
      end)

      assert :ok = NetflowProviderDatasetRefreshWorker.perform(%Job{args: %{}})
    end

    test "oui worker handles unreachable source and returns :ok" do
      Application.put_env(
        :serviceradar_core,
        NetflowOuiDatasetRefreshWorker,
        source_url: "https://127.0.0.1/oui.csv",
        timeout_ms: 50,
        failure_reschedule_seconds: 60,
        reschedule_seconds: 60
      )

      on_exit(fn ->
        Application.delete_env(:serviceradar_core, NetflowOuiDatasetRefreshWorker)
      end)

      assert :ok = NetflowOuiDatasetRefreshWorker.perform(%Job{args: %{}})
    end
  end

  describe "periodic successor scheduling" do
    test "both workers queue their delayed successor while the current job is executing" do
      if ObanSupport.available?() do
        Enum.each(
          [NetflowProviderDatasetRefreshWorker, NetflowOuiDatasetRefreshWorker],
          &assert_queues_successor_while_executing/1
        )
      else
        assert true
      end
    end
  end

  defp assert_expected_schedule_result(result) do
    if ObanSupport.available?() do
      assert match?({:ok, :already_scheduled}, result) or
               match?({:ok, %Job{}}, result)
    else
      assert {:error, :oban_unavailable} = result
    end
  end

  defp assert_queues_successor_while_executing(worker) do
    delete_worker_jobs(worker)
    executing = insert_executing_job!(worker)
    previous_worker_env = Application.get_env(:serviceradar_core, worker)
    previous_cluster_enabled = Application.get_env(:serviceradar_core, :cluster_enabled)

    Application.put_env(:serviceradar_core, :cluster_enabled, false)

    Application.put_env(:serviceradar_core, worker,
      source_url: "https://fixtures.invalid/dataset",
      validate_url: fn _url -> :ok end,
      http_get: fn _url, _opts -> {:error, :fixture_unavailable} end,
      failure_reschedule_seconds: 7_200,
      reschedule_seconds: 7_200
    )

    try do
      assert :ok = worker.perform(%{executing | args: %{}})

      worker_jobs =
        Repo.all(
          from(job in Job,
            where: job.worker == ^inspect(worker),
            order_by: [asc: job.id]
          )
        )

      successor = Enum.find(worker_jobs, &(&1.id != executing.id and &1.state == "scheduled"))

      assert successor,
             "expected #{inspect(worker)} to queue a scheduled successor, got: #{inspect(Enum.map(worker_jobs, &{&1.id, &1.state, &1.conflict?}))}"

      refute successor.conflict?
      assert DateTime.after?(successor.scheduled_at, DateTime.utc_now())
    after
      restore_env(worker, previous_worker_env)
      restore_env(:cluster_enabled, previous_cluster_enabled)
      delete_worker_jobs(worker)
    end
  end

  defp insert_executing_job!(worker) do
    now = DateTime.utc_now()

    %{}
    |> Job.new(worker: worker, queue: :maintenance)
    |> Ecto.Changeset.change(
      state: "executing",
      attempt: 1,
      max_attempts: 3,
      attempted_at: now,
      inserted_at: now,
      scheduled_at: now
    )
    |> Repo.insert!()
  end

  defp delete_worker_jobs(worker) do
    Repo.delete_all(from(job in Job, where: job.worker == ^inspect(worker)))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
