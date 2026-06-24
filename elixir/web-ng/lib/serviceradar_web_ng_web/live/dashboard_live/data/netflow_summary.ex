defmodule ServiceRadarWebNGWeb.DashboardLive.Data.NetflowSummary do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp flow_summary(time_window) do
        cutoff = cutoff_for_time_window(time_window)

        Enum.find_value(
          [
            {"platform.flow_traffic_1h", "flow_traffic_1h", "bucket", 3_600},
            {"platform.ocsf_network_activity_5m_traffic", "ocsf_network_activity_5m_traffic", "bucket", 300},
            {"platform.ocsf_network_activity", "ocsf_network_activity", "time", nil}
          ],
          empty_flow_summary(),
          fn {relation_ref, relation, time_column, bucket_seconds} ->
            if relation_exists?(relation_ref) do
              summary = flow_summary_from_relation(relation, time_column, cutoff, bucket_seconds)

              if summary.flow_count > 0 or summary.bytes_total > 0 do
                summary
              end
            end
          end
        )
      rescue
        _ -> empty_flow_summary()
      end

      @sobelow_skip ["SQL.Query"]
      defp flow_summary_from_relation(relation, time_column, cutoff, bucket_seconds) do
        flow_count_expr = flow_count_expr(relation)
        coverage_expr = flow_summary_coverage_expr(time_column, bucket_seconds)

        sql = """
        SELECT
          COALESCE(SUM(bytes_total), 0)::bigint,
          COALESCE(SUM(packets_total), 0)::bigint,
          COALESCE(#{flow_count_expr}, 0)::bigint,
          #{coverage_expr}
        FROM #{relation}
        WHERE #{time_column} >= $1
        """

        case ServiceRadarWebNG.Repo.query(sql, [cutoff]) do
          {:ok, %{rows: [[bytes, packets, flows, coverage_seconds]]}} ->
            seconds = max(to_int(coverage_seconds), 1)

            %{
              bytes_total: to_int(bytes),
              packets_total: to_int(packets),
              flow_count: to_int(flows),
              bps: Float.round(to_int(bytes) * 8 / seconds, 2),
              pps: Float.round(to_int(packets) / seconds, 2)
            }

          _ ->
            empty_flow_summary()
        end
      end

      defp flow_summary_coverage_expr(time_column, bucket_seconds) when is_integer(bucket_seconds) do
        interval = "#{bucket_seconds} seconds"

        """
        COALESCE(
          GREATEST(
            EXTRACT(EPOCH FROM ((MAX(#{time_column}) + INTERVAL '#{interval}') - MIN(#{time_column})))::bigint,
            1
          ),
          1
        )::bigint
        """
      end

      defp flow_summary_coverage_expr(time_column, nil) do
        """
        COALESCE(
          GREATEST(
            EXTRACT(EPOCH FROM (
              MAX(COALESCE(end_time, #{time_column})) - MIN(COALESCE(start_time, #{time_column}))
            ))::bigint,
            1
          ),
          1
        )::bigint
        """
      end
    end
  end
end
