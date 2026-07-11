defmodule ServiceRadarWebNGWeb.StatsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Stats
  alias ServiceRadarWebNGWeb.Stats.Extract
  alias ServiceRadarWebNGWeb.Stats.Query

  describe "log severity query helpers" do
    test "use canonical aliases without redundant case variants" do
      assert Query.log_severity_values(:fatal) == ~w(fatal critical emergency alert)
      assert Query.log_severity_values(:error) == ~w(error err)
      assert Query.log_severity_values(:warning) == ~w(warning warn)
      assert Query.log_severity_values(:info) == ~w(info information informational notice)
      assert Query.log_severity_values(:debug) == ~w(debug trace)
    end

    test "builds click-through queries from shared severity groups" do
      assert Query.logs_severity_data_query(:debug, limit: 100) ==
               "in:logs severity_text:(debug,trace) time:last_24h sort:timestamp:desc limit:100"

      assert Query.logs_severity_data_query([:fatal, :error]) ==
               "in:logs severity_text:(fatal,critical,emergency,alert,error,err) time:last_24h sort:timestamp:desc"
    end

    test "builds fallback count queries from the same severity groups" do
      assert Query.logs_severity_count_query(:fatal) ==
               ~s|in:logs severity_text:(fatal,critical,emergency,alert) time:last_24h stats:"count() as total"|
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
