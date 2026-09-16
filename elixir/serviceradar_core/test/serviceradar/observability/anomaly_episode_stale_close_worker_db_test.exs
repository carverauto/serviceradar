defmodule ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorkerDBTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.AnomalyDetectionConfig
  alias ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_module = Application.get_env(:serviceradar_core, AnomalyEpisodeStaleCloseWorker)

    previous_global =
      Application.get_env(:serviceradar_core, :anomaly_episode_stale_after_minutes)

    Application.delete_env(:serviceradar_core, :anomaly_episode_stale_after_minutes)

    Application.put_env(:serviceradar_core, AnomalyEpisodeStaleCloseWorker,
      settings_fetcher: fn ->
        {:ok, %AnomalyDetectionConfig{emission: %{"episode_update_interval_secs" => 1_800}}}
      end
    )

    on_exit(fn ->
      restore_env(AnomalyEpisodeStaleCloseWorker, previous_module)
      restore_env(:anomaly_episode_stale_after_minutes, previous_global)
    end)
  end

  test "perform closes only open episodes silent beyond the derived heartbeat margin" do
    unique = System.unique_integer([:positive])
    live_uid = "test-episode-stale-live-#{unique}"
    stale_uid = "test-episode-stale-dead-#{unique}"
    central_live_uid = "test-episode-stale-central-live-#{unique}"
    central_stale_uid = "test-episode-stale-central-dead-#{unique}"
    uids = [live_uid, stale_uid, central_live_uid, central_stale_uid]

    on_exit(fn -> delete_episodes!(uids) end)
    delete_episodes!(uids)

    now = DateTime.utc_now()

    # Margin is 2 * 1800s heartbeat = 3600s; one late heartbeat stays open.
    insert_open_episode!(live_uid, DateTime.add(now, -3_000, :second))
    insert_open_episode!(stale_uid, DateTime.add(now, -4_200, :second))

    # Central seasonal episodes are refreshed hourly by cron, so the edge margin
    # (60 min) closed every one of them before its next evaluation. They get a
    # 150 min window instead: 70 min silent stays open, 166 min silent closes.
    insert_open_episode!(central_live_uid, DateTime.add(now, -4_200, :second), "central_seasonal")

    insert_open_episode!(
      central_stale_uid,
      DateTime.add(now, -9_960, :second),
      "central_seasonal"
    )

    assert :ok = AnomalyEpisodeStaleCloseWorker.perform(%Oban.Job{})

    assert [["open", nil]] = episode_status(live_uid)
    assert [["stale_closed", "stale"]] = episode_status(stale_uid)
    assert [["open", nil]] = episode_status(central_live_uid)
    assert [["stale_closed", "stale"]] = episode_status(central_stale_uid)
  end

  defp insert_open_episode!(episode_uid, last_seen_at, detector \\ "drift") do
    Repo.query!(
      """
      INSERT INTO platform.anomaly_episodes (
        episode_uid, finding_uid, device_uid, series_key, detector,
        status, opened_at, last_seen_at
      ) VALUES ($1, $1, 'sr:test-stale-close-device', $1, $3, 'open', $2, $2)
      """,
      [episode_uid, last_seen_at, detector]
    )
  end

  defp episode_status(episode_uid) do
    Repo.query!(
      "SELECT status, clear_reason FROM platform.anomaly_episodes WHERE episode_uid = $1",
      [episode_uid]
    ).rows
  end

  defp delete_episodes!(episode_uids) do
    Repo.query!("DELETE FROM platform.anomaly_episodes WHERE episode_uid = ANY($1)", [
      episode_uids
    ])
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
