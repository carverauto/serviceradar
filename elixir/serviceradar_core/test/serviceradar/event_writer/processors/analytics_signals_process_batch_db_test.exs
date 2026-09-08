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
      send(test_pid(), {:alert_evaluation_events, events})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core, :analytics_signals_process_batch_test_pid)
    end
  end

  defmodule NorthboundRunner do
    @moduledoc false

    def handle_event(event) do
      send(test_pid(), {:northbound_event, event})
      {:ok, []}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core, :analytics_signals_process_batch_test_pid)
    end
  end

  defmodule FailingNorthboundRunner do
    @moduledoc false

    def handle_event(_event), do: raise("northbound runner unavailable")
  end

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    previous_queue = Application.get_env(:serviceradar_core, :stateful_alert_evaluation_queue)

    previous_northbound_runner =
      Application.get_env(:serviceradar_core, :northbound_event_handler_runner)

    previous_test_pid =
      Application.get_env(:serviceradar_core, :analytics_signals_process_batch_test_pid)

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

    Application.put_env(
      :serviceradar_core,
      :northbound_event_handler_runner,
      __MODULE__.NorthboundRunner
    )

    Application.put_env(
      :serviceradar_core,
      :analytics_signals_process_batch_test_pid,
      self()
    )

    Application.put_env(:serviceradar_core, :anomaly_episodes_enabled, true)
    Application.put_env(:serviceradar_core, :anomaly_episode_stale_after_minutes, 30)
    AnomalyEpisodeRegistry.reset_rate_guard!()
    AnomalyEpisodeRegistry.reset_tripwire!()

    on_exit(fn ->
      restore_env(:stateful_alert_evaluation_queue, previous_queue)
      restore_env(:northbound_event_handler_runner, previous_northbound_runner)
      restore_env(:analytics_signals_process_batch_test_pid, previous_test_pid)
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

  test "inventory vulnerability assessment opens, resolves, and reopens one OCSF row" do
    event_id = "assessment-lifecycle-#{System.unique_integer([:positive])}"
    open_message = assessment_message(event_id, "open", "active", "confirmed", "affected")
    row = AnalyticsSignals.parse_message(open_message)

    delete_event!(row)
    on_exit(fn -> delete_event!(row) end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([open_message])
    assert event_count(row) == 1
    assert event_lifecycle(row) == ["open", 1, "Create"]

    assert_receive {:alert_evaluation_events, [open_alert_row]}
    assert open_alert_row.status == "open"

    assert_receive {:northbound_event, open_northbound_row}
    assert open_northbound_row.id == uuid_string(row.id)
    assert open_northbound_row.status == "open"
    assert open_northbound_row.activity_name == "Create"

    assert {:ok, 1} = AnalyticsSignals.process_batch([open_message])
    refute_receive {:alert_evaluation_events, _}, 100
    refute_receive {:northbound_event, _}, 100

    resolved_message =
      assessment_message(event_id, "resolved", "resolved", "confirmed", "fixed")

    assert {:ok, 1} = AnalyticsSignals.process_batch([resolved_message])
    assert event_count(row) == 1
    assert event_lifecycle(row) == ["resolved", 3, "Close"]

    assert_receive {:alert_evaluation_events, [resolved_alert_row]}
    assert resolved_alert_row.status == "resolved"

    assert_receive {:northbound_event, resolved_northbound_row}
    assert resolved_northbound_row.id == uuid_string(row.id)
    assert resolved_northbound_row.status == "resolved"
    assert resolved_northbound_row.activity_name == "Close"

    assert {:ok, 1} = AnalyticsSignals.process_batch([resolved_message])
    refute_receive {:alert_evaluation_events, _}, 100
    refute_receive {:northbound_event, _}, 100

    reopened_message = assessment_message(event_id, "open", "active", "confirmed", "affected")

    assert {:ok, 1} = AnalyticsSignals.process_batch([reopened_message])
    assert event_count(row) == 1
    assert event_lifecycle(row) == ["open", 2, "Update"]

    assert_receive {:alert_evaluation_events, [reopened_alert_row]}
    assert reopened_alert_row.status == "open"

    assert_receive {:northbound_event, reopened_northbound_row}
    assert reopened_northbound_row.id == uuid_string(row.id)
    assert reopened_northbound_row.status == "open"
    assert reopened_northbound_row.activity_name == "Update"

    assert {:ok, 1} = AnalyticsSignals.process_batch([reopened_message])
    refute_receive {:alert_evaluation_events, _}, 100
    refute_receive {:northbound_event, _}, 100
  end

  test "northbound runner failure does not suppress the durable alert transition" do
    Application.put_env(
      :serviceradar_core,
      :northbound_event_handler_runner,
      __MODULE__.FailingNorthboundRunner
    )

    event_id = "assessment-runner-failure-#{System.unique_integer([:positive])}"
    message = assessment_message(event_id, "open", "active", "confirmed", "affected")
    row = AnalyticsSignals.parse_message(message)

    delete_event!(row)
    on_exit(fn -> delete_event!(row) end)

    assert {:ok, 1} = AnalyticsSignals.process_batch([message])
    assert event_count(row) == 1
    assert_receive {:alert_evaluation_events, [alert_row]}
    assert alert_row.status == "open"
  end

  @tag sandbox: :unboxed
  test "concurrent duplicate opens serialize and dispatch one durable transition" do
    event_id = "assessment-concurrent-open-#{System.unique_integer([:positive])}"
    message = assessment_message(event_id, "open", "active", "confirmed", "affected")
    row = AnalyticsSignals.parse_message(message)
    event_uuid = uuid_string(row.id)
    parent = self()

    delete_event!(row)
    on_exit(fn -> delete_event!(row) end)

    lock_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            ["serviceradar:inventory-vulnerability-lifecycle:#{event_uuid}"]
          )

          send(parent, :inventory_vulnerability_lock_held)

          receive do
            :release_inventory_vulnerability_lock -> :ok
          after
            5_000 -> raise "timed out waiting to release inventory vulnerability lock"
          end
        end)
      end)

    assert_receive :inventory_vulnerability_lock_held, 1_000

    workers =
      for _ <- 1..2 do
        Task.async(fn ->
          result = AnalyticsSignals.process_batch([message])
          send(parent, {:inventory_vulnerability_process_finished, self()})
          result
        end)
      end

    on_exit(fn ->
      send(lock_holder.pid, :release_inventory_vulnerability_lock)

      Enum.each([lock_holder | workers], fn task ->
        if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
      end)
    end)

    refute_receive {:inventory_vulnerability_process_finished, _pid}, 250
    send(lock_holder.pid, :release_inventory_vulnerability_lock)

    assert {:ok, :ok} = Task.await(lock_holder, 5_000)
    assert [{:ok, 1}, {:ok, 1}] = Task.await_many(workers, 5_000)
    assert event_count(row) == 1

    assert_receive {:northbound_event, northbound_row}
    assert northbound_row.id == event_uuid
    assert northbound_row.status == "open"
    refute_receive {:northbound_event, _}, 100

    assert_receive {:alert_evaluation_events, [alert_row]}
    assert alert_row.id == event_uuid
    assert alert_row.status == "open"
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

  test "episode path rate guard folds over-limit escalation transitions after DB upsert" do
    Application.put_env(:serviceradar_core, :anomaly_episode_rate_limit_per_hour, 1)
    attach_governor_telemetry()

    unique = System.unique_integer([:positive])
    series_key = "test-series-rate-guard-#{unique}"

    messages = [
      anomaly_message(series_key, "rate-guard-#{unique}-1", 1_812_456_000_000_000_000, 3),
      anomaly_message(series_key, "rate-guard-#{unique}-2", 1_812_456_000_000_000_000, 4)
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

    assert [[1, 2, 4]] =
             Repo.query!(
               """
               SELECT
                 count(*),
                 COALESCE(sum(occurrence_count), 0)::bigint,
                 max(peak_severity_id)
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

  defp assessment_message(event_id, finding_status, assessment_status, assessment, disposition) do
    payload = %{
      "event_id" => event_id,
      "signal_type" => "inventory",
      "event_type" => "vulnerability_assessment",
      "finding_type" => "vulnerability",
      "timestamp" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "device_uid" => "sr:assessment-lifecycle-device",
      "cve_id" => "CVE-2099-9001",
      "status" => finding_status,
      "finding_status" => finding_status,
      "assessment_status" => assessment_status,
      "assessment" => assessment,
      "disposition" => disposition,
      "package" => %{
        "identity_key" => "pkgid:v1:assessment-lifecycle",
        "name" => "starling-fetch",
        "version" => "3.2.1-1ubuntu99.4"
      }
    }

    %{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.inventory.vulnerability_assessment",
        received_at: DateTime.utc_now()
      }
    }
  end

  defp anomaly_message(
         series_key,
         event_id,
         episode_started_at_unix_nano \\ 1_812_456_000_000_000_000,
         severity_id \\ 4
       ) do
    payload = %{
      "event_id" => event_id,
      "signal_type" => "prediction",
      "event_type" => "anomaly",
      "class_uid" => 2004,
      "time" => 1_812_456_000_000,
      "severity_id" => severity_id,
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

  defp event_lifecycle(row) do
    %{rows: [[status, activity_id, activity_name]]} =
      Repo.query!(
        "SELECT status, activity_id, activity_name FROM platform.ocsf_events WHERE id = ($1::text)::uuid AND time = $2",
        [uuid_string(row.id), row.time]
      )

    [status, activity_id, activity_name]
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
