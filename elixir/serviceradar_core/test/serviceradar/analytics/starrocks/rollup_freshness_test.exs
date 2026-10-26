defmodule ServiceRadar.Analytics.StarRocks.RollupFreshnessTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.RollupFreshness
  alias ServiceRadar.Analytics.StarRocks.RollupFreshnessCache

  @moduletag :db_free

  defp flows_mv_sql, do: mv_sql("ocsf_network_activity_hourly")
  defp flows_raw_sql, do: raw_sql("ocsf_network_activity", "time")

  # Each probe's statement, without the time bound it carries.
  defp mv_sql(view), do: "SELECT MAX(`bucket`) FROM #{Env.table(view)}"
  defp raw_sql(table, column), do: "SELECT MAX(`#{column}`) FROM #{Env.table(table)}"

  # Answers each probe by which statement it is, whatever bound it carries.
  defp route(sql, routes) do
    case Enum.find(routes, fn {prefix, _answer} -> String.starts_with?(sql, prefix) end) do
      {_prefix, answer} -> answer.()
      nil -> flunk("unexpected probe: #{sql}")
    end
  end

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
    healthy_refresh(fn sql ->
      route(sql, [
        {flows_mv_sql(), fn -> result(mv_rows) end},
        {flows_raw_sql(), fn -> result(raw_rows) end}
      ])
    end)
  end

  defp healthy_refresh(query) do
    fn sql ->
      if String.contains?(sql, "information_schema.materialized_views"),
        do: result([["true", "SUCCESS", 15]]),
        else: query.(sql)
    end
  end

  # Reports each flows probe to `parent` as it is issued.
  defp counted_probe(parent) do
    fn sql ->
      route(sql, [
        {flows_mv_sql(),
         fn ->
           send(parent, :mv_probe)
           result([[~N[1999-06-15 12:00:00]]])
         end},
        {flows_raw_sql(),
         fn ->
           send(parent, :raw_probe)
           result([[~N[1999-06-15 12:30:00]]])
         end}
      ])
    end
  end

  test "a scheduled view fails closed after a stale or failed refresh within the same bucket" do
    for metadata <- [
          [["true", "FAILED", 10]],
          [["true", "SUCCESS", 121]],
          [["false", "SUCCESS", 5]],
          []
        ] do
      query = fn sql ->
        if String.contains?(sql, "information_schema.materialized_views"),
          do: result(metadata),
          else: flunk("unhealthy view must select raw before high-water probes")
      end

      refute RollupFreshness.fresh?(:flows, query: query)
    end
  end

  test "a view that has kept up with its source table reads as fresh" do
    probe = probes([[~N[1999-06-15 12:00:00]]], [[~N[1999-06-15 12:59:00]]])
    assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
  end

  test "a view lagging its source table past the threshold reads as stale" do
    probe = probes([[~N[1999-06-15 09:00:00]]], [[~N[1999-06-15 12:59:00]]])
    refute RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
  end

  # The signal is lag behind the source table, not the wall clock: a dataset
  # that stopped receiving rows hours ago keeps its rollup instead of pushing
  # every long-window chart onto a full raw scan.
  test "an idle dataset stays on its rollup no matter how old the newest row is" do
    probe = probes([[~N[1999-06-15 03:00:00]]], [[~N[1999-06-15 03:30:00]]])
    assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
  end

  test "a source table with no rows at all reads as fresh" do
    probe = probes([[nil]], [[nil]])
    assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
  end

  test "an empty view over a populated source table reads as stale" do
    probe = probes([[nil]], [[~N[1999-06-15 12:00:00]]])
    refute RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
  end

  test "a probe returning no rows fails closed to stale" do
    probe = fn _sql -> result([]) end
    refute RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
  end

  test "an unparseable high-water mark fails closed to stale" do
    probe = probes([["not-a-timestamp"]], [[~N[1999-06-15 12:00:00]]])
    refute RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
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
    assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
  end

  test "a failed freshness probe fails closed to stale" do
    probe = fn _sql -> {:error, :connect_failed} end
    refute RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
  end

  test "an unknown dataset reads as stale and issues no probe" do
    probe = fn sql -> flunk("unknown dataset must not probe StarRocks: #{sql}") end
    refute RollupFreshness.fresh?(:unknown_dataset, query: healthy_refresh(probe))
  end

  test "metrics and events probe their own source table and time column" do
    metrics = fn sql ->
      route(sql, [
        {mv_sql("timeseries_metrics_hourly"), fn -> result([[~N[1999-06-15 12:00:00]]]) end},
        {raw_sql("timeseries_metrics", "timestamp"),
         fn -> result([[~N[1999-06-15 12:30:00]]]) end}
      ])
    end

    assert RollupFreshness.fresh?(:metrics, query: healthy_refresh(metrics))

    events = fn sql ->
      route(sql, [
        {mv_sql("events_hourly"), fn -> result([[~N[1999-06-15 12:00:00]]]) end},
        {raw_sql("events", "time"), fn -> result([[~N[1999-06-15 12:30:00]]]) end}
      ])
    end

    assert RollupFreshness.fresh?(:events, query: healthy_refresh(events))
  end

  # `bucket` is date_trunc('hour', ...), so the source mark is floored to the
  # same grain before diffing. Without that, a view that has fully caught up
  # still shows the minutes elapsed inside the newest bucket as lag, and any
  # threshold under an hour reports it stale for most of every hour.
  test "a caught-up view is fresh even under a sub-hour threshold" do
    probe = probes([[~N[1999-06-15 12:00:00]]], [[~N[1999-06-15 12:44:55]]])
    assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe), stale_after_seconds: 900)
  end

  test "a view one whole hour behind is stale under a sub-hour threshold" do
    probe = probes([[~N[1999-06-15 11:00:00]]], [[~N[1999-06-15 12:29:00]]])
    refute RollupFreshness.fresh?(:flows, query: healthy_refresh(probe), stale_after_seconds: 900)
  end

  # `traces_stats_5m` buckets on a 5-minute slice, not the hour, so its source
  # mark is floored to the 5-minute boundary. With an hourly floor a view whose
  # newest bucket is only the first slice of the current hour reads 0 seconds
  # behind and serves an undercount with no error, which is the short-count
  # case this gate exists to send to the raw fallback.
  defp traces_stats_probe(mv_rows, raw_rows) do
    fn sql ->
      route(sql, [
        {mv_sql("traces_stats_5m"), fn -> result(mv_rows) end},
        {raw_sql("otel_traces", "timestamp"), fn -> result(raw_rows) end}
      ])
    end
  end

  test "the 5-minute traces_stats view floors its source mark to its own grain" do
    probe = traces_stats_probe([[~N[1999-06-15 14:55:00]]], [[~N[1999-06-15 14:58:00]]])

    assert RollupFreshness.fresh?(:traces_stats,
             query: healthy_refresh(probe),
             stale_after_seconds: 0
           )
  end

  test "a 5-minute view whose newest bucket is only the first slice reads as stale" do
    # Spans run through 14:58 but only the 14:00-14:05 slice is loaded. The
    # hourly floor would call this fresh; the 5-minute floor reports the 55
    # minutes of missing slices as lag.
    probe = traces_stats_probe([[~N[1999-06-15 14:00:00]]], [[~N[1999-06-15 14:58:00]]])

    refute RollupFreshness.fresh?(:traces_stats,
             query: healthy_refresh(probe),
             stale_after_seconds: 0
           )
  end

  test "the staleness threshold is configurable per call" do
    probe = probes([[~N[1999-06-15 09:00:00]]], [[~N[1999-06-15 12:00:00]]])

    assert RollupFreshness.fresh?(:flows,
             query: healthy_refresh(probe),
             stale_after_seconds: 11_000
           )

    refute RollupFreshness.fresh?(:flows,
             query: healthy_refresh(probe),
             stale_after_seconds: 3_000
           )
  end

  describe "bounded probes" do
    # Every gated dataset: the source table, the column it is partitioned on,
    # and the view's bucket width in seconds. Each view is partitioned on `day`.
    @gated [
      flows: {"ocsf_network_activity", "time", 3_600},
      metrics: {"timeseries_metrics", "timestamp", 3_600},
      events: {"events", "time", 3_600},
      traces_stats: {"otel_traces", "timestamp", 300},
      traces_red: {"otel_traces", "timestamp", 3_600},
      mtr_hops: {"mtr_hops", "time", 3_600},
      mtr_destination: {"mtr_traces", "time", 3_600}
    ]

    # An unbounded MAX reads every partition the table retains, which on a
    # year of events costs seconds on each cold page load. A bound on the
    # partition column lets StarRocks read only the newest days; one on
    # `bucket` would prune none of a view's `day` partitions.
    test "every probe reads only recent partitions, on the column they are split by" do
      stale_after = RollupFreshness.stale_after_seconds()

      for {dataset, {table, column, grain}} <- @gated do
        parent = self()

        probe = fn sql ->
          send(parent, {:probe, sql})
          result([[NaiveDateTime.utc_now()]])
        end

        now = DateTime.utc_now()
        RollupFreshness.fresh?(dataset, query: healthy_refresh(probe))
        sqls = drain_probes()

        source_sql = Enum.find(sqls, &String.starts_with?(&1, raw_sql(table, column)))
        view_sql = Enum.find(sqls, &String.starts_with?(&1, "SELECT MAX(`bucket`) FROM "))

        source_since = lower_bound!(source_sql, "#{raw_sql(table, column)} WHERE `#{column}` >= ")

        assert view_sql =~ " WHERE `day` >= '",
               "#{dataset} view probe does not bound its day partitions: #{view_sql}"

        view_since = lower_bound!(view_sql, "SELECT MAX(`bucket`) FROM ")

        # The window covers the threshold plus a bucket, so a dataset idle for
        # less than that is still compared, and stays within two days.
        lookback = DateTime.diff(now, source_since)
        assert lookback >= stale_after + grain, "#{dataset} window #{lookback}s"
        assert lookback < 2 * 86_400, "#{dataset} window #{lookback}s"

        # The view is read from a day boundary at or before the oldest bucket a
        # fresh view can hold for a source row at the window's edge.
        floored = DateTime.from_unix!(div(DateTime.to_unix(source_since), grain) * grain)
        assert %{hour: 0, minute: 0, second: 0} = view_since
        assert DateTime.compare(view_since, DateTime.shift(floored, second: -stale_after)) != :gt
      end
    end

    test "a dataset whose newest row predates the window reads as fresh" do
      now = NaiveDateTime.utc_now()

      assert RollupFreshness.fresh?(:flows,
               query: warehouse([ago(now, 3 * 86_400)], [ago(now, 5 * 86_400)])
             )
    end

    test "source rows inside the window with no view rows inside it read as stale" do
      now = NaiveDateTime.utc_now()

      refute RollupFreshness.fresh?(:flows,
               query: warehouse([ago(now, 600)], [ago(now, 3 * 86_400)])
             )
    end

    # A source row at the shortest window the bound promises, against the
    # oldest view bucket the threshold accepts for it: bounding the view must
    # not hide that bucket, and one bucket older is still lag.
    test "the verdict at the window's edge matches an unbounded comparison" do
      stale_after = RollupFreshness.stale_after_seconds()
      edge = ago(NaiveDateTime.utc_now(), stale_after + 3_600)
      oldest_fresh = ago(floor_hour(edge), stale_after)

      assert RollupFreshness.fresh?(:flows, query: warehouse([edge], [oldest_fresh]))
      refute RollupFreshness.fresh?(:flows, query: warehouse([edge], [ago(oldest_fresh, 3_600)]))
    end
  end

  defp drain_probes(acc \\ []) do
    receive do
      {:probe, sql} -> drain_probes([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp lower_bound!(sql, prefix) do
    assert is_binary(sql) and String.starts_with?(sql, prefix),
           "unbounded or misplaced probe: #{inspect(sql)}"

    [_, literal] = Regex.run(~r/>= '([^']+)'/, sql)
    {:ok, since, 0} = DateTime.from_iso8601(literal)
    since
  end

  defp ago(%NaiveDateTime{} = at, seconds),
    do: at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.add(-seconds)

  defp floor_hour(%NaiveDateTime{} = at), do: %{at | minute: 0, second: 0, microsecond: {0, 0}}

  # A stand-in for the warehouse holding the given flows rows and view
  # buckets. Each probe is answered from them honouring the lower bound it
  # carries -- on the source column for the table, on `day` for the view --
  # and an unbounded probe sees every row.
  defp warehouse(source_rows, view_buckets) do
    healthy_refresh(fn sql ->
      since =
        case Regex.run(~r/>= '([^']+)'/, sql) do
          [_, literal] ->
            {:ok, since, 0} = DateTime.from_iso8601(literal)
            DateTime.to_naive(since)

          nil ->
            nil
        end

      route(sql, [
        {flows_mv_sql(),
         fn -> newest(view_buckets, since, &NaiveDateTime.beginning_of_day/1) end},
        {flows_raw_sql(), fn -> newest(source_rows, since, & &1) end}
      ])
    end)
  end

  defp newest(rows, since, partition_key) do
    kept =
      if since,
        do: Enum.filter(rows, &(NaiveDateTime.compare(partition_key.(&1), since) != :lt)),
        else: rows

    result([[Enum.max(kept, NaiveDateTime, fn -> nil end)]])
  end

  describe "with the high-water cache running" do
    setup do
      start_supervised!(%{
        id: RollupFreshnessCache,
        start: {RollupFreshnessCache, :start_link, [[]]}
      })

      :ok
    end

    # One dashboard render fires several rollup-eligible queries. Without
    # amortization each chart pays its own pair of probes.
    test "queries within the cache window share one pair of probes" do
      probe = counted_probe(self())

      assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
      assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
      assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))

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

      assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
      assert RollupFreshness.fresh?(:events, query: healthy_refresh(probe))

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

      raw = fn ->
        :counters.add(attempts, 1, 1)

        if :counters.get(attempts, 1) == 1 do
          {:error, :connect_failed}
        else
          result([[~N[1999-06-15 12:30:00]]])
        end
      end

      probe = fn sql ->
        route(sql, [
          {flows_raw_sql(), raw},
          {flows_mv_sql(), fn -> result([[~N[1999-06-15 12:00:00]]]) end}
        ])
      end

      refute RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
      assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
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

      probe = counted_probe(self())

      assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))
      assert RollupFreshness.fresh?(:flows, query: healthy_refresh(probe))

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

    assert RollupFreshness.dataset_for_sql("SELECT bucket FROM #{Env.table("traces_stats_5m")}") ==
             :traces_stats

    assert RollupFreshness.dataset_for_sql("SELECT bucket FROM #{Env.table("spans_red_1h")}") ==
             :traces_red

    assert RollupFreshness.dataset_for_sql("SELECT bucket FROM #{Env.table("mtr_hops_hourly")}") ==
             :mtr_hops

    assert RollupFreshness.dataset_for_sql(
             "SELECT bucket FROM #{Env.table("mtr_destination_hourly")}"
           ) ==
             :mtr_destination

    # The raw-hop fallback names no rollup, so it is never gated.
    assert RollupFreshness.dataset_for_sql("SELECT `time` FROM #{Env.table("mtr_hops")}") == nil

    # The raw-span fallback names no rollup, so it is never gated.
    assert RollupFreshness.dataset_for_sql("SELECT `timestamp` FROM #{Env.table("otel_traces")}") ==
             nil

    assert RollupFreshness.dataset_for_sql(
             "SELECT `time` FROM #{Env.table("ocsf_network_activity")}"
           ) == nil

    assert RollupFreshness.dataset_for_sql(nil) == nil
  end
end
