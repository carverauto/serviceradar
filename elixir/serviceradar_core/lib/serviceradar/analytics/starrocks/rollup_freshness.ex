defmodule ServiceRadar.Analytics.StarRocks.RollupFreshness do
  @moduledoc """
  Guards hourly-rollup reads against stale async materialized views.

  The `*_hourly` views come from `priv/starrocks/0017`, which replaces the
  unpartitioned ones of `0005` and `0016` with views partitioned by day; the
  trace rollups `traces_stats_5m` and `spans_red_1h` from `0022`, and the MTR
  rollups `mtr_hops_hourly` and `mtr_destination_hourly` from `0025` (the
  destination view rebuilt by `0028` for trace/hop event-day alignment), are built
  the same way and gated the same way. They
  use a 30-second schedule after migration `0027`, so a reader must verify the view has
  caught up before trusting it: an unrefreshed view returns short counts with
  no error.

  A recent successful refresh (within 120 seconds, plus the cache TTL) is
  required alongside the view's lag behind its own source table. This catches
  failed refreshes and late rows that bucket maxima alone cannot detect.
  After that health check, a source table holding no rows reads as fresh.
  Any error, empty result, or unparseable
  high-water mark reads as stale, which routes the query to the StarRocks
  raw table, never CNPG.

  Both marks are read on the same grain: `bucket` is `date_trunc('hour', ...)`
  for the hourly views and `time_slice(..., INTERVAL 5 MINUTE)` for
  `traces_stats_5m`, so the source mark is floored to that view's bucket width
  before diffing. The threshold therefore counts whole buckets the view is
  behind -- not the minutes that have elapsed inside the newest bucket, which a
  caught-up view accrues anyway and which would otherwise report it stale for
  most of every bucket.

  The Frontend is queried over the MySQL text protocol and `MySQL.to_postgrex/1`
  passes cells through untouched, so a `DATETIME` arrives as whatever MyXQL
  decoded -- a struct or an ISO8601 binary. Both are accepted, the same shapes
  `LogEventConsumers` already normalizes off this seam; treating a binary as
  unreadable would silently disable every rollup.

  Both probes are bounded to a recent window so StarRocks prunes to the newest
  day partitions instead of scanning a year of them. The source window reaches
  back twice the staleness threshold plus one bucket; a source table with no
  rows inside it has nothing a view could be lagging, so it reads as fresh,
  like an empty table. The view window starts a further threshold before the
  floored source cutoff, which is the oldest bucket a caught-up view can hold,
  so bounding it never turns a fresh verdict stale; it is matched on the view's
  `day` partition column, because a predicate on `bucket` prunes nothing.

  `RollupFreshnessCache` holds each mark for `rollup_cache_ttl_seconds` so the
  queries of one dashboard render share a pair of probes. Callers inject the
  transport with `:query`, the arity-1 seam the readers already use; otherwise
  probes go through `Query.execute/1` like every other statement.

  The gate sits in the request path, so it never raises: a probe or cache
  lookup that throws or exits is logged and read as stale, which routes the
  query to the StarRocks raw table like every other failure here.
  """

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query
  alias ServiceRadar.Analytics.StarRocks.RollupFreshnessCache

  require Logger

  # dataset => {materialized view, source table, source time column, bucket
  # width in minutes}
  @sources %{
    flows: {"ocsf_network_activity_hourly", "ocsf_network_activity", "time", 60},
    metrics: {"timeseries_metrics_hourly", "timeseries_metrics", "timestamp", 60},
    events: {"events_hourly", "events", "time", 60},
    traces_stats: {"traces_stats_5m", "otel_traces", "timestamp", 5},
    traces_red: {"spans_red_1h", "otel_traces", "timestamp", 60},
    mtr_hops: {"mtr_hops_hourly", "mtr_hops", "time", 60},
    # The destination view is built over a join, but its buckets are the trace
    # hours (a row exists for every hour with any trace), so its source mark is
    # mtr_traces' newest row, not the join's.
    mtr_destination: {"mtr_destination_hourly", "mtr_traces", "time", 60}
  }

  @spec dataset_for_sql(term()) :: atom() | nil
  def dataset_for_sql(sql) when is_binary(sql) do
    Enum.find_value(@sources, fn {dataset, {mv, _raw, _column, _grain}} ->
      if String.contains?(sql, Env.table(mv)), do: dataset
    end)
  end

  def dataset_for_sql(_sql), do: nil

  @doc """
  Settles a compiled StarRocks translation against the freshness gate.

  Materialized views refresh on a bounded schedule, so a view the
  compiler actually picked has to be checked before its rows are served: an
  unrefreshed view returns short counts with no error. Only the compiled SQL
  knows whether a rollup was chosen, so this runs after compilation -- a query
  that reads no `_hourly` view costs no round trip. A stale view is recompiled
  through `retranslate` in `starrocks_raw` mode, never against CNPG.
  """
  @spec settle(map(), term(), (String.t() -> {:ok, map()} | {:error, term()})) ::
          {:ok, map(), term()} | {:error, term()}
  def settle(translation, mode, retranslate)

  def settle(%{"sql" => sql} = translation, "starrocks", retranslate) when is_binary(sql) do
    case dataset_for_sql(sql) do
      nil ->
        {:ok, translation, "starrocks"}

      dataset ->
        if fresh?(dataset) do
          {:ok, translation, "starrocks"}
        else
          with {:ok, raw} <- retranslate.("starrocks_raw") do
            {:ok, raw, "starrocks_raw"}
          end
        end
    end
  end

  def settle(translation, mode, _retranslate), do: {:ok, translation, mode}

  @spec stale_after_seconds(keyword()) :: non_neg_integer()
  def stale_after_seconds(opts \\ []) do
    Keyword.get_lazy(opts, :stale_after_seconds, fn ->
      :serviceradar_core
      |> Application.get_env(StarRocks, [])
      |> Keyword.get(:rollup_stale_after_seconds, Env.default_rollup_stale_after_seconds())
    end)
  end

  @spec fresh?(atom(), keyword()) :: boolean()
  def fresh?(dataset, opts \\ [])

  def fresh?(dataset, opts) when is_atom(dataset) and is_list(opts) do
    case Map.get(@sources, dataset) do
      {mv, raw, column, grain} ->
        run = runner(opts)

        refresh_healthy?(run, dataset, mv, opts) and
          caught_up?(run, dataset, mv, raw, column, grain, opts)

      nil ->
        false
    end
  rescue
    error -> stale(dataset, error)
  catch
    :exit, reason -> stale(dataset, reason)
  end

  # Bucket maxima cannot detect a failed refresh or missing late rows within
  # the newest bucket. Scheduled views must also have a recent successful
  # refresh. Probe metadata rather than scanning the raw table a second time.
  # The 30-second schedule has 90 seconds of execution slack. Cache age adds at
  # most its configured TTL. Missing/failed metadata always selects raw SQL.
  defp refresh_healthy?(run, dataset, mv, opts) do
    sql = """
    SELECT IS_ACTIVE, LAST_REFRESH_STATE,
      TIMESTAMPDIFF(SECOND, LAST_REFRESH_START_TIME, CURRENT_TIMESTAMP())
    FROM information_schema.materialized_views
    WHERE TABLE_SCHEMA = '#{Env.config()[:database]}' AND TABLE_NAME = '#{mv}'
    """

    max_age = Keyword.get(opts, :refresh_stale_after_seconds, 120)

    key = {dataset, :refresh, max_age}

    case RollupFreshnessCache.fetch(key) do
      {:ok, value} ->
        value

      :miss ->
        case run.(sql) do
          {:ok, %{rows: [[active, "SUCCESS", age]]}}
          when active in [true, "true", "TRUE", 1] and is_integer(age) ->
            RollupFreshnessCache.put(key, age >= 0 and age <= max_age)

          _ ->
            false
        end
    end
  end

  defp stale(dataset, reason) do
    Logger.warning("RollupFreshness: treating #{dataset} rollup as stale",
      reason: inspect(reason)
    )

    false
  end

  defp caught_up?(run, dataset, mv, raw, column, grain, opts) do
    stale_after = stale_after_seconds(opts)
    {lookback, source_since, view_day} = windows(grain, stale_after)

    raw_sql =
      "SELECT MAX(`#{column}`) FROM #{Env.table(raw)} WHERE `#{column}` >= '#{iso(source_since)}'"

    case high_water(run, {dataset, :raw, lookback}, raw_sql) do
      {:ok, nil} ->
        true

      {:ok, raw_max} ->
        mv_sql =
          "SELECT MAX(`bucket`) FROM #{Env.table(mv)} WHERE `day` >= '#{iso(view_day)}'"

        case high_water(run, {dataset, :mv, lookback}, mv_sql) do
          {:ok, %NaiveDateTime{} = mv_max} ->
            NaiveDateTime.diff(floor_to_grain(raw_max, grain), mv_max) <= stale_after

          _ ->
            false
        end

      :error ->
        false
    end
  end

  # The source window is twice the threshold plus one bucket: a row older than
  # that which a successfully refreshed view has not absorbed is not lag the
  # threshold is meant to catch. A view is fresh when its newest bucket is
  # within `stale_after` of the floored source mark, so the oldest bucket a
  # fresh view can hold for a row inside the window is the floored cutoff
  # minus `stale_after`. Reading the view from that bucket's day returns the
  # exact maximum whenever the verdict could be fresh, and nothing or an older
  # bucket -- stale either way -- when it could not.
  defp windows(grain, stale_after) do
    lookback = 2 * (stale_after + grain * 60)

    source_since =
      DateTime.shift(DateTime.truncate(DateTime.utc_now(), :second), second: -lookback)

    view_day =
      source_since
      |> floor_to_grain(grain)
      |> DateTime.shift(second: -stale_after)
      |> then(&%{&1 | hour: 0, minute: 0, second: 0})

    {lookback, source_since, view_day}
  end

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  # Each mark is cached under the window it was read with, so a call with a
  # different threshold never reuses a mark bounded for another one.
  defp high_water(run, key, sql) do
    case RollupFreshnessCache.fetch(key) do
      {:ok, mark} ->
        mark

      :miss ->
        case probe(run, sql) do
          {:ok, _} = mark -> RollupFreshnessCache.put(key, mark)
          :error -> :error
        end
    end
  end

  defp probe(run, sql) do
    case run.(sql) do
      {:ok, %{rows: [[nil]]}} -> {:ok, nil}
      {:ok, %{rows: [[value]]}} -> to_naive(value)
      _ -> :error
    end
  end

  defp to_naive(%NaiveDateTime{} = value), do: {:ok, value}

  defp to_naive(%DateTime{} = value), do: {:ok, DateTime.to_naive(value)}

  defp to_naive(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> {:ok, naive}
      _ -> :error
    end
  end

  defp to_naive(_value), do: :error

  defp floor_to_grain(%{minute: _} = value, minutes) do
    minute = value.minute - rem(value.minute, minutes)
    %{value | minute: minute, second: 0, microsecond: {0, 0}}
  end

  defp runner(opts) do
    case Keyword.get(opts, :query) do
      fun when is_function(fun, 1) -> fun
      _ -> &Query.execute/1
    end
  end
end
