defmodule ServiceRadar.Analytics.StarRocks.RollupFreshnessTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.RollupFreshness
  alias ServiceRadar.Analytics.StarRocks.RollupFreshnessCache

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

  # The Frontend answers over the MySQL text protocol and the transport hands
  # cells through untouched, so a DATETIME reaches this check as whatever MyXQL
  # decoded. Reading a binary as unparseable would report every view stale and
  # silently retire the rollup with nothing logged.
  test "a string high-water mark is read, not rejected" do
    kept_up = probes([["1999-06-15 12:00:00"]], [["1999-06-15 12:59:00"]])
    assert RollupFreshness.fresh?(:flows, query: kept_up)

    lagging = probes([["1999-06-15 09:00:00"]], [["1999-06-15 12:59:00"]])
    refute RollupFreshness.fresh?(:flows, query: lagging)

    iso = probes([["1999-06-15T12:00:00Z"]], [["1999-06-15T12:59:00Z"]])
    assert RollupFreshness.fresh?(:flows, query: iso)
  end

  test "a DateTime high-water mark is read too" do
    probe = probes([[~U[1999-06-15 12:00:00Z]]], [[~U[1999-06-15 12:59:00Z]]])
    assert RollupFreshness.fresh?(:flows, query: probe)
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

  # `bucket` is date_trunc('hour', ...), so the source mark is floored to the
  # same grain before diffing. Without that, a view that has fully caught up
  # still shows the minutes elapsed inside the newest bucket as lag, and any
  # threshold under an hour reports it stale for most of every hour.
  test "a caught-up view is fresh even under a sub-hour threshold" do
    probe = probes([[~N[1999-06-15 12:00:00]]], [[~N[1999-06-15 12:44:55]]])
    assert RollupFreshness.fresh?(:flows, query: probe, stale_after_seconds: 900)
  end

  test "a view one whole hour behind is stale under a sub-hour threshold" do
    probe = probes([[~N[1999-06-15 11:00:00]]], [[~N[1999-06-15 12:29:00]]])
    refute RollupFreshness.fresh?(:flows, query: probe, stale_after_seconds: 900)
  end

  test "the staleness threshold is configurable per call" do
    probe = probes([[~N[1999-06-15 09:00:00]]], [[~N[1999-06-15 12:00:00]]])

    assert RollupFreshness.fresh?(:flows, query: probe, stale_after_seconds: 11_000)
    refute RollupFreshness.fresh?(:flows, query: probe, stale_after_seconds: 3_000)
  end

  describe "with the high-water cache running" do
    setup do
      start_supervised!(%{
        id: RollupFreshnessCache,
        start: {RollupFreshnessCache, :start_link, [[]]}
      })

      :ok
    end

    # Both probes are unbounded aggregates over the warehouse's largest
    # partitioned tables, and one dashboard render fires several rollup-eligible
    # queries. Without amortization each chart pays its own pair.
    test "queries within the cache window share one pair of probes" do
      parent = self()
      mv = flows_mv_sql()
      raw = flows_raw_sql()

      probe = fn
        ^mv ->
          send(parent, :mv_probe)
          result([[~N[1999-06-15 12:00:00]]])

        ^raw ->
          send(parent, :raw_probe)
          result([[~N[1999-06-15 12:30:00]]])
      end

      assert RollupFreshness.fresh?(:flows, query: probe)
      assert RollupFreshness.fresh?(:flows, query: probe)
      assert RollupFreshness.fresh?(:flows, query: probe)

      assert_received :raw_probe
      assert_received :mv_probe
      refute_received :raw_probe
      refute_received :mv_probe
    end

    test "each dataset caches its own marks" do
      parent = self()

      probe = fn sql ->
        send(parent, {:probe, sql})

        if sql =~ "_hourly" do
          result([[~N[1999-06-15 12:00:00]]])
        else
          result([[~N[1999-06-15 12:30:00]]])
        end
      end

      assert RollupFreshness.fresh?(:flows, query: probe)
      assert RollupFreshness.fresh?(:events, query: probe)

      assert_received {:probe, flows_raw}
      assert flows_raw =~ "ocsf_network_activity"
      assert_received {:probe, flows_mv}
      assert flows_mv =~ "ocsf_network_activity_hourly"
      assert_received {:probe, events_raw}
      assert events_raw =~ "events"
      assert_received {:probe, events_mv}
      assert events_mv =~ "events_hourly"
    end

    # A cached failure would hold the rollup shut for the whole window after a
    # single timeout, which is the outcome the gate exists to avoid.
    test "a failed probe is not cached, so the next query retries it" do
      attempts = :counters.new(1, [])
      mv = flows_mv_sql()
      raw = flows_raw_sql()

      probe = fn
        ^raw ->
          :counters.add(attempts, 1, 1)

          if :counters.get(attempts, 1) == 1 do
            {:error, :connect_failed}
          else
            result([[~N[1999-06-15 12:30:00]]])
          end

        ^mv ->
          result([[~N[1999-06-15 12:00:00]]])
      end

      refute RollupFreshness.fresh?(:flows, query: probe)
      assert RollupFreshness.fresh?(:flows, query: probe)
    end
  end

  # The gate runs inside the request path, between compiling a query and
  # submitting it. A probe or cache lookup that throws has to read as stale --
  # routing the query to the StarRocks raw table -- rather than take the
  # dashboard render down with it.
  test "a raising probe reads as stale instead of propagating" do
    probe = fn _sql -> raise "frontend exploded" end

    assert ExUnit.CaptureLog.capture_log(fn ->
             refute RollupFreshness.fresh?(:flows, query: probe)
           end) =~ "treating flows rollup as stale"
  end

  test "a probe that exits reads as stale instead of propagating" do
    probe = fn _sql -> exit(:timeout) end

    assert ExUnit.CaptureLog.capture_log(fn ->
             refute RollupFreshness.fresh?(:flows, query: probe)
           end) =~ "treating flows rollup as stale"
  end

  describe "cache ttl" do
    setup do
      previous = Application.get_env(:serviceradar_core, StarRocks, [])
      on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous) end)

      start_supervised!(%{
        id: RollupFreshnessCache,
        start: {RollupFreshnessCache, :start_link, [[]]}
      })

      %{previous: previous}
    end

    # 0 means never reuse a mark, so every query pays its own pair of probes.
    # Serving a cached verdict under that setting is the one thing it forbids.
    test "a zero ttl disables reuse so every query probes", %{previous: previous} do
      Application.put_env(
        :serviceradar_core,
        StarRocks,
        Keyword.put(previous, :rollup_cache_ttl_seconds, 0)
      )

      parent = self()
      mv = flows_mv_sql()
      raw = flows_raw_sql()

      probe = fn
        ^mv ->
          send(parent, :mv_probe)
          result([[~N[1999-06-15 12:00:00]]])

        ^raw ->
          send(parent, :raw_probe)
          result([[~N[1999-06-15 12:30:00]]])
      end

      assert RollupFreshness.fresh?(:flows, query: probe)
      assert RollupFreshness.fresh?(:flows, query: probe)

      assert_received :raw_probe
      assert_received :mv_probe
      assert_received :raw_probe
      assert_received :mv_probe
    end

    test "a configured ttl is what the cache stores marks for", %{previous: previous} do
      Application.put_env(
        :serviceradar_core,
        StarRocks,
        Keyword.put(previous, :rollup_cache_ttl_seconds, 7)
      )

      assert RollupFreshnessCache.ttl_seconds() == 7
    end

    test "an unconfigured ttl is the shipped default", %{previous: previous} do
      Application.put_env(
        :serviceradar_core,
        StarRocks,
        Keyword.delete(previous, :rollup_cache_ttl_seconds)
      )

      assert RollupFreshnessCache.ttl_seconds() == Env.default_rollup_cache_ttl_seconds()
    end
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
