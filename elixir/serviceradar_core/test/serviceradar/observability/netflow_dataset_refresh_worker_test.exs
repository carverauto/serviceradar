defmodule ServiceRadar.Observability.NetflowDatasetRefreshWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.{
    NetflowOuiDatasetRefreshWorker,
    NetflowProviderDatasetRefreshWorker
  }

  describe "ensure_scheduled/0" do
    test "provider worker returns oban_unavailable when Oban is not running" do
      assert {:error, :oban_unavailable} = NetflowProviderDatasetRefreshWorker.ensure_scheduled()
    end

    test "oui worker returns oban_unavailable when Oban is not running" do
      assert {:error, :oban_unavailable} = NetflowOuiDatasetRefreshWorker.ensure_scheduled()
    end
  end

  describe "perform/1 failure path" do
    test "provider worker handles unreachable source and returns :ok" do
      Application.put_env(
        :serviceradar_core,
        NetflowProviderDatasetRefreshWorker,
        source_url: "http://127.0.0.1:9/provider.json",
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
        source_url: "http://127.0.0.1:9/oui.csv",
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
end
