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

      defp trace_sparkline(time_window, metric, mtr_overlays) do
        rollup_values =
          if relation_exists?("platform.traces_stats_5m") do
            trace_rollup_sparkline(time_window, metric)
          else
            []
          end

        if rollup_values == [] and metric == :latency_ms do
          mtr_overlay_sparkline(mtr_overlays, :avg_latency_ms)
        else
          rollup_values
        end
      rescue
        _ -> []
      end

      defp trace_rollup_sparkline(time_window, :latency_ms) do
        sql = """
        SELECT bucket, avg_duration_ms
        FROM (
          SELECT bucket, COALESCE(AVG(avg_duration_ms), 0)::float8 AS avg_duration_ms
          FROM platform.traces_stats_5m
          WHERE bucket >= $1
          GROUP BY bucket
          ORDER BY bucket DESC
          LIMIT $2
        ) recent
        ORDER BY bucket ASC
        """

        one_value_sparkline(sql, [cutoff_for_time_window(time_window), 48 * 2])
      end

      defp trace_rollup_sparkline(time_window, :success_pct) do
        sql = """
        SELECT bucket, success_pct
        FROM (
          SELECT
            bucket,
            CASE
              WHEN COALESCE(SUM(total_count), 0) = 0 THEN 100.0
              ELSE (1.0 - COALESCE(SUM(error_count), 0)::float8 / COALESCE(SUM(total_count), 0)::float8) * 100.0
            END AS success_pct
          FROM platform.traces_stats_5m
          WHERE bucket >= $1
          GROUP BY bucket
          ORDER BY bucket DESC
          LIMIT $2
        ) recent
        ORDER BY bucket ASC
        """

        one_value_sparkline(sql, [cutoff_for_time_window(time_window), 48 * 2])
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

      defp mtr_overlay_sparkline([], _metric), do: []

      defp mtr_overlay_sparkline(overlays, :avg_latency_ms) do
        overlays
        |> Enum.map(fn overlay -> to_float(overlay.avg_us) / 1000 end)
        |> sparkline_tail()
      end

      defp mtr_overlay_sparkline(overlays, :loss_pct) do
        overlays
        |> Enum.map(&to_float(&1.loss_pct))
        |> sparkline_tail()
      end
    end
  end
end
