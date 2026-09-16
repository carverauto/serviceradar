defmodule ServiceRadarWebNGWeb.DashboardLive.Data.NetflowSummary do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp flow_summary(%{start: _, end: _, seconds: seconds} = window) do
        time = ServiceRadarWebNGWeb.DashboardLive.Window.query_time(window)

        query =
          ~s|in:flows #{time} stats:"sum(bytes_total) as bytes_total, sum(packets_total) as packets_total, count(*) as flow_count" limit:1|

        case default_srql_module().query(query, %{scope: nil}) do
          {:ok, %{"results" => [%{} = row]}} ->
            bytes = to_int(row["bytes_total"])
            packets = to_int(row["packets_total"])

            %{
              bytes_total: bytes,
              packets_total: packets,
              flow_count: to_int(row["flow_count"]),
              bps: Float.round(bytes * 8 / max(seconds, 1), 2),
              pps: Float.round(packets / max(seconds, 1), 2)
            }

          {:ok, %{"results" => []}} ->
            empty_flow_summary()

          _ ->
            Map.put(empty_flow_summary(), :error, :query_failed)
        end
      end

      defp flow_summary(value), do: flow_summary(ServiceRadarWebNGWeb.DashboardLive.Window.resolve(value, "netflow"))
    end
  end
end
