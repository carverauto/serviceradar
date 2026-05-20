defmodule ServiceRadarWebNGWeb.StatsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Stats
  alias ServiceRadarWebNGWeb.Stats.Query

  describe "log severity query helpers" do
    test "include title case variants used by direct log rows" do
      assert "Critical" in Query.log_severity_values(:fatal)
      assert "Debug" in Query.log_severity_values(:debug)
      assert "Warning" in Query.log_severity_values(:warning)
      assert "Notice" in Query.log_severity_values(:info)
      assert "Error" in Query.log_severity_values(:error)
    end

    test "builds click-through queries from shared severity groups" do
      assert Query.logs_severity_data_query(:debug, limit: 100) ==
               "in:logs severity_text:(debug,DEBUG,Debug,trace,TRACE,Trace) time:last_24h sort:timestamp:desc limit:100"

      assert Query.logs_severity_data_query([:fatal, :error]) =~ "Critical"
      assert Query.logs_severity_data_query([:fatal, :error]) =~ "Err"
    end

    test "builds fallback count queries from the same severity groups" do
      assert Query.logs_severity_count_query(:fatal) ==
               ~s|in:logs severity_text:(fatal,FATAL,Fatal,critical,CRITICAL,Critical,emergency,EMERGENCY,Emergency,alert,ALERT,Alert) time:last_24h stats:"count() as total"|
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
