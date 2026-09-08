defmodule ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.AnomalyDetectionConfig
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

  test "stale window derives two heartbeats from emission settings with a 30 minute floor" do
    Application.delete_env(:serviceradar_core, :anomaly_episode_stale_after_minutes)

    put_settings_fetcher(emission_fetcher(1_800))
    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 3_600

    put_settings_fetcher(emission_fetcher(3_600))
    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 7_200

    put_settings_fetcher(emission_fetcher(300))
    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 1_800

    put_settings_fetcher(emission_fetcher("900"))
    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 1_800
  end

  test "stale window falls back to the default heartbeat when settings are unavailable" do
    Application.delete_env(:serviceradar_core, :anomaly_episode_stale_after_minutes)

    # The fallback heartbeat is the emission default, not a duplicated constant.
    assert AnomalyDetectionConfig.default_episode_update_interval_secs() == 1_800

    put_settings_fetcher(fn -> {:error, :database_unavailable} end)
    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 3_600

    put_settings_fetcher(fn -> raise "settings fetch boom" end)
    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 3_600

    put_settings_fetcher(emission_fetcher(nil))
    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 3_600
  end

  test "explicit stale window configuration wins over the derived margin" do
    Application.delete_env(:serviceradar_core, AnomalyEpisodeStaleCloseWorker)
    Application.put_env(:serviceradar_core, :anomaly_episode_stale_after_minutes, 12)

    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 720

    Application.put_env(:serviceradar_core, AnomalyEpisodeStaleCloseWorker,
      stale_after_minutes: 45,
      settings_fetcher: emission_fetcher(86_400)
    )

    assert AnomalyEpisodeStaleCloseWorker.stale_after_seconds() == 2_700
  end

  defp put_settings_fetcher(fun) do
    Application.put_env(:serviceradar_core, AnomalyEpisodeStaleCloseWorker, settings_fetcher: fun)
  end

  defp emission_fetcher(heartbeat_secs) do
    fn ->
      {:ok,
       %AnomalyDetectionConfig{emission: %{"episode_update_interval_secs" => heartbeat_secs}}}
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
