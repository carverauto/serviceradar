defmodule ServiceRadar.Analytics.StarRocks.RollupFreshnessTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.RollupFreshness

  @moduletag :db_free

  defp flows_mv_sql, do: "SELECT MAX(`bucket`) FROM #{Env.table("ocsf_network_activity_hourly")}"
  defp flows_raw_sql, do: "SELECT MAX(`time`) FROM #{Env.table("ocsf_network_activity")}"

  defp result(rows) do
    {:ok,
     %Postgrex.Result{
       command: :select,
       columns: ["max"],
       rows: rows,
       num_rows: length(rows),
       connection_id: nil
     }}
  end

  # Answers the two high-water-mark probes the check issues: the view's newest
  # bucket and the newest row in the table that view aggregates.
  defp probes(mv_rows, raw_rows) do
    mv = flows_mv_sql()
    raw = flows_raw_sql()

    fn
      ^mv -> result(mv_rows)
      ^raw -> result(raw_rows)
    end
  end

  test "a view that has kept up with its source table reads as fresh" do
    probe = probes([[~N[1999-06-15 12:00:00]]], [[~N[1999-06-15 12:59:00]]])
    assert RollupFreshness.fresh?(:flows, query: probe)
  end

  test "a view lagging its source table past the threshold reads as stale" do
    probe = probes([[~N[1999-06-15 09:00:00]]], [[~N[1999-06-15 12:59:00]]])
    refute RollupFreshness.fresh?(:flows, query: probe)
  end

  # The signal is lag behind the source table, not the wall clock: a dataset
  # that stopped receiving rows hours ago keeps its rollup instead of pushing
  # every long-window chart onto a full raw scan.
  test "an idle dataset stays on its rollup no matter how old the newest row is" do
    probe = probes([[~N[1999-06-15 03:00:00]]], [[~N[1999-06-15 03:30:00]]])
    assert RollupFreshness.fresh?(:flows, query: probe)
  end

  test "a source table with no rows at all reads as fresh" do
    probe = probes([[nil]], [[nil]])
    assert RollupFreshness.fresh?(:flows, query: probe)
  end

  test "an empty view over a populated source table reads as stale" do
    probe = probes([[nil]], [[~N[1999-06-15 12:00:00]]])
    refute RollupFreshness.fresh?(:flows, query: probe)
  end

  test "a probe returning no rows fails closed to stale" do
    probe = fn _sql -> result([]) end
    refute RollupFreshness.fresh?(:flows, query: probe)
  end

  test "an unparseable high-water mark fails closed to stale" do
    probe = probes([["not-a-timestamp"]], [[~N[1999-06-15 12:00:00]]])
    refute RollupFreshness.fresh?(:flows, query: probe)
  end

  test "a failed freshness probe fails closed to stale" do
    probe = fn _sql -> {:error, :connect_failed} end
    refute RollupFreshness.fresh?(:flows, query: probe)
  end

  test "an unknown dataset reads as stale and issues no probe" do
    probe = fn sql -> flunk("unknown dataset must not probe StarRocks: #{sql}") end
    refute RollupFreshness.fresh?(:unknown_dataset, query: probe)
  end

  test "metrics and events probe their own source table and time column" do
    metrics = fn
      "SELECT MAX(`bucket`) FROM " <> _ = sql ->
        assert sql =~ "timeseries_metrics_hourly"
        result([[~N[1999-06-15 12:00:00]]])

      sql ->
        assert sql == "SELECT MAX(`timestamp`) FROM #{Env.table("timeseries_metrics")}"
        result([[~N[1999-06-15 12:30:00]]])
    end

    assert RollupFreshness.fresh?(:metrics, query: metrics)

    events = fn
      "SELECT MAX(`bucket`) FROM " <> _ = sql ->
        assert sql =~ "events_hourly"
        result([[~N[1999-06-15 12:00:00]]])

      sql ->
        assert sql == "SELECT MAX(`time`) FROM #{Env.table("events")}"
        result([[~N[1999-06-15 12:30:00]]])
    end

    assert RollupFreshness.fresh?(:events, query: events)
  end

  test "the staleness threshold is configurable per call" do
    probe = probes([[~N[1999-06-15 09:00:00]]], [[~N[1999-06-15 12:00:00]]])

    assert RollupFreshness.fresh?(:flows, query: probe, stale_after_seconds: 11_000)
    refute RollupFreshness.fresh?(:flows, query: probe, stale_after_seconds: 3_000)
  end

  test "the :mysql seam still reaches the probe when no :query fun is injected" do
    probe = probes([[~N[1999-06-15 12:00:00]]], [[~N[1999-06-15 12:30:00]]])
    assert RollupFreshness.fresh?(:flows, mysql: probe)
  end

  test "the compiled SQL names the dataset whose rollup it reads" do
    assert RollupFreshness.dataset_for_sql(
             "SELECT bucket FROM #{Env.table("ocsf_network_activity_hourly")}"
           ) == :flows

    assert RollupFreshness.dataset_for_sql(
             "SELECT bucket FROM #{Env.table("timeseries_metrics_hourly")}"
           ) == :metrics

    assert RollupFreshness.dataset_for_sql("SELECT bucket FROM #{Env.table("events_hourly")}") ==
             :events

    assert RollupFreshness.dataset_for_sql(
             "SELECT `time` FROM #{Env.table("ocsf_network_activity")}"
           ) == nil

    assert RollupFreshness.dataset_for_sql(nil) == nil
  end
end
