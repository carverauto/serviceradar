defmodule ServiceRadar.Analytics.StarRocks.RollupFreshness do
  @moduledoc """
  Guards hourly-rollup reads against stale async materialized views.

  The `*_hourly` views come from `priv/starrocks/0017`, which replaces the
  unpartitioned ones of `0005` and `0016` with views partitioned by day; the
  trace rollups `traces_stats_5m` and `spans_red_1h` from `0022`, and the MTR
  rollups `mtr_hops_hourly` and `mtr_destination_hourly` from `0025`, are built
  the same way and gated the same way. They
  are `REFRESH ASYNC` with no schedule, so a reader must verify the view has
  caught up before trusting it: an unrefreshed view returns short counts with
  no error.

  Staleness is the view's lag behind its own source table, never the wall
  clock, so a dataset that simply stopped receiving rows keeps its rollup
  instead of pushing long windows onto a full raw scan. A source table
  holding no rows reads as fresh. Any error, empty result, or unparseable
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

  Hourly materialized views are `REFRESH ASYNC` with no schedule, so a view the
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
        caught_up?(runner(opts), dataset, mv, raw, column, grain, opts)

      nil ->
        false
    end
  rescue
    error -> stale(dataset, error)
  catch
    :exit, reason -> stale(dataset, reason)
  end

  defp stale(dataset, reason) do
    Logger.warning("RollupFreshness: treating #{dataset} rollup as stale",
      reason: inspect(reason)
    )

    false
  end

  defp caught_up?(run, dataset, mv, raw, column, grain, opts) do
    case high_water(run, dataset, :raw, "SELECT MAX(`#{column}`) FROM #{Env.table(raw)}") do
      {:ok, nil} ->
        true

      {:ok, raw_max} ->
        case high_water(run, dataset, :mv, "SELECT MAX(`bucket`) FROM #{Env.table(mv)}") do
          {:ok, %NaiveDateTime{} = mv_max} ->
            NaiveDateTime.diff(floor_to_grain(raw_max, grain), mv_max) <=
              stale_after_seconds(opts)

          _ ->
            false
        end

      :error ->
        false
    end
  end

  defp high_water(run, dataset, kind, sql) do
    case RollupFreshnessCache.fetch({dataset, kind}) do
      {:ok, mark} ->
        mark

      :miss ->
        case probe(run, sql) do
          {:ok, _} = mark -> RollupFreshnessCache.put({dataset, kind}, mark)
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

  defp floor_to_grain(%NaiveDateTime{} = value, minutes) do
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
