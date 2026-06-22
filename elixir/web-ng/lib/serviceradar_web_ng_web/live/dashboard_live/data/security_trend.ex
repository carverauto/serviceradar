defmodule ServiceRadarWebNGWeb.DashboardLive.Data.SecurityTrend do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @sobelow_skip ["SQL.Query"]
      defp security_trend(time_window) do
        cutoff = cutoff_for_time_window(time_window)

        if relation_exists?("platform.ocsf_events") do
          sql = """
          SELECT bucket, total, low, medium, high, critical
          FROM (
            SELECT
              date_trunc('hour', time) AS bucket,
              COUNT(*)::bigint AS total,
              COUNT(*) FILTER (WHERE COALESCE(severity_id, 0) BETWEEN 1 AND 2)::bigint AS low,
              COUNT(*) FILTER (WHERE COALESCE(severity_id, 0) = 3)::bigint AS medium,
              COUNT(*) FILTER (WHERE COALESCE(severity_id, 0) = 4)::bigint AS high,
              COUNT(*) FILTER (WHERE COALESCE(severity_id, 0) >= 5)::bigint AS critical
            FROM ocsf_events
            WHERE time >= $1
            GROUP BY 1
            ORDER BY 1 DESC
            LIMIT 48
          ) recent
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
