defmodule ServiceRadar.Observability.AnomalyAlertLivenessWorkerTest do
  # Not async: one case changes the global alert evaluation mode.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.AnomalyAlertLivenessWorker

  defp health_recorder(pid) do
    fn check, healthy?, metadata ->
      send(pid, {:health, check, healthy?, metadata})
      :ok
    end
  end

  defp cleanup(pid) do
    fn series_key ->
      send(pid, {:cleanup, series_key})
      :ok
    end
  end

  test "records healthy with the deterministic scheduled series key on success" do
    pid = self()

    check = fn opts ->
      send(pid, {:check_opts, opts})
      {:ok, %{alert_id: "alert-1", series_key: opts[:series_key]}}
    end

    assert :ok =
             AnomalyAlertLivenessWorker.run(
               check: check,
               cleanup: cleanup(pid),
               health_recorder: health_recorder(pid)
             )

    assert_received {:check_opts, check_opts}
    assert check_opts[:series_key] == "synthetic:anomaly-alert-liveness:tripwire"

    assert_received {:health, "anomaly-alert-liveness", true, metadata}
    assert metadata["series_key"] == "synthetic:anomaly-alert-liveness:tripwire"

    refute_received {:cleanup, _series_key}
  end

  test "logs, cleans up, and records unhealthy when the check fails" do
    pid = self()
    check = fn _opts -> {:error, :anomaly_alert_liveness_timeout} end

    log =
      capture_log(fn ->
        assert :ok =
                 AnomalyAlertLivenessWorker.run(
                   check: check,
                   cleanup: cleanup(pid),
                   health_recorder: health_recorder(pid)
                 )
      end)

    assert log =~ "Anomaly alert liveness check failed"

    assert_received {:cleanup, "synthetic:anomaly-alert-liveness:tripwire"}
    assert_received {:health, "anomaly-alert-liveness", false, metadata}
    assert metadata["reason"] =~ "anomaly_alert_liveness_timeout"
  end

  test "a raising check fails open: unhealthy recorded, no crash" do
    pid = self()
    check = fn _opts -> raise "engine boom" end

    log =
      capture_log(fn ->
        assert :ok =
                 AnomalyAlertLivenessWorker.run(
                   check: check,
                   cleanup: cleanup(pid),
                   health_recorder: health_recorder(pid)
                 )
      end)

    assert log =~ "Anomaly alert liveness check failed"
    assert_received {:health, "anomaly-alert-liveness", false, metadata}
    assert metadata["reason"] =~ "engine boom"
  end

  test "skips the probe without recording a failure while alert evaluation is not active" do
    pid = self()
    {:ok, previous_mode} = Application.fetch_env(:serviceradar_core, :alert_evaluation_mode)

    on_exit(fn ->
      Application.put_env(:serviceradar_core, :alert_evaluation_mode, previous_mode)
    end)

    check = fn opts ->
      send(pid, {:check_opts, opts})
      {:error, :alert_evaluation_not_activated}
    end

    for mode <- [:prepared, :draining] do
      Application.put_env(:serviceradar_core, :alert_evaluation_mode, mode)

      log =
        capture_log(fn ->
          assert :ok =
                   AnomalyAlertLivenessWorker.run(
                     check: check,
                     cleanup: cleanup(pid),
                     health_recorder: health_recorder(pid)
                   )
        end)

      refute log =~ "Anomaly alert liveness check failed"
      refute_received {:check_opts, _opts}
      refute_received {:cleanup, _series_key}
      refute_received {:health, _check, _healthy?, _metadata}
    end
  end

  test "a raising cleanup does not prevent the unhealthy record" do
    pid = self()
    check = fn _opts -> {:error, :timeout} end
    raising_cleanup = fn _series_key -> raise "cleanup boom" end

    log =
      capture_log(fn ->
        assert :ok =
                 AnomalyAlertLivenessWorker.run(
                   check: check,
                   cleanup: raising_cleanup,
                   health_recorder: health_recorder(pid)
                 )
      end)

    assert log =~ "Anomaly alert liveness cleanup failed"
    assert_received {:health, "anomaly-alert-liveness", false, _metadata}
  end

  test "retries once on a single transient failure without logging at error or recording unhealthy" do
    pid = self()
    counter = :counters.new(1, [:atomics])

    check = fn opts ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> {:error, :anomaly_alert_liveness_timeout}
        2 -> {:ok, %{alert_id: "alert-1", series_key: opts[:series_key]}}
      end
    end

    error_log =
      capture_log([level: :error], fn ->
        assert :ok =
                 AnomalyAlertLivenessWorker.run(
                   check: check,
                   cleanup: cleanup(pid),
                   health_recorder: health_recorder(pid)
                 )
      end)

    assert error_log == ""
    assert :counters.get(counter, 1) == 2
    assert_received {:cleanup, "synthetic:anomaly-alert-liveness:tripwire"}
    refute_received {:health, "anomaly-alert-liveness", false, _metadata}

    assert_received {:health, "anomaly-alert-liveness", true,
                     %{"series_key" => "synthetic:anomaly-alert-liveness:tripwire"}}
  end

  test "does not retry non-transient rule contract regressions" do
    pid = self()
    counter = :counters.new(1, [:atomics])

    check = fn opts ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          {:error, {:stale_rule_contract, "causal_prediction_health_finding", :drift_open_state}}

        2 ->
          {:ok, %{alert_id: "alert-1", series_key: opts[:series_key]}}
      end
    end

    error_log =
      capture_log([level: :error], fn ->
        assert :ok =
                 AnomalyAlertLivenessWorker.run(
                   check: check,
                   cleanup: cleanup(pid),
                   health_recorder: health_recorder(pid)
                 )
      end)

    assert error_log =~ "Anomaly alert liveness check failed"
    assert :counters.get(counter, 1) == 1
    assert_received {:health, "anomaly-alert-liveness", false, metadata}
    assert metadata["reason"] =~ "stale_rule_contract"
  end
end
