defmodule ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.EventWriter.Processors.AnomalyEpisodeRegistry

  defmodule RepoStub do
    @moduledoc false

    def query(_sql, params) do
      decision =
        Process.get(:episode_decision, %{
          previous_status: "",
          previous_peak_severity_id: -1,
          episode_uid: nil,
          producer_count: 1
        })

      status = Enum.at(params, 8)
      severity_id = Enum.at(params, 9)
      current_peak = max(decision.previous_peak_severity_id, severity_id)
      current_status = Map.get(decision, :current_status, status)

      send(Process.get(:episode_test_pid), {:episode_upsert, params})

      episode_uid =
        case Map.get(decision, :episode_uid) do
          # An all-NULL RETURNING projection: the statement inserted nothing.
          :null -> nil
          nil -> Enum.at(params, 0)
          uid -> uid
        end

      {:ok,
       %{
         rows: [
           [
             decision.previous_status,
             decision.previous_peak_severity_id,
             current_status,
             if(is_nil(current_status), do: nil, else: severity_id),
             if(is_nil(current_status), do: nil, else: current_peak),
             episode_uid,
             Map.get(decision, :producer_count, 1)
           ]
         ]
       }}
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :anomaly_episodes_enabled)
    previous_limit = Application.get_env(:serviceradar_core, :anomaly_episode_rate_limit_per_hour)

    previous_threshold =
      Application.get_env(:serviceradar_core, :anomaly_ingest_flood_threshold_per_minute)

    previous_publisher =
      Application.get_env(:serviceradar_core, :anomaly_ingest_tripwire_publisher)

    Application.put_env(:serviceradar_core, :anomaly_episodes_enabled, true)
    Process.put(:episode_test_pid, self())
    AnomalyEpisodeRegistry.reset_rate_guard!()
    AnomalyEpisodeRegistry.reset_tripwire!()

    on_exit(fn ->
      Process.delete(:episode_decision)
      Process.delete(:episode_test_pid)
      restore_env(:anomaly_episodes_enabled, previous)
      restore_env(:anomaly_episode_rate_limit_per_hour, previous_limit)
      restore_env(:anomaly_ingest_flood_threshold_per_minute, previous_threshold)
      restore_env(:anomaly_ingest_tripwire_publisher, previous_publisher)
      AnomalyEpisodeRegistry.reset_rate_guard!()
      AnomalyEpisodeRegistry.reset_tripwire!()
    end)
  end

  test "new anomaly episode emits an open transition and stamps transition identity" do
    original = anomaly_row("anomaly_drift_open", severity_id: 4, producer_version: "0.2.0")

    assert [row] = AnomalyEpisodeRegistry.transition_rows([original], RepoStub)
    assert row.id != original.id
    assert row.metadata["event_identity"]
    assert row.metadata["service_radar"]["transition"] == "open"
    assert row.metadata["service_radar"]["episode_uid"]
    assert row.metadata["service_radar"]["producer_version"] == "0.2.0"
    assert row.metadata["detection_finding"]["transition"] == "open"

    assert_receive {:episode_upsert, params}
    assert Enum.at(params, 1) == original.metadata["service_radar"]["finding_uid"]
    assert Enum.at(params, 2) == "sr:episode-device"
    assert Enum.at(params, 3) == original.metadata["service_radar"]["series_key"]
    assert Enum.at(params, 8) == "open"
    assert Enum.at(params, 9) == 4
    assert Enum.at(params, 19) == "open"
  end

  test "unchanged open episode folds into the episode row without an OCSF event" do
    Process.put(:episode_decision, %{previous_status: "open", previous_peak_severity_id: 4})

    row = anomaly_row("anomaly_open", severity_id: 4)

    assert [] = AnomalyEpisodeRegistry.transition_rows([row], RepoStub)
    assert_receive {:episode_upsert, _params}
  end

  test "severity escalation emits an update transition" do
    Process.put(:episode_decision, %{previous_status: "open", previous_peak_severity_id: 3})

    row = anomaly_row("anomaly_open", severity_id: 4)

    assert [_row] = AnomalyEpisodeRegistry.transition_rows([row], RepoStub)
    assert_receive {:episode_upsert, _params}
  end

  test "a duplicate producer folds onto the canonical episode identity" do
    canonical_episode_uid = Ecto.UUID.generate()

    Process.put(:episode_decision, %{
      previous_status: "open",
      previous_peak_severity_id: 3,
      episode_uid: canonical_episode_uid,
      producer_count: 2
    })

    attach_multi_producer_telemetry()

    duplicate = anomaly_row("anomaly_open", severity_id: 4)
    assert [row] = AnomalyEpisodeRegistry.transition_rows([duplicate], RepoStub)
    assert row.metadata["service_radar"]["episode_uid"] == canonical_episode_uid

    assert_receive {:multi_producer, [:serviceradar, :anomaly, :episode_registry],
                    %{multi_producer_series: 1}, %{producer_count: 2}}
  end

  test "drift clear emits only when an episode was previously open" do
    Process.put(:episode_decision, %{previous_status: "open", previous_peak_severity_id: 4})

    clear = anomaly_row("anomaly_drift_clear", severity_id: 2)

    assert [row] = AnomalyEpisodeRegistry.transition_rows([clear], RepoStub)
    assert row.metadata["service_radar"]["transition"] == "clear"
    assert_receive {:episode_upsert, params}
    assert Enum.at(params, 8) == "cleared"
    assert Enum.at(params, 19) == "clear"

    Process.put(:episode_decision, %{previous_status: "", previous_peak_severity_id: -1})

    assert [] = AnomalyEpisodeRegistry.transition_rows([clear], RepoStub)
  end

  test "a clear that resolves no episode is neither persisted nor emitted" do
    # The upsert inserts nothing when a clear finds no open (or fold-window)
    # episode, so the RETURNING projection comes back all-NULL. That used to
    # mint a zero-length "cleared" episode for every central seasonal clear
    # that arrived after the stale sweep had already closed the breach.
    Process.put(:episode_decision, %{
      previous_status: "",
      previous_peak_severity_id: -1,
      current_status: nil,
      episode_uid: :null,
      producer_count: 0
    })

    clear = anomaly_row("anomaly_clear", severity_id: 2)

    assert [] = AnomalyEpisodeRegistry.transition_rows([clear], RepoStub)
    assert_receive {:episode_upsert, params}
    assert Enum.at(params, 8) == "cleared"
  end

  test "the upsert statement gates the insert on a clear resolving an episode" do
    sql = AnomalyEpisodeRegistry.upsert_sql()
    assert sql =~ "orphan_clear"
    assert sql =~ "WHERE NOT aggregate.orphan_clear"
  end

  test "a clear is withheld while another producer keeps the canonical episode open" do
    Process.put(:episode_decision, %{
      previous_status: "open",
      previous_peak_severity_id: 4,
      current_status: "open",
      producer_count: 2
    })

    clear = anomaly_row("anomaly_drift_clear", severity_id: 2)

    assert [] = AnomalyEpisodeRegistry.transition_rows([clear], RepoStub)
    assert_receive {:episode_upsert, params}
    assert Enum.at(params, 19) == "clear"
  end

  test "rate guard folds over-limit transitions after episode upsert" do
    Application.put_env(:serviceradar_core, :anomaly_episode_rate_limit_per_hour, 1)
    attach_governor_telemetry()

    row = anomaly_row("anomaly_open", severity_id: 4)

    assert [_row] = AnomalyEpisodeRegistry.transition_rows([row], RepoStub)
    assert [] = AnomalyEpisodeRegistry.transition_rows([row], RepoStub)

    assert_receive {:episode_upsert, _params}
    assert_receive {:episode_upsert, _params}

    assert_receive {:governor, [:serviceradar, :anomaly, :governor], %{count: 1},
                    %{reason: :rate_limited, finding_uid: finding_uid, limit_per_hour: 1}}

    assert finding_uid == row.metadata["service_radar"]["finding_uid"]
  end

  test "flood tripwire emits one operational event when per-minute upserts cross threshold" do
    Application.put_env(:serviceradar_core, :anomaly_ingest_flood_threshold_per_minute, 1)

    Application.put_env(:serviceradar_core, :anomaly_ingest_tripwire_publisher, fn subject,
                                                                                   payload ->
      send(self(), {:tripwire, subject, payload})
      :ok
    end)

    row = anomaly_row("anomaly_open", severity_id: 4)

    assert [_row] = AnomalyEpisodeRegistry.transition_rows([row], RepoStub)
    assert [_row] = AnomalyEpisodeRegistry.transition_rows([row], RepoStub)
    assert [_row] = AnomalyEpisodeRegistry.transition_rows([row], RepoStub)

    assert_receive {:tripwire, "event_writer", payload}
    assert payload.event == "anomaly_ingest_flood"
    assert payload.status_code == "anomaly_ingest_flood"
    assert payload.count_per_minute == 2
    assert payload.threshold_per_minute == 1
    assert payload.finding_uid == row.metadata["service_radar"]["finding_uid"]

    refute_receive {:tripwire, _, _}, 100
  end

  describe "enabled?/0" do
    setup do
      previous_env_var = System.get_env("EVENT_WRITER_ANOMALY_EPISODES")

      on_exit(fn ->
        case previous_env_var do
          nil -> System.delete_env("EVENT_WRITER_ANOMALY_EPISODES")
          value -> System.put_env("EVENT_WRITER_ANOMALY_EPISODES", value)
        end
      end)

      Application.delete_env(:serviceradar_core, :anomaly_episodes_enabled)
      System.delete_env("EVENT_WRITER_ANOMALY_EPISODES")
      :ok
    end

    test "defaults to enabled" do
      assert AnomalyEpisodeRegistry.enabled?()
    end

    test "env var kill switch disables the registry" do
      for value <- ["false", "0", "no", "off", " False "] do
        System.put_env("EVENT_WRITER_ANOMALY_EPISODES", value)
        refute AnomalyEpisodeRegistry.enabled?()
      end

      System.put_env("EVENT_WRITER_ANOMALY_EPISODES", "true")
      assert AnomalyEpisodeRegistry.enabled?()
    end

    test "app env override wins over the env var" do
      System.put_env("EVENT_WRITER_ANOMALY_EPISODES", "true")
      Application.put_env(:serviceradar_core, :anomaly_episodes_enabled, false)

      refute AnomalyEpisodeRegistry.enabled?()
    end

    test "kill switch passes rows through without episode upserts" do
      System.put_env("EVENT_WRITER_ANOMALY_EPISODES", "false")

      row = anomaly_row("anomaly_open", severity_id: 4)

      assert [^row] = AnomalyEpisodeRegistry.transition_rows([row], RepoStub)
      refute_receive {:episode_upsert, _params}, 100
    end
  end

  test "complete projection falls back to finding UID and opened_at for legacy producers" do
    row = anomaly_row("anomaly_open", severity_id: 4)

    assert {:ok, attrs} = AnomalyEpisodeRegistry.episode_projection(row)
    assert attrs.episode_uid
    assert attrs.finding_uid == row.metadata["service_radar"]["finding_uid"]
    assert attrs.detector == "drift"
    assert attrs.status == "open"
    assert attrs.last_transition == "open"
  end

  defp anomaly_row(state, opts) do
    severity_id = Keyword.get(opts, :severity_id, 4)
    producer_version = Keyword.get(opts, :producer_version)

    payload =
      %{
        "event_id" => "episode-registry-#{state}-#{System.unique_integer([:positive])}",
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-07-04T12:00:00Z",
        "severity_id" => severity_id,
        "device_uid" => "sr:episode-device",
        "verdict_source" => "edge-drift",
        "producer_version" => producer_version,
        "anomaly" => %{
          "series_key" => "sysmon:cpu:sr:episode-device",
          "metric_class" => "sysmon.cpu",
          "metric_name" => "cpu.usage_percent",
          "state" => state,
          "score" => 4.5,
          "episode_started_at_unix_nano" => 1_812_456_000_000_000_000
        }
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    AnalyticsSignals.parse_message(%{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.predictions.sysmon:cpu:sr:episode-device",
        received_at: ~U[2026-07-04 12:00:00Z]
      }
    })
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

  defp attach_multi_producer_telemetry do
    handler_id = {__MODULE__, :multi_producer, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:serviceradar, :anomaly, :episode_registry],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:multi_producer, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
