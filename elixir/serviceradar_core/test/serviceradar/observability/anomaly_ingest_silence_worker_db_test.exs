defmodule ServiceRadar.Observability.AnomalyIngestSilenceWorkerDBTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Observability.AnomalyIngestSilenceWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  # Anchored far in the future so pre-existing rows in a shared scratch DB can
  # never fall inside the probe windows and flake the verdicts.
  @now DateTime.add(DateTime.utc_now(), 3650 * 86_400, :second)

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    unique = System.unique_integer([:positive])
    series_key = "test-anomaly-silence-#{unique}"

    delete_rows!(series_key)

    {:ok, series_key: series_key}
  end

  test "fires only when metric ingest is alive and anomaly ingest is silent", %{
    series_key: series_key
  } do
    test_pid = self()

    health = fn check, healthy?, metadata ->
      send(test_pid, {:health, check, healthy?, metadata})
      :ok
    end

    # No rows in either window: metric ingest dead -> stays quiet.
    assert :ok = AnomalyIngestSilenceWorker.run(now: @now, health_recorder: health)
    refute_received {:health, _check, _healthy?, _metadata}

    # Metric ingest alive, no anomaly-detection findings, no live episode,
    # no add-on heartbeat -> fires.
    insert_metric!(series_key, DateTime.add(@now, -600, :second))
    assert :ok = AnomalyIngestSilenceWorker.run(now: @now, health_recorder: health)
    assert_received {:health, "anomaly-ingest-silence", false, _metadata}

    # A 2004 row WITHOUT the anomaly-detection source_type does not count.
    insert_finding!(DateTime.add(@now, -300, :second), %{
      "service_radar" => %{"series_key" => series_key}
    })

    assert :ok = AnomalyIngestSilenceWorker.run(now: @now, health_recorder: health)
    assert_received {:health, "anomaly-ingest-silence", false, _metadata}

    # An open episode seen inside the window proves a live pipeline -> healthy.
    insert_episode!(series_key, "open", DateTime.add(@now, -900, :second))
    assert :ok = AnomalyIngestSilenceWorker.run(now: @now, health_recorder: health)
    assert_received {:health, "anomaly-ingest-silence", true, _metadata}

    # A stale-closed episode does not count -> fires again.
    close_episode!(series_key)
    assert :ok = AnomalyIngestSilenceWorker.run(now: @now, health_recorder: health)
    assert_received {:health, "anomaly-ingest-silence", false, _metadata}

    # A fresh running anomaly add-on heartbeat = healthy quiet fleet.
    insert_addon_status!(series_key, "running", DateTime.add(@now, -300, :second))
    assert :ok = AnomalyIngestSilenceWorker.run(now: @now, health_recorder: health)
    assert_received {:health, "anomaly-ingest-silence", true, _metadata}

    # A stale heartbeat (older than the freshness bound) does not count.
    set_addon_health!(series_key, DateTime.add(@now, -3600, :second))
    assert :ok = AnomalyIngestSilenceWorker.run(now: @now, health_recorder: health)
    assert_received {:health, "anomaly-ingest-silence", false, _metadata}

    # A real anomaly-detection finding inside the window -> healthy.
    insert_finding!(DateTime.add(@now, -300, :second), %{
      "service_radar" => %{
        "series_key" => series_key,
        "source_type" => "anomaly_detection"
      }
    })

    assert :ok = AnomalyIngestSilenceWorker.run(now: @now, health_recorder: health)
    assert_received {:health, "anomaly-ingest-silence", true, _metadata}
  end

  defp insert_metric!(series_key, timestamp) do
    Repo.query!(
      """
      INSERT INTO platform.timeseries_metrics (
        "timestamp", gateway_id, metric_name, metric_type, value, series_key
      ) VALUES ($1, 'test-gateway', 'cpu.usage_percent', 'gauge', 1.0, $2)
      """,
      [timestamp, series_key]
    )
  end

  defp insert_finding!(time, metadata) do
    Repo.query!(
      """
      INSERT INTO platform.ocsf_events (
        id, time, class_uid, category_uid, type_uid, activity_id, metadata, log_provider
      ) VALUES (gen_random_uuid(), $1, 2004, 2, 200401, 1, $2, $3)
      """,
      [time, metadata, "test-anomaly-silence"]
    )
  end

  defp insert_episode!(series_key, status, last_seen_at) do
    Repo.query!(
      """
      INSERT INTO platform.anomaly_episodes (
        episode_uid, finding_uid, device_uid, series_key, detector,
        status, opened_at, last_seen_at
      ) VALUES ($1, $1, 'sr:test-anomaly-silence-device', $1, 'drift', $2, $3, $3)
      """,
      [series_key, status, DateTime.to_naive(last_seen_at)]
    )
  end

  defp close_episode!(series_key) do
    Repo.query!(
      "UPDATE platform.anomaly_episodes SET status = 'stale_closed', cleared_at = now(), clear_reason = 'stale' WHERE episode_uid = $1",
      [series_key]
    )
  end

  defp insert_addon_status!(series_key, state, last_health_at) do
    Repo.query!(
      """
      INSERT INTO platform.addon_statuses (
        agent_uid, addon_id, state, last_health_at, reported_at
      ) VALUES ($1, 'anomaly', $2, $3, $3)
      """,
      [series_key, state, last_health_at]
    )
  end

  defp set_addon_health!(series_key, last_health_at) do
    Repo.query!(
      "UPDATE platform.addon_statuses SET last_health_at = $2 WHERE agent_uid = $1",
      [series_key, last_health_at]
    )
  end

  defp delete_rows!(series_key) do
    Repo.query!("DELETE FROM platform.timeseries_metrics WHERE series_key = $1", [series_key])

    Repo.query!(
      """
      DELETE FROM platform.ocsf_events
      WHERE metadata #>> '{service_radar,series_key}' = $1
      """,
      [series_key]
    )

    Repo.query!("DELETE FROM platform.anomaly_episodes WHERE episode_uid = $1", [series_key])
    Repo.query!("DELETE FROM platform.addon_statuses WHERE agent_uid = $1", [series_key])
  end
end
