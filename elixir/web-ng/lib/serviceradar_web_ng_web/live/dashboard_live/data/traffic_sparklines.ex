defmodule ServiceRadarWebNGWeb.DashboardLive.Data.TrafficSparklines do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp dashboard_sparklines(time_window, security_trend) do
        %{
          assets: device_activity_sparkline(time_window),
          threats: security_trend |> Enum.map(&(&1.high + &1.critical)) |> sparkline_tail(),
          network_health: service_availability_sparkline(time_window),
          camera: camera_activity_sparkline(time_window),
          survey: survey_sample_sparkline(time_window),
          throughput: flow_traffic_sparkline(time_window, :bps),
          service_health: service_availability_sparkline(time_window),
          latency: mtr_timeseries_sparkline(time_window, :latency_ms),
          packet_loss: mtr_timeseries_sparkline(time_window, :loss_pct)
        }
      rescue
        _ -> empty_sparklines()
      end

      defp empty_sparklines do
        %{
          assets: [],
          threats: [],
          network_health: [],
          camera: [],
          survey: [],
          throughput: [],
          service_health: [],
          latency: [],
          packet_loss: []
        }
      end

      defp flow_traffic_sparkline(time_window, metric) do
        cutoff = cutoff_for_time_window(time_window)

        Enum.find_value(flow_sparkline_sources(time_window), [], fn
          {relation_ref, relation, time_column, bucket_seconds} ->
            if relation_exists?(relation_ref) do
              values = flow_traffic_sparkline_from_relation(relation, time_column, cutoff, bucket_seconds, metric)
              if values != [], do: values
            end
        end)
      rescue
        _ -> []
      end

      defp flow_sparkline_sources(time_window) when time_window in ["last_7d", "last_30d"] do
        [
          {"platform.flow_traffic_1h", "platform.flow_traffic_1h", "bucket", 3600},
          {"platform.ocsf_network_activity_5m_traffic", "platform.ocsf_network_activity_5m_traffic", "bucket", 300},
          {"platform.ocsf_network_activity", "platform.ocsf_network_activity", "time", bucket_seconds_for(time_window)}
        ]
      end

      defp flow_sparkline_sources(time_window) do
        [
          {"platform.ocsf_network_activity_5m_traffic", "platform.ocsf_network_activity_5m_traffic", "bucket", 300},
          {"platform.flow_traffic_1h", "platform.flow_traffic_1h", "bucket", 3600},
          {"platform.ocsf_network_activity", "platform.ocsf_network_activity", "time", bucket_seconds_for(time_window)}
        ]
      end

      defp flow_traffic_sparkline_from_relation(
             "platform.ocsf_network_activity" = relation,
             time_column,
             cutoff,
             seconds,
             metric
           ) do
        bucket_interval = bucket_interval_literal(sparkline_bucket_for_from_seconds(seconds))

        sql = """
        SELECT bucket, bytes_total, packets_total, flow_count
        FROM (
          SELECT
            time_bucket(#{bucket_interval}, #{time_column}) AS bucket,
            COALESCE(SUM(bytes_total), 0)::float8 AS bytes_total,
            COALESCE(SUM(packets_total), 0)::float8 AS packets_total,
            COUNT(*)::float8 AS flow_count
          FROM #{relation}
          WHERE #{time_column} >= $1
          GROUP BY 1
          ORDER BY 1 DESC
          LIMIT $2
        ) recent
        ORDER BY bucket ASC
        """

        sparkline_query_values(sql, [cutoff, 48 * 2], metric, seconds)
      end

      defp flow_traffic_sparkline_from_relation(relation, time_column, cutoff, seconds, metric) do
        sql = """
        SELECT bucket, bytes_total, packets_total, flow_count
        FROM (
          SELECT
            #{time_column} AS bucket,
            COALESCE(SUM(bytes_total), 0)::float8 AS bytes_total,
            COALESCE(SUM(packets_total), 0)::float8 AS packets_total,
            COALESCE(SUM(flow_count), 0)::float8 AS flow_count
          FROM #{relation}
          WHERE #{time_column} >= $1
          GROUP BY 1
          ORDER BY 1 DESC
          LIMIT $2
        ) recent
        ORDER BY bucket ASC
        """

        sparkline_query_values(sql, [cutoff, 48 * 2], metric, seconds)
      end

      @sobelow_skip ["SQL.Query"]
      defp sparkline_query_values(sql, params, metric, seconds) do
        case ServiceRadarWebNG.Repo.query(sql, params) do
          {:ok, %{rows: rows}} ->
            rows
            |> Enum.map(fn [_bucket, bytes, packets, flows] ->
              case metric do
                :bps -> to_float(bytes) * 8 / max(seconds, 1)
                :pps -> to_float(packets) / max(seconds, 1)
                :flows -> to_float(flows)
                _ -> to_float(bytes)
              end
            end)
            |> sparkline_tail()

          _ ->
            []
        end
      end
    end
  end
end
