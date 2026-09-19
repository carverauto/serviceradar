defmodule ServiceRadar.Analytics.StarRocks.RollupFreshness do
  @moduledoc """
  Guards hourly-rollup reads against stale async materialized views.

  The `*_hourly` views in `priv/starrocks/0005` are `REFRESH ASYNC` with no
  schedule, so a reader must verify the view has caught up before trusting
  it: an unrefreshed view returns short counts with no error.

  Staleness is the view's lag behind its own source table --
  `MAX(raw.<time column>) - MAX(mv.bucket)` -- never the wall clock, so a
  dataset that simply stopped receiving rows keeps its rollup instead of
  pushing long windows onto a full raw scan. A source table holding no rows
  reads as fresh. Any error, empty result, or non-timestamp high-water mark
  reads as stale, which routes the query to the StarRocks raw table, never
  CNPG.

  Callers inject the transport with `:query` (the arity-1 seam the readers
  already use) or `:mysql`; both reach the same Frontend pool in production.
  """

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query

  # dataset => {materialized view, source table, source time column}
  @sources %{
    flows: {"ocsf_network_activity_hourly", "ocsf_network_activity", "time"},
    metrics: {"timeseries_metrics_hourly", "timeseries_metrics", "timestamp"},
    events: {"events_hourly", "events", "time"}
  }

  @spec dataset_for_sql(term()) :: atom() | nil
  def dataset_for_sql(sql) when is_binary(sql) do
    Enum.find_value(@sources, fn {dataset, {mv, _raw, _column}} ->
      if String.contains?(sql, Env.table(mv)), do: dataset
    end)
  end

  def dataset_for_sql(_sql), do: nil

  @spec stale_after_seconds(keyword()) :: pos_integer()
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
      {mv, raw, column} -> caught_up?(runner(opts), mv, raw, column, opts)
      nil -> false
    end
  end

  defp caught_up?(run, mv, raw, column, opts) do
    case max_timestamp(run, "SELECT MAX(`#{column}`) FROM #{Env.table(raw)}") do
      {:ok, nil} ->
        true

      {:ok, raw_max} ->
        case max_timestamp(run, "SELECT MAX(`bucket`) FROM #{Env.table(mv)}") do
          {:ok, %NaiveDateTime{} = mv_max} ->
            NaiveDateTime.diff(raw_max, mv_max) <= stale_after_seconds(opts)

          _ ->
            false
        end

      :error ->
        false
    end
  end

  defp max_timestamp(run, sql) do
    case run.(sql) do
      {:ok, %{rows: [[nil]]}} -> {:ok, nil}
      {:ok, %{rows: [[%NaiveDateTime{} = max]]}} -> {:ok, max}
      _ -> :error
    end
  end

  defp runner(opts) do
    case Keyword.get(opts, :query) do
      fun when is_function(fun, 1) ->
        fun

      _ ->
        query_opts = Keyword.take(opts, [:mysql])
        &Query.execute(&1, query_opts)
    end
  end
end
