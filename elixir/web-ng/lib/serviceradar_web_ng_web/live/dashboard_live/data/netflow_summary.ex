defmodule ServiceRadarWebNGWeb.DashboardLive.Data.NetflowSummary do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp flow_summary(time_window) do
        cutoff = cutoff_for_time_window(time_window)

        Enum.find_value(
          [
            {"platform.flow_traffic_1h", "flow_traffic_1h", "bucket"},
            {"platform.ocsf_network_activity_5m_traffic", "ocsf_network_activity_5m_traffic", "bucket"},
            {"platform.ocsf_network_activity", "ocsf_network_activity", "time"}
          ],
          empty_flow_summary(),
          fn {relation_ref, relation, time_column} ->
            if relation_exists?(relation_ref) do
              summary = flow_summary_from_relation(relation, time_column, cutoff)

              if summary.flow_count > 0 or summary.bytes_total > 0 do
                summary
              end
            end
          end
        )
      rescue
        _ -> empty_flow_summary()
      end

      defp flow_summary_from_relation(relation, time_column, cutoff) do
        flow_count_expr = flow_count_expr(relation)

        sql = """
        SELECT
          COALESCE(SUM(bytes_total), 0)::bigint,
          COALESCE(SUM(packets_total), 0)::bigint,
          COALESCE(#{flow_count_expr}, 0)::bigint
        FROM #{relation}
        WHERE #{time_column} >= $1
        """

        case ServiceRadarWebNG.Repo.query(sql, [cutoff]) do
          {:ok, %{rows: [[bytes, packets, flows]]}} ->
            seconds = max(DateTime.diff(DateTime.utc_now(), cutoff, :second), 1)

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
    end
  end
end
