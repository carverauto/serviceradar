# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
defmodule ServiceRadarWebNGWeb.DashboardLive.Data.ServiceSparklines do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp service_availability_sparkline(time_window) do
        if relation_exists?("platform.services_availability_5m") do
          sql = """
          SELECT bucket, availability_pct
          FROM (
            SELECT
              bucket,
              CASE
                WHEN COALESCE(SUM(total_count), 0) = 0 THEN 0.0
                ELSE COALESCE(SUM(available_count), 0)::float8 / COALESCE(SUM(total_count), 0)::float8 * 100.0
              END AS availability_pct
            FROM platform.services_availability_5m
            WHERE bucket >= $1
            GROUP BY bucket
            ORDER BY bucket DESC
            LIMIT $2
          ) recent
          ORDER BY bucket ASC
          """

          one_value_sparkline(sql, [cutoff_for_time_window(time_window), 48 * 2])
        else
          []
        end
      rescue
        _ -> []
      end

      defp device_activity_sparkline(time_window) do
        if relation_exists?("platform.ocsf_devices") do
          sql = """
          SELECT bucket, value
          FROM (
            SELECT
              time_bucket(#{bucket_interval_literal(sparkline_bucket_for(time_window))}, last_seen_time) AS bucket,
              COUNT(*) FILTER (WHERE COALESCE(is_available, false) = true)::float8 AS value
            FROM platform.ocsf_devices
            WHERE deleted_at IS NULL
              AND is_active = true
              AND last_seen_time >= $1
            GROUP BY 1
            ORDER BY 1 DESC
            LIMIT $2
          ) recent
          ORDER BY bucket ASC
          """

          one_value_sparkline(sql, [cutoff_for_time_window(time_window), 48 * 2])
        else
          []
        end
      rescue
        _ -> []
      end

      defp camera_activity_sparkline(time_window) do
        if relation_exists?("platform.camera_sources") do
          sql = """
          SELECT bucket, value
          FROM (
            SELECT
              time_bucket(#{bucket_interval_literal(sparkline_bucket_for(time_window))}, COALESCE(last_activity_at, last_event_at, updated_at)) AS bucket,
              COUNT(*) FILTER (WHERE availability_status IN ('available', 'online', 'active', 'healthy'))::float8 AS value
            FROM platform.camera_sources
            WHERE COALESCE(last_activity_at, last_event_at, updated_at) >= $1
            GROUP BY 1
            ORDER BY 1 DESC
            LIMIT $2
          ) recent
          ORDER BY bucket ASC
          """

          one_value_sparkline(sql, [cutoff_for_time_window(time_window), 48 * 2])
        else
          []
        end
      rescue
        _ -> []
      end

      defp survey_sample_sparkline(time_window) do
        cond do
          relation_exists?("platform.survey_rf_pose_matches") ->
            sql = """
            SELECT bucket, value
            FROM (
              SELECT
                time_bucket(#{bucket_interval_literal(sparkline_bucket_for(time_window))}, rf_captured_at) AS bucket,
                COUNT(*)::float8 AS value
              FROM platform.survey_rf_pose_matches
              WHERE rf_captured_at >= $1
                AND x IS NOT NULL
                AND z IS NOT NULL
                AND rssi_dbm IS NOT NULL
              GROUP BY 1
              ORDER BY 1 DESC
              LIMIT $2
            ) recent
            ORDER BY bucket ASC
            """

            one_value_sparkline(sql, [cutoff_for_time_window(time_window), 48 * 2])

          relation_exists?("platform.survey_samples") ->
            sql = """
            SELECT bucket, value
            FROM (
              SELECT
                time_bucket(#{bucket_interval_literal(sparkline_bucket_for(time_window))}, timestamp) AS bucket,
                COUNT(*)::float8 AS value
              FROM platform.survey_samples
              WHERE timestamp >= $1
              GROUP BY 1
              ORDER BY 1 DESC
              LIMIT $2
            ) recent
            ORDER BY bucket ASC
            """

            one_value_sparkline(sql, [cutoff_for_time_window(time_window), 48 * 2])

          true ->
            []
        end
      rescue
        _ -> []
      end

      @sobelow_skip ["SQL.Query"]
      defp one_value_sparkline(sql, params) do
        case ServiceRadarWebNG.Repo.query(sql, params) do
          {:ok, %{rows: rows}} ->
            rows
            |> Enum.map(fn [_bucket, value] -> to_float(value) end)
            |> sparkline_tail()

          _ ->
            []
        end
      end

      @sobelow_skip ["SQL.Query"]
      defp mtr_timeseries_sparkline(time_window, metric) do
        if relation_exists?("platform.mtr_traces") and relation_exists?("platform.mtr_hops") do
          {value_expr, denominator_expr} =
            case metric do
              :latency_ms ->
                {
                  """
                  SUM(h.avg_us::numeric * h.received::numeric)
                    FILTER (WHERE h.avg_us IS NOT NULL AND h.received > 0) /
                    NULLIF(
                      SUM(h.received::numeric)
                        FILTER (WHERE h.avg_us IS NOT NULL AND h.received > 0),
                      0
                    ) / 1000.0
                  """,
                  """
                  SUM(h.received::numeric)
                    FILTER (WHERE h.avg_us IS NOT NULL AND h.received > 0)
                  """
                }

              :loss_pct ->
                {
                  """
                  100.0 * (
                    SUM(h.sent::numeric) FILTER (WHERE h.sent > 0) -
                      SUM(h.received::numeric) FILTER (WHERE h.sent > 0)
                  ) /
                    NULLIF(SUM(h.sent::numeric) FILTER (WHERE h.sent > 0), 0)
                  """,
                  "SUM(h.sent::numeric) FILTER (WHERE h.sent > 0)"
                }
            end

          sql = """
          WITH destination_hops AS (
            SELECT trace_time, sent, received, avg_us
            FROM (
              SELECT
                t.time AS trace_time,
                h.time AS hop_time,
                h.id AS hop_id,
                h.trace_id,
                h.sent,
                h.received,
                h.avg_us,
                ROW_NUMBER() OVER (
                  PARTITION BY h.trace_id
                  ORDER BY h.time DESC, h.id DESC
                ) AS terminal_rank
              FROM mtr_traces t
              INNER JOIN mtr_hops h
                ON h.trace_id = t.id
                AND t.target_reached
                AND h.hop_number = t.total_hops
              WHERE t.time >= $1
            ) terminal_candidates
            WHERE terminal_rank = 1
          )
          SELECT bucket, value
          FROM (
            SELECT
              time_bucket(#{bucket_interval_literal(sparkline_bucket_for(time_window))}, h.trace_time) AS bucket,
              #{value_expr} AS value
            FROM destination_hops h
            GROUP BY 1
            HAVING #{denominator_expr} > 0
            ORDER BY 1 DESC
            LIMIT $2
          ) recent
          ORDER BY bucket ASC
          """

          one_value_sparkline(sql, [cutoff_for_time_window(time_window), 48 * 2])
        else
          []
        end
      rescue
        _ -> []
      end
    end
  end
end
