defmodule ServiceRadar.Observability.CaggRefreshHazards do
  @moduledoc """
  Finds continuous aggregates whose refresh window reaches at or past their raw
  source's retention boundary.

  That configuration DELETES materialized history: `drop_chunks` plants
  invalidations, and a policy refresh that covers a dropped-chunk region
  recomputes those buckets from absent raw rows (verified on TimescaleDB
  2.24.0). `DataRetentionWorker` clamps the refresh windows it manages and
  reports what this check still finds on every deployment. The check only
  reads the Timescale catalog; it never changes a policy.
  """

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Repo

  @query_timeout_ms 120_000

  @type hazard :: %{
          view: String.t(),
          source: String.t(),
          refresh_start: String.t(),
          source_retention: String.t() | nil
        }

  @doc """
  Continuous aggregates in `platform` whose refresh `start_offset` reaches
  their source's retention.

  The source retention is its in-database retention policy when one exists.
  Otherwise it is the window in `worker_windows` (`%{table => days}`), the
  retention `DataRetentionWorker` drops that hypertable's chunks by itself. A
  source with neither drops nothing, so it is never a hazard. An unreadable
  catalog returns `[]`.
  """
  @spec list(%{optional(String.t()) => pos_integer()}) :: [hazard()]
  def list(worker_windows) when is_map(worker_windows) do
    sql = """
    SELECT agg.view_name,
           agg.hypertable_name AS source,
           refresh.config->>'start_offset' AS refresh_start,
           retention.config->>'drop_after' AS source_retention,
           CASE
             WHEN retention.config IS NOT NULL
              AND (refresh.config->>'start_offset')::interval >=
                  (retention.config->>'drop_after')::interval
             THEN true
             ELSE false
           END AS policy_hazard
    FROM timescaledb_information.continuous_aggregates agg
    JOIN timescaledb_information.jobs refresh
      ON refresh.proc_name = 'policy_refresh_continuous_aggregate'
     AND refresh.hypertable_schema = agg.view_schema
     AND refresh.hypertable_name = agg.view_name
    LEFT JOIN timescaledb_information.jobs retention
      ON retention.proc_name = 'policy_retention'
     AND retention.hypertable_schema = agg.hypertable_schema
     AND retention.hypertable_name = agg.hypertable_name
    WHERE agg.hypertable_schema = 'platform'
    """

    case SQL.query(Repo, sql, [], timeout: @query_timeout_ms) do
      {:ok, %{rows: rows}} ->
        for [view, source, refresh_start, source_retention, policy_hazard] <- rows,
            hazard?(policy_hazard, refresh_start, Map.get(worker_windows, source)) do
          %{
            view: view,
            source: source,
            refresh_start: refresh_start,
            source_retention: source_retention || worker_retention_label(worker_windows, source)
          }
        end

      {:error, _} ->
        []
    end
  end

  # The in-database retention policy comparison already decided it.
  defp hazard?(true, _refresh_start, _worker_days), do: true
  # No in-database policy and the worker does not drop this source either.
  defp hazard?(false, _refresh_start, nil), do: false
  # No in-database policy: compare with the window the worker drops by.
  defp hazard?(false, refresh_start, worker_days) do
    case parse_interval_days(refresh_start) do
      nil -> false
      refresh_days -> refresh_days >= worker_days
    end
  end

  defp worker_retention_label(windows, source) do
    case Map.get(windows, source) do
      nil -> nil
      days -> "#{days} days (configured worker retention)"
    end
  end

  # Timescale renders these configs like "32 days" / "10:00:00" / "7 days 00:00:00".
  defp parse_interval_days(value) when is_binary(value) do
    cond do
      match = Regex.run(~r/(\d+)\s*day/, value) ->
        [_, days] = match
        String.to_integer(days)

      match = Regex.run(~r/^(\d+):\d{2}:\d{2}$/, String.trim(value)) ->
        [_, hours] = match
        div(String.to_integer(hours), 24)

      # sub-day intervals can never reach past a >=1 day retention window
      true ->
        0
    end
  end

  defp parse_interval_days(_), do: nil
end
