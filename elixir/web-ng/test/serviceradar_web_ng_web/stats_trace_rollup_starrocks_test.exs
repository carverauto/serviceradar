defmodule ServiceRadarWebNGWeb.StatsTraceRollupStarRocksTest do
  # With the warehouse enabled, spans, trace summaries and the trace rollup are
  # stored there only, so the rollup health card must read them there: the CNPG
  # relations stop receiving rows at the switch and would report a growing lag.
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNGWeb.Stats

  @moduletag :db_free

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    Application.put_env(:serviceradar_core, StarRocks, Keyword.put(prev, :enabled, true))
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
  end

  defp warehouse(marks) do
    test = self()

    fn sql ->
      send(test, {:sql, sql})

      Enum.find_value(marks, {:error, :unexpected_sql}, fn {table, reply} ->
        if sql =~ "serviceradar.#{table} ", do: reply
      end)
    end
  end

  test "reads the latest span, summary and rollup marks from the warehouse" do
    query =
      warehouse([
        {"otel_traces", {:ok, %{rows: [[~N[2026-01-15 10:00:00]]]}}},
        {"otel_trace_summaries", {:ok, %{rows: [["2026-01-15 09:59:30"]]}}},
        {"traces_stats_5m", {:ok, %{rows: [[~N[2026-01-15 09:55:00]]]}}}
      ])

    status = Stats.trace_rollup_status(query: query)

    assert status.healthy?
    assert status.raw_latest_timestamp == ~U[2026-01-15 10:00:00Z]
    assert status.summary_latest_timestamp == ~U[2026-01-15 09:59:30Z]
    assert status.rollup_latest_bucket == ~U[2026-01-15 09:55:00Z]

    for _probe <- 1..3 do
      assert_received {:sql, sql}
      assert sql =~ "SELECT MAX("
      refute sql =~ "NOW()"
      refute sql =~ "platform."
    end
  end

  test "reports a lagging summary table, and a relation the warehouse cannot read as missing" do
    query =
      warehouse([
        {"otel_traces", {:ok, %{rows: [[~N[2026-01-15 10:00:00]]]}}},
        {"otel_trace_summaries", {:ok, %{rows: [[~N[2026-01-15 08:00:00]]]}}},
        {"traces_stats_5m", {:error, {:starrocks_mysql, "Unknown table"}}}
      ])

    status = Stats.trace_rollup_status(query: query, stale_threshold_seconds: 1_800)

    refute status.healthy?
    refute status.traces_rollup_present?
    assert status.summary_lag_seconds == 7_200
    assert Enum.any?(status.messages, &(&1 =~ "Trace summaries lag raw traces"))
  end
end
