defmodule ServiceRadar.Analytics.StarRocks.RollupFreshness do
  @moduledoc """
  Guards hourly-rollup reads against stale async materialized views.

  The `*_hourly` views in `priv/starrocks/0005` are `REFRESH ASYNC` with no
  schedule, so a reader must verify the view has caught up before trusting
  it: an unrefreshed view returns short counts with no error. `fresh?/2`
  compares `MAX(bucket)` against the wall clock and fails closed -- any
  error, empty view, or unparseable timestamp reads as stale, which routes
  the query to the StarRocks raw table, never CNPG.
  """

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query

  @mv_for %{
    flows: "ocsf_network_activity_hourly",
    metrics: "timeseries_metrics_hourly",
    events: "events_hourly"
  }

  @default_stale_after_seconds 7_200

  @spec mv_for(atom()) :: String.t() | nil
  def mv_for(dataset) when is_atom(dataset), do: Map.get(@mv_for, dataset)

  @spec stale_after_seconds(keyword()) :: pos_integer()
  def stale_after_seconds(opts \\ []) do
    Keyword.get_lazy(opts, :stale_after_seconds, fn ->
      :serviceradar_core
      |> Application.get_env(StarRocks, [])
      |> Keyword.get(:rollup_stale_after_seconds, @default_stale_after_seconds)
    end)
  end

  @spec fresh?(atom(), keyword()) :: boolean()
  def fresh?(dataset, opts \\ [])

  def fresh?(dataset, opts) when is_atom(dataset) and is_list(opts) do
    # :now and :stale_after_seconds steer this check; only :mysql (and app
    # env) belong to the query layer.
    query_opts = Keyword.drop(opts, [:now, :stale_after_seconds])

    with mv when is_binary(mv) <- mv_for(dataset),
         sql = "SELECT MAX(`bucket`) FROM #{Env.table(mv)}",
         {:ok, %{rows: [[max]]}} <- Query.execute(sql, query_opts),
         {:ok, lag} <- lag_seconds(max, opts) do
      lag <= stale_after_seconds(opts)
    else
      _ -> false
    end
  end

  defp lag_seconds(%NaiveDateTime{} = max, opts) do
    now =
      case Keyword.get(opts, :now) do
        %NaiveDateTime{} = now -> now
        _ -> NaiveDateTime.utc_now()
      end

    {:ok, NaiveDateTime.diff(now, max)}
  end

  defp lag_seconds(_max, _opts), do: :error
end
