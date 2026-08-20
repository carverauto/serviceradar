defmodule ServiceRadarWebNGWeb.StatsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Stats
  alias ServiceRadarWebNGWeb.Stats.Extract
  alias ServiceRadarWebNGWeb.Stats.Query

  describe "log severity query helpers" do
    test "use canonical aliases plus every OTel enum variant" do
      assert Query.log_severity_values(:error) ==
               ~w(error err critical severity_number_error severity_number_error2 severity_number_error3 severity_number_error4)

      assert Query.log_severity_values(:fatal) ==
               ~w(fatal emergency alert severity_number_fatal severity_number_fatal2 severity_number_fatal3 severity_number_fatal4)

      assert Query.log_severity_values(:warning) ==
               ~w(warning warn severity_number_warn severity_number_warn2 severity_number_warn3 severity_number_warn4)

      debug = Query.log_severity_values(:debug)
      assert Enum.take(debug, 2) == ~w(debug trace)
      assert "severity_number_debug4" in debug
      assert "severity_number_trace4" in debug
    end

    test "builds click-through queries from shared severity groups" do
      debug_query = Query.logs_severity_data_query(:debug, limit: 100)
      assert debug_query =~ "in:logs severity:(debug,trace,"
      assert debug_query =~ "severity_number_debug4"
      assert debug_query =~ "severity_number_trace4"
      assert debug_query =~ "severity_number:(1,2,3,4,5,6,7,8) severity_match:any"
      assert String.ends_with?(debug_query, "time:last_24h sort:timestamp:desc limit:100")

      error_query = Query.logs_severity_data_query([:fatal, :error])
      assert error_query =~ "severity_number_fatal4"
      assert error_query =~ "severity_number_error4"
      assert error_query =~ "severity_number:(21,22,23,24,17,18,19,20) severity_match:any"
      assert String.ends_with?(error_query, "time:last_24h sort:timestamp:desc")
    end

    test "builds fallback count queries from the same severity groups" do
      query = Query.logs_severity_count_query(:fatal)
      assert query =~ "severity:(fatal,emergency,alert,"
      refute query =~ "severity:(fatal,critical,"
      assert query =~ "severity_number_fatal4"
      assert query =~ "severity_number:(21,22,23,24) severity_match:any"

      error_count = Query.logs_severity_count_query(:error)
      assert error_count =~ "severity:(error,err,critical,"
      assert String.ends_with?(query, ~s|time:last_24h stats:"count() as total"|)
    end
  end

  describe "logs severity rollup result" do
    defmodule LogsSeverityStubSRQL do
      @moduledoc false

      def query(query, %{scope: scope}) do
        send(self(), {:logs_severity_query, query, scope})

        {:ok,
         %{
           "results" => [
             %{
               "total" => "42",
               "fatal" => 1,
               "error" => 2,
               "warning" => 3,
               "info" => 35,
               "debug" => 1
             }
           ]
         }}
      end
    end

    defmodule LogsSeverityErrorStubSRQL do
      @moduledoc false
      def query(_query, _opts), do: {:error, :undefined_table}
    end

    test "preserves successful stats and scope" do
      assert {:ok, %{total: 42, fatal: 1, error: 2, warning: 3, info: 35, debug: 1}} =
               Stats.logs_severity_result(srql_module: LogsSeverityStubSRQL, scope: :tenant_a)

      assert_received {:logs_severity_query, "in:logs time:last_24h rollup_stats:severity", :tenant_a}
    end

    test "preserves rollup errors for panes while retaining the compatibility helper" do
      assert {:error, :undefined_table} =
               Stats.logs_severity_result(srql_module: LogsSeverityErrorStubSRQL)

      assert Stats.logs_severity(srql_module: LogsSeverityErrorStubSRQL) ==
               Stats.empty_logs_severity()
    end
  end

  describe "assess_logs_rollup_status/1" do
    test "treats an empty current window as healthy when the rollup exists" do
      status =
        Stats.assess_logs_rollup_status(
          rollup_present?: true,
          raw_latest_timestamp: nil,
          raw_window_start_timestamp: nil,
          rollup_latest_bucket: nil,
          rollup_window_start_bucket: nil
        )

      assert status.healthy?
      assert status.messages == []
    end

    test "reports a populated 24-hour rollup as healthy" do
      status =
        Stats.assess_logs_rollup_status(
          rollup_present?: true,
          raw_latest_timestamp: ~U[2026-08-12 12:04:00Z],
          raw_window_start_timestamp: ~U[2026-08-11 12:05:00Z],
          rollup_latest_bucket: ~U[2026-08-12 12:00:00Z],
          rollup_window_start_bucket: ~U[2026-08-11 12:05:00Z],
          stale_threshold_seconds: 900,
          coverage_grace_seconds: 300
        )

      assert status.healthy?
      assert status.lag_seconds == 240
      assert status.coverage_gap_seconds == 0
      assert status.messages == []
    end

    test "reports missing, stale, and partial rollups" do
      missing =
        Stats.assess_logs_rollup_status(
          rollup_present?: false,
          raw_latest_timestamp: ~U[2026-08-12 12:04:00Z]
        )

      refute missing.healthy?
      assert Enum.any?(missing.messages, &String.contains?(&1, "Missing log severity rollup"))

      stale =
        Stats.assess_logs_rollup_status(
          rollup_present?: true,
          raw_latest_timestamp: ~U[2026-08-12 12:04:00Z],
          raw_window_start_timestamp: ~U[2026-08-11 12:05:00Z],
          rollup_latest_bucket: ~U[2026-08-12 11:30:00Z],
          rollup_window_start_bucket: ~U[2026-08-11 14:05:00Z],
          stale_threshold_seconds: 900,
          coverage_grace_seconds: 300
        )

      refute stale.healthy?
      assert stale.lag_seconds == 2_040
      assert stale.coverage_gap_seconds == 7_200
      assert Enum.any?(stale.messages, &String.contains?(&1, "lags raw logs"))
      assert Enum.any?(stale.messages, &String.contains?(&1, "24-hour card window"))
    end
  end

  describe "metrics RED rollup stats" do
    test "builds the rollup_stats:red query over otel_traces" do
      assert Query.metrics_red() == "in:otel_traces time:last_24h rollup_stats:red"
      assert Query.metrics_red(time: "last_6h") == "in:otel_traces time:last_6h rollup_stats:red"

      assert Query.metrics_red(service_name: "core-elx") ==
               ~s|in:otel_traces time:last_24h rollup_stats:red service_name:"core-elx"|
    end

    test "extracts the red payload into metrics summary keys" do
      payload = %{
        "total" => 1200,
        "errors" => 24,
        "slow" => 36,
        "error_rate" => 2.0,
        "avg_duration_ms" => 12.5,
        "p50_duration_ms" => 8.0,
        "p95_duration_ms" => 42.0,
        "max_duration_ms" => 480.0
      }

      assert Extract.metrics_red({:ok, %{"results" => [payload]}}) == %{
               total: 1200,
               slow_spans: 36,
               error_spans: 24,
               error_rate: 2.0,
               avg_duration_ms: 12.5,
               p50_duration_ms: 8.0,
               p95_duration_ms: 42.0,
               max_duration_ms: 480.0,
               sample_size: 1200
             }
    end

    test "tolerates string-encoded numbers in the payload" do
      payload = %{"total" => "10", "errors" => "1", "slow" => "2", "error_rate" => "10.0"}

      stats = Extract.metrics_red({:ok, %{"results" => [payload]}})

      assert stats.total == 10
      assert stats.error_spans == 1
      assert stats.slow_spans == 2
      assert stats.error_rate == 10.0
      assert stats.sample_size == 10
    end

    test "falls back to empty stats on errors or empty results" do
      assert Extract.metrics_red({:error, :nif_panic}) == Extract.empty_metrics_red()
      assert Extract.metrics_red({:ok, %{"results" => []}}) == Extract.empty_metrics_red()
      assert Stats.empty_metrics_summary() == Extract.empty_metrics_red()
    end

    test "metrics_summary goes through the SRQL module (no Ecto path, no process-name guard)" do
      defmodule RedStubSRQL do
        @moduledoc false
        def query(query, %{scope: :tenant_a}) do
          send(self(), {:red_query, query})

          {:ok, %{"results" => [%{"total" => 7, "errors" => 1, "slow" => 2, "error_rate" => 14.3}]}}
        end
      end

      stats = Stats.metrics_summary(srql_module: RedStubSRQL, scope: :tenant_a)

      assert_received {:red_query, "in:otel_traces time:last_24h rollup_stats:red"}
      assert %{total: 7, error_spans: 1, slow_spans: 2, error_rate: 14.3} = stats
    end
  end

  describe "anomaly findings rollup stats" do
    test "builds the rollup_stats:anomaly_findings query over events" do
      assert Query.anomaly_findings() == "in:events time:last_24h rollup_stats:anomaly_findings"

      assert Query.anomaly_findings(time: "last_7d") ==
               "in:events time:last_7d rollup_stats:anomaly_findings"
    end

    test "extracts the anomaly findings payload" do
      payload = %{
        "total" => 12,
        "anomalies" => 7,
        "at_risk" => 5,
        "critical" => 2,
        "high" => 3
      }

      assert Extract.anomaly_findings({:ok, %{"results" => [payload]}}) == %{
               total: 12,
               anomalies: 7,
               at_risk: 5,
               critical: 2,
               high: 3
             }
    end

    test "anomaly_findings_summary goes through the SRQL module" do
      defmodule AnomalyFindingsStubSRQL do
        @moduledoc false
        def query(query, %{scope: :tenant_a}) do
          send(self(), {:anomaly_findings_query, query})

          {:ok, %{"results" => [%{"total" => "4", "anomalies" => "3", "at_risk" => "1"}]}}
        end
      end

      stats = Stats.anomaly_findings_summary(srql_module: AnomalyFindingsStubSRQL, scope: :tenant_a)

      assert_received {:anomaly_findings_query, "in:events time:last_24h rollup_stats:anomaly_findings"}
      assert %{total: 4, anomalies: 3, at_risk: 1, critical: 0, high: 0} = stats
    end
  end

  describe "assess_trace_rollup_status/1" do
    test "returns healthy when assets are present and within lag threshold" do
      raw_latest = ~U[2026-03-14 12:00:00Z]
      summary_latest = ~U[2026-03-14 11:58:30Z]
      rollup_latest = ~U[2026-03-14 11:55:00Z]

      status =
        Stats.assess_trace_rollup_status(
          summary_table_present?: true,
          traces_rollup_present?: true,
          raw_latest_timestamp: raw_latest,
          summary_latest_timestamp: summary_latest,
          rollup_latest_bucket: rollup_latest,
          stale_threshold_seconds: 600
        )

      assert status.healthy?
      assert status.messages == []
      assert status.summary_lag_seconds == 90
      assert status.rollup_lag_seconds == 300
    end

    test "reports missing assets and stale lag" do
      raw_latest = ~U[2026-03-14 12:00:00Z]
      summary_latest = ~U[2026-03-14 10:00:00Z]
      rollup_latest = ~U[2026-03-14 11:00:00Z]

      status =
        Stats.assess_trace_rollup_status(
          summary_table_present?: false,
          traces_rollup_present?: false,
          raw_latest_timestamp: raw_latest,
          summary_latest_timestamp: summary_latest,
          rollup_latest_bucket: rollup_latest,
          stale_threshold_seconds: 900
        )

      refute status.healthy?

      assert Enum.any?(
               status.messages,
               &String.contains?(&1, "Missing trace summary table")
             )

      assert Enum.any?(
               status.messages,
               &String.contains?(&1, "Missing trace rollup")
             )

      assert Enum.any?(
               status.messages,
               &String.contains?(&1, "Trace summaries lag raw traces by 2h 0m.")
             )

      assert Enum.any?(
               status.messages,
               &String.contains?(&1, "Trace rollup lags raw traces by 1h 0m.")
             )
    end
  end

  describe "trace_rollup_status/1" do
    test "does not surface repo startup failures to users" do
      status = Stats.trace_rollup_status()

      assert status.healthy?
      assert status.messages == []
    end
  end
end
