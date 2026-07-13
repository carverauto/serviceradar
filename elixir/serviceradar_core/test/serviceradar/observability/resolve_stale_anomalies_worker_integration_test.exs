defmodule ServiceRadar.Observability.ResolveStaleAnomaliesWorkerIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Observability.AnomalyEpisode
  alias ServiceRadar.Observability.ResolveStaleAnomaliesWorker
  alias ServiceRadar.Observability.StatefulAlertEngine
  alias ServiceRadar.Observability.StatefulAlertRule
  alias ServiceRadar.Repo

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = %{id: "system", role: :admin}
    reset_engine()
    on_exit(&reset_engine/0)
    {:ok, actor: actor}
  end

  test "stale sweep keeps alerts whose episode is still open and resolves the rest", %{
    actor: actor
  } do
    unique = System.unique_integer([:positive])
    device_uid = "sr:episode-liveness-device-#{unique}"
    live_series_key = "sysmon:cpu:#{device_uid}:0"
    dead_series_key = "sysmon:memory:#{device_uid}:0"
    alert_title = "Episode liveness #{unique}"
    rule_name = "episode-liveness-rule-#{unique}"

    create_rule!(rule_name, alert_title, actor)

    base_time = DateTime.utc_now()

    # Open one alert per series; neither ever receives an anomaly_clear.
    assert :ok =
             StatefulAlertEngine.evaluate_events([
               anomaly_event(device_uid, live_series_key, base_time, 0),
               anomaly_event(device_uid, dead_series_key, base_time, 10)
             ])

    assert [_alert1, _alert2] = active_alerts_by_title(actor, alert_title)

    # Only the live series has an open episode heartbeating `last_seen_at`.
    upsert_episode!(device_uid, live_series_key, "open", base_time)

    now = DateTime.add(base_time, 3600, :second)
    cutoff = now

    live_series_keys = ResolveStaleAnomaliesWorker.live_episode_series_keys(now, Repo)
    assert MapSet.member?(live_series_keys, live_series_key)
    refute MapSet.member?(live_series_keys, dead_series_key)

    # The episode-less alert resolves; the live-episode alert is kept.
    assert {:ok, 1} =
             StatefulAlertEngine.resolve_stale_anomalies(rule_name, cutoff, now, live_series_keys)

    assert [kept] = active_alerts_by_title(actor, alert_title)
    assert kept.metadata["incident_group_values"]["anomaly.series_key"] == live_series_key

    # Once the episode clears, the next sweep resolves the remaining alert.
    upsert_episode!(device_uid, live_series_key, "cleared", base_time)

    live_series_keys = ResolveStaleAnomaliesWorker.live_episode_series_keys(now, Repo)
    refute MapSet.member?(live_series_keys, live_series_key)

    assert {:ok, 1} =
             StatefulAlertEngine.resolve_stale_anomalies(rule_name, cutoff, now, live_series_keys)

    assert [] = active_alerts_by_title(actor, alert_title)
  end

  test "live_episode_series_keys returns only open episodes within the freshness window" do
    unique = System.unique_integer([:positive])
    device_uid = "sr:episode-window-device-#{unique}"
    fresh_key = "sysmon:cpu:#{device_uid}:0"
    stale_key = "sysmon:memory:#{device_uid}:0"
    cleared_key = "sysmon:disk:#{device_uid}:0"

    now = DateTime.utc_now()

    upsert_episode!(device_uid, fresh_key, "open", now)
    upsert_episode!(device_uid, stale_key, "open", DateTime.add(now, -8 * 3600, :second))
    upsert_episode!(device_uid, cleared_key, "cleared", now)

    live_series_keys = ResolveStaleAnomaliesWorker.live_episode_series_keys(now, Repo)

    assert MapSet.member?(live_series_keys, fresh_key)
    refute MapSet.member?(live_series_keys, stale_key)
    refute MapSet.member?(live_series_keys, cleared_key)
  end

  defp create_rule!(rule_name, alert_title, actor) do
    StatefulAlertRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: rule_name,
        enabled: true,
        signal: :event,
        match: %{
          "subject_prefix" => "signals.analytics.predictions",
          "attribute_equals" => %{
            "signal_type" => "prediction",
            "event_type" => "anomaly",
            "anomaly.state" => ["anomaly_open", "open"]
          },
          "recovery" => %{
            "subject_prefix" => "signals.analytics.predictions",
            "attribute_equals" => %{
              "signal_type" => "prediction",
              "event_type" => "anomaly",
              "anomaly.state" => ["anomaly_clear", "inactive"]
            }
          }
        },
        group_by: ["device", "anomaly.series_key"],
        threshold: 1,
        window_seconds: 300,
        bucket_seconds: 60,
        cooldown_seconds: 300,
        renotify_seconds: 3600,
        event: %{
          "log_name" => "alert.health.anomaly_detection",
          "message" => "Anomaly detection finding detected"
        },
        alert: %{"title" => alert_title, "severity_from" => "source"}
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp anomaly_event(device_uid, series_key, base_time, offset) do
    %{
      id: Ash.UUID.generate(),
      time: DateTime.add(base_time, offset, :second),
      severity_id: OCSF.severity_high(),
      severity: OCSF.severity_name(OCSF.severity_high()),
      message: "Anomaly anomaly_open",
      log_name: "signals.analytics.predictions.#{series_key}",
      log_provider: "anomaly_detection",
      device: %{"uid" => device_uid},
      unmapped: %{
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "anomaly" => %{
          "state" => "anomaly_open",
          "series_key" => series_key,
          "metric_class" => "sysmon.cpu"
        }
      },
      metadata: %{"signal_type" => "prediction", "event_type" => "anomaly"}
    }
  end

  defp upsert_episode!(device_uid, series_key, status, last_seen_at) do
    AnomalyEpisode.upsert_episode!(
      %{
        episode_uid: "episode-#{series_key}",
        finding_uid: "finding-#{series_key}",
        device_uid: device_uid,
        series_key: series_key,
        detector: "spike",
        status: status,
        opened_at: DateTime.add(last_seen_at, -600, :second),
        last_seen_at: last_seen_at,
        cleared_at: if(status == "cleared", do: last_seen_at),
        clear_reason: if(status == "cleared", do: "clear")
      },
      actor: SystemActor.system(:test_support)
    )
  end

  defp active_alerts_by_title(actor, title) do
    Alert
    |> Ash.Query.for_read(:active, %{}, actor: actor)
    |> Ash.read!()
    |> ServiceRadar.Ash.Page.unwrap!()
    |> Enum.filter(fn alert -> alert.title == title end)
  end

  defp reset_engine do
    ServiceRadar.TestSupport.drain_stateful_alert_engines()
  end
end
