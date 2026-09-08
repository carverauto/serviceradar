defmodule ServiceRadar.Observability.AnomalyIngestSilenceWorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.AnomalyIngestSilenceWorker

  defmodule RepoStub do
    @moduledoc false

    def query(sql, [cutoff]) do
      send(Process.get(:silence_test_pid), {:query, sql, cutoff})
      responses = Process.get(:silence_repo_responses)

      cond do
        sql =~ "timeseries_metrics" -> respond(responses.metrics)
        sql =~ "ocsf_events" -> respond(responses.anomalies)
        sql =~ "anomaly_episodes" -> respond(Map.get(responses, :episodes, false))
        sql =~ "addon_statuses" -> respond(Map.get(responses, :heartbeat, false))
      end
    end

    defp respond(value) when is_boolean(value), do: {:ok, %{rows: [[value]]}}
    defp respond({:error, _reason} = error), do: error
    defp respond(:raise), do: raise("query boom")
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :anomaly_silence_hours)
    Process.put(:silence_test_pid, self())

    on_exit(fn ->
      Process.delete(:silence_test_pid)
      Process.delete(:silence_repo_responses)

      case previous do
        nil -> Application.delete_env(:serviceradar_core, :anomaly_silence_hours)
        value -> Application.put_env(:serviceradar_core, :anomaly_silence_hours, value)
      end
    end)
  end

  defp health_recorder(pid) do
    fn check, healthy?, metadata ->
      send(pid, {:health, check, healthy?, metadata})
      :ok
    end
  end

  defp run(responses, opts \\ []) do
    Process.put(:silence_repo_responses, responses)

    AnomalyIngestSilenceWorker.run(
      Keyword.merge(
        [repo: RepoStub, health_recorder: health_recorder(self())],
        opts
      )
    )
  end

  test "fires unhealthy only when findings, episodes, and heartbeat are all silent" do
    log =
      capture_log(fn ->
        assert :ok =
                 run(%{metrics: true, anomalies: false, episodes: false, heartbeat: false})
      end)

    assert log =~ "No anomaly-detection findings or live episodes for 6h"
    assert_received {:health, "anomaly-ingest-silence", false, %{"silence_hours" => 6}}
  end

  test "records healthy when anomaly findings arrived inside the window" do
    assert :ok = run(%{metrics: true, anomalies: true})
    assert_received {:health, "anomaly-ingest-silence", true, %{}}

    # Findings short-circuit the remaining probes.
    assert_received {:query, metrics_sql, _}
    assert metrics_sql =~ "timeseries_metrics"
    assert_received {:query, anomaly_sql, _}
    assert anomaly_sql =~ "ocsf_events"
    refute_received {:query, _sql, _cutoff}
  end

  test "a recently seen open episode counts as a live pipeline (episodes-mode folding)" do
    assert :ok = run(%{metrics: true, anomalies: false, episodes: true})
    assert_received {:health, "anomaly-ingest-silence", true, %{}}
  end

  test "a fresh running anomaly add-on heartbeat makes silence healthy quiet" do
    assert :ok = run(%{metrics: true, anomalies: false, episodes: false, heartbeat: true})
    assert_received {:health, "anomaly-ingest-silence", true, %{}}
  end

  test "uses the configured silence window for the anomaly cutoff" do
    Application.put_env(:serviceradar_core, :anomaly_silence_hours, 2)
    now = ~U[2026-07-12 12:00:00Z]

    assert :ok =
             run(%{metrics: true, anomalies: false, episodes: false, heartbeat: true},
               now: now
             )

    assert_received {:query, metrics_sql, metrics_cutoff}
    assert metrics_sql =~ "timeseries_metrics"
    assert metrics_cutoff == ~U[2026-07-12 11:00:00Z]

    assert_received {:query, anomaly_sql, anomaly_cutoff}
    assert anomaly_sql =~ "ocsf_events"
    assert anomaly_sql =~ "class_uid = 2004"
    assert anomaly_sql =~ "{service_radar,source_type}"
    assert anomaly_cutoff == ~U[2026-07-12 10:00:00Z]

    # The episode probe shares the silence window (naive, matching the
    # timestamp(6) column); the heartbeat probe uses its own 15m freshness.
    assert_received {:query, episode_sql, episode_cutoff}
    assert episode_sql =~ "anomaly_episodes"
    assert episode_sql =~ "status = 'open'"
    assert episode_cutoff == ~N[2026-07-12 10:00:00]

    assert_received {:query, heartbeat_sql, heartbeat_cutoff}
    assert heartbeat_sql =~ "addon_statuses"
    assert heartbeat_sql =~ "addon_id = 'anomaly'"
    assert heartbeat_sql =~ "state = 'running'"
    assert heartbeat_cutoff == ~N[2026-07-12 11:45:00]

    assert_received {:health, "anomaly-ingest-silence", true, %{}}
  end

  test "stays quiet when metric ingest is dead too" do
    assert :ok = run(%{metrics: false, anomalies: false})

    refute_received {:health, _check, _healthy?, _metadata}

    # The anomaly query never runs: only the metrics probe was issued.
    assert_received {:query, metrics_sql, _cutoff}
    assert metrics_sql =~ "timeseries_metrics"
    refute_received {:query, _sql, _other_cutoff}
  end

  test "query errors fail open: log, no verdict, no crash" do
    log =
      capture_log(fn ->
        assert :ok = run(%{metrics: {:error, :connection_refused}, anomalies: true})
      end)

    assert log =~ "skipping this run"
    refute_received {:health, _check, _healthy?, _metadata}

    log =
      capture_log(fn ->
        assert :ok = run(%{metrics: true, anomalies: :raise})
      end)

    assert log =~ "skipping this run"
    refute_received {:health, _check, _healthy?, _metadata}

    log =
      capture_log(fn ->
        assert :ok =
                 run(%{metrics: true, anomalies: false, episodes: {:error, :timeout}})
      end)

    assert log =~ "skipping this run"
    refute_received {:health, _check, _healthy?, _metadata}

    log =
      capture_log(fn ->
        assert :ok = run(%{metrics: true, anomalies: false, episodes: false, heartbeat: :raise})
      end)

    assert log =~ "skipping this run"
    refute_received {:health, _check, _healthy?, _metadata}
  end

  test "silence_hours defaults to 6 and honors positive app env" do
    Application.delete_env(:serviceradar_core, :anomaly_silence_hours)
    assert AnomalyIngestSilenceWorker.silence_hours() == 6

    Application.put_env(:serviceradar_core, :anomaly_silence_hours, 12)
    assert AnomalyIngestSilenceWorker.silence_hours() == 12

    Application.put_env(:serviceradar_core, :anomaly_silence_hours, 0)
    assert AnomalyIngestSilenceWorker.silence_hours() == 6
  end
end
