defmodule ServiceRadar.Observability.NetflowDatasetRefreshWorkerTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.NetflowOuiDatasetRefreshWorker
  alias ServiceRadar.Observability.NetflowProviderDatasetRefreshWorker
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

      assert :ok = NetflowProviderDatasetRefreshWorker.perform(%Oban.Job{args: %{}})
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

      assert :ok = NetflowOuiDatasetRefreshWorker.perform(%Oban.Job{args: %{}})
    end
  end

  defp assert_expected_schedule_result(result) do
    if ObanSupport.available?() do
      assert match?({:ok, :already_scheduled}, result) or
               match?({:ok, %Oban.Job{}}, result)
    else
      assert {:error, :oban_unavailable} = result
    end
  end
end
