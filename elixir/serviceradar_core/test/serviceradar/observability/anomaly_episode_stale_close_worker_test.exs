defmodule ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorker

  defmodule RepoStub do
    @moduledoc false

    def query(sql, params) do
      send(Process.get(:stale_close_test_pid), {:stale_close_query, sql, params})
      {:ok, %{num_rows: 3}}
    end
  end

  setup do
    previous_module = Application.get_env(:serviceradar_core, AnomalyEpisodeStaleCloseWorker)

    previous_global =
      Application.get_env(:serviceradar_core, :anomaly_episode_stale_after_minutes)

    Process.put(:stale_close_test_pid, self())

    on_exit(fn ->
      Process.delete(:stale_close_test_pid)
      restore_env(AnomalyEpisodeStaleCloseWorker, previous_module)
      restore_env(:anomaly_episode_stale_after_minutes, previous_global)
    end)
  end

  test "close_stale marks open rows as stale closed" do
    cutoff = ~N[2026-07-04 11:30:00.000000]
    now = ~N[2026-07-04 12:00:00.000000]

    assert {:ok, 3} = AnomalyEpisodeStaleCloseWorker.close_stale(cutoff, now, RepoStub)

    assert_receive {:stale_close_query, sql, [^cutoff, ^now]}
    assert sql =~ "status = 'stale_closed'"
    assert sql =~ "clear_reason = 'stale'"
    assert sql =~ "WHERE status = 'open'"
  end

  test "stale window defaults to 30 minutes and can be configured" do
    Application.delete_env(:serviceradar_core, AnomalyEpisodeStaleCloseWorker)
    Application.delete_env(:serviceradar_core, :anomaly_episode_stale_after_minutes)

    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 1_800

    Application.put_env(:serviceradar_core, :anomaly_episode_stale_after_minutes, 12)
    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 720

    Application.put_env(:serviceradar_core, AnomalyEpisodeStaleCloseWorker,
      stale_after_minutes: 45
    )

    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 2_700
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
