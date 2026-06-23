defmodule ServiceRadarWebNGWeb.DashboardLive.Data.SecurityTrend do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @sobelow_skip ["SQL.Query"]
      defp security_trend(time_window) do
        cutoff = cutoff_for_time_window(time_window)

        if relation_exists?("platform.ocsf_events_hourly_stats") and
             relation_exists?("platform.ocsf_events") do
          # Read closed hours from the pre-aggregated CAGG (severity_id is already
          # COALESCEd to 0 in the rollup) and only the single in-progress hour
          # from raw ocsf_events. Avoids a full ~880k-row scan of ocsf_events on
          # every dashboard render (live EXPLAIN: cost ~610 vs ~58,768).
          sql = """
          WITH hourly AS (
            SELECT bucket, severity_id, total_count
            FROM ocsf_events_hourly_stats
            WHERE bucket >= $1 AND bucket < date_trunc('hour', now())
            UNION ALL
            SELECT
              date_trunc('hour', time) AS bucket,
              COALESCE(severity_id, 0) AS severity_id,
              COUNT(*)::bigint AS total_count
            FROM ocsf_events
            WHERE time >= date_trunc('hour', now())
            GROUP BY 1, 2
          ),
          recent AS (
            SELECT
              bucket,
              SUM(total_count)::bigint AS total,
              COALESCE(SUM(total_count) FILTER (WHERE severity_id BETWEEN 1 AND 2), 0)::bigint AS low,
              COALESCE(SUM(total_count) FILTER (WHERE severity_id = 3), 0)::bigint AS medium,
              COALESCE(SUM(total_count) FILTER (WHERE severity_id = 4), 0)::bigint AS high,
              COALESCE(SUM(total_count) FILTER (WHERE severity_id >= 5), 0)::bigint AS critical
            FROM hourly
            GROUP BY bucket
            ORDER BY bucket DESC
            LIMIT 48
          )
          SELECT bucket, total, low, medium, high, critical
          FROM recent
          ORDER BY bucket ASC
          """

          case ServiceRadarWebNG.Repo.query(sql, [cutoff]) do
            {:ok, %{rows: rows}} ->
              Enum.map(rows, fn [bucket, total, low, medium, high, critical] ->
                %{
                  bucket: bucket,
                  label: format_bucket(bucket),
                  total: to_int(total),
                  low: to_int(low),
                  medium: to_int(medium),
                  high: to_int(high),
                  critical: to_int(critical)
                }
              end)

            _ ->
              []
          end
        else
          []
        end
      rescue
        _ -> []
      end
    end
  end
end
