defmodule ServiceRadar.EventWriter.Processors.AnalyticsSignalsProcessBatchDBTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistry
  alias ServiceRadar.Observability.AnomalyEpisodeStaleCloseWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  defmodule AlertQueue do
    @moduledoc false

    def enqueue_events(events) do
      send(self(), {:alert_evaluation_events, events})
      :ok
    end
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_queue = Application.get_env(:serviceradar_core, :stateful_alert_evaluation_queue)
    previous_episodes = Application.get_env(:serviceradar_core, :anomaly_episodes_enabled)

    previous_stale_after =
      Application.get_env(:serviceradar_core, :anomaly_episode_stale_after_minutes)

    previous_rate_limit =
      Application.get_env(:serviceradar_core, :anomaly_episode_rate_limit_per_hour)

    Application.put_env(
      :serviceradar_core,
      :stateful_alert_evaluation_queue,
      __MODULE__.AlertQueue
    )

    Application.put_env(:serviceradar_core, :anomaly_episodes_enabled, true)
    Application.put_env(:serviceradar_core, :anomaly_episode_stale_after_minutes, 30)
    AnomalyEpisodeRegistry.reset_rate_guard!()
    AnomalyEpisodeRegistry.reset_tripwire!()

    on_exit(fn ->
      restore_env(:stateful_alert_evaluation_queue, previous_queue)
      restore_env(:anomaly_episodes_enabled, previous_episodes)
      restore_env(:anomaly_episode_stale_after_minutes, previous_stale_after)
      restore_env(:anomaly_episode_rate_limit_per_hour, previous_rate_limit)
      AnomalyEpisodeRegistry.reset_rate_guard!()
      AnomalyEpisodeRegistry.reset_tripwire!()
    end)
  end

  test "bulk recorded causal predictions skip duplicate delivery without alert re-enqueue" do
    Application.put_env(:serviceradar_core, :anomaly_episodes_enabled, false)

    message = anomaly_message()
    row = AnalyticsSignals.parse_message(message)

    delete_event!(row)
    on_exit(fn -> delete_event!(row) end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1

    assert_receive {:alert_evaluation_events, [alert_row]}
    assert alert_row.id == uuid_string(row.id)
    assert alert_row.metadata["event_identity"] == row.metadata["event_identity"]

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1
    refute_receive {:alert_evaluation_events, _}, 100
  end

  test "episode path folds stale producer replays into one transition row and stale-closes" do
    unique = System.unique_integer([:positive])
    series_key = "test-series-episode-fold-#{unique}"
    messages = Enum.map(1..5, &anomaly_message(series_key, "episode-fold-#{unique}-#{&1}"))

    on_exit(fn -> delete_episode_fixture!(series_key) end)
    delete_episode_fixture!(series_key)

    assert {:ok, 5} = AnalyticsSignals.process_batch(messages)

    assert_receive {:alert_evaluation_events, [alert_row]}
    refute_receive {:alert_evaluation_events, _}, 100
    assert alert_row.metadata["service_radar"]["transition"] == "open"

    assert [[episode_uid, 5, "open", "open"]] =
             Repo.query!(
               """
               SELECT episode_uid, occurrence_count, status, last_transition
               FROM platform.anomaly_episodes
               WHERE series_key = $1
               """,
               [series_key]
             ).rows

    assert [[1, true, payload_bytes]] =
             Repo.query!(
               """
               SELECT count(*), bool_and(raw_data IS NULL), max(pg_column_size(unmapped))
               FROM platform.ocsf_events
               WHERE metadata->'service_radar'->>'episode_uid' = $1
               """,
               [episode_uid]
             ).rows

    assert payload_bytes < 2_048

    old_seen_at = DateTime.add(DateTime.utc_now(), -3_600, :second)

    Repo.query!(
      "UPDATE platform.anomaly_episodes SET last_seen_at = $2 WHERE series_key = $1",
      [series_key, old_seen_at]
    )

    assert :ok = AnomalyEpisodeStaleCloseWorker.perform(%Oban.Job{})

    assert [["stale_closed", "stale"]] =
             Repo.query!(
               "SELECT status, clear_reason FROM platform.anomaly_episodes WHERE series_key = $1",
               [series_key]
             ).rows
  end

  test "episode path rate guard folds over-limit transitions after DB upsert" do
    Application.put_env(:serviceradar_core, :anomaly_episode_rate_limit_per_hour, 1)
    attach_governor_telemetry()

    unique = System.unique_integer([:positive])
    series_key = "test-series-rate-guard-#{unique}"

    messages = [
      anomaly_message(series_key, "rate-guard-#{unique}-1", 1_812_456_000_000_000_000),
      anomaly_message(series_key, "rate-guard-#{unique}-2", 1_812_456_030_000_000_000)
    ]

    on_exit(fn -> delete_episode_fixture!(series_key) end)
    delete_episode_fixture!(series_key)

    assert {:ok, 2} = AnalyticsSignals.process_batch(messages)

    assert_receive {:alert_evaluation_events, [alert_row]}
    refute_receive {:alert_evaluation_events, _}, 100
    assert alert_row.metadata["service_radar"]["transition"] == "open"

    assert_receive {:governor, [:serviceradar, :anomaly, :governor], %{count: 1},
                    %{reason: :rate_limited, finding_uid: finding_uid, limit_per_hour: 1}}

    assert is_binary(finding_uid)

    assert [[2, 2]] =
             Repo.query!(
               """
               SELECT count(*), COALESCE(sum(occurrence_count), 0)::bigint
               FROM platform.anomaly_episodes
               WHERE series_key = $1
               """,
               [series_key]
             ).rows

    assert [[1]] =
             Repo.query!(
               """
               SELECT count(*)
               FROM platform.ocsf_events
               WHERE metadata->'service_radar'->>'series_key' = $1
               """,
               [series_key]
             ).rows
  end

  defp anomaly_message do
    subject = "signals.analytics.predictions.test-series-bulk-record"

    payload = %{
      "event_id" => "bulk-recorded-anomaly-#{System.unique_integer([:positive])}",
      "signal_type" => "prediction",
      "event_type" => "anomaly",
      "class_uid" => 2004,
      "time" => 1_812_456_000_000,
      "severity_id" => 4,
      "device_uid" => "sr:bulk-record-device",
      "anomaly" => %{
        "series_key" => "test-series-bulk-record",
        "metric_class" => "sysmon.cpu",
        "state" => "anomaly_open",
        "score" => 4.2
      }
    }

    %{
      data: Jason.encode!(payload),
      metadata: %{subject: subject, received_at: DateTime.utc_now()}
    }
  end

  defp anomaly_message(
         series_key,
         event_id,
         episode_started_at_unix_nano \\ 1_812_456_000_000_000_000
       ) do
    payload = %{
      "event_id" => event_id,
      "signal_type" => "prediction",
      "event_type" => "anomaly",
      "class_uid" => 2004,
      "time" => 1_812_456_000_000,
      "severity_id" => 4,
      "device_uid" => "sr:episode-fold-device",
      "verdict_source" => "edge-drift",
      "producer_version" => "0.2.0",
      "anomaly" => %{
        "series_key" => series_key,
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "state" => "anomaly_drift_open",
        "score" => 4.2,
        "episode_started_at_unix_nano" => episode_started_at_unix_nano
      }
    }

    %{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.predictions.#{series_key}",
        received_at: DateTime.utc_now()
      }
    }
  end

  defp delete_event!(nil), do: :ok

  defp delete_event!(row) do
    Repo.query!(
      "DELETE FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
      [uuid_string(row.id), row.time]
    )

    :ok
  end

  defp delete_episode_fixture!(series_key) do
    Repo.query!(
      """
      DELETE FROM platform.ocsf_events
      WHERE metadata->'service_radar'->>'series_key' = $1
         OR unmapped->'anomaly'->>'series_key' = $1
      """,
      [series_key]
    )

    Repo.query!("DELETE FROM platform.anomaly_episodes WHERE series_key = $1", [series_key])
    :ok
  end

  defp event_count(row) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
        [uuid_string(row.id), row.time]
      )

    count
  end

  defp uuid_string(<<_::128>> = id) do
    {:ok, uuid} = Ecto.UUID.load(id)
    uuid
  end

  defp uuid_string(id) when is_binary(id) do
    {:ok, uuid} = Ecto.UUID.cast(id)
    uuid
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)

  defp attach_governor_telemetry do
    handler_id = {__MODULE__, :governor, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :anomaly, :governor],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:governor, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
