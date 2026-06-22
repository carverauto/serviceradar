defmodule ServiceRadarWebNGWeb.DashboardLive.Data.BasicSummaries do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @sobelow_skip ["SQL.Query"]
      defp device_summary(_scope) do
        if relation_exists?("platform.ocsf_devices") do
          sql = """
          SELECT
            COUNT(*)::bigint AS total,
            COUNT(*) FILTER (WHERE is_available = true)::bigint AS available
          FROM platform.ocsf_devices
          WHERE deleted_at IS NULL
            AND is_active = true
          """

          case ServiceRadarWebNG.Repo.query(sql, []) do
            {:ok, %{rows: [[total, available]]}} ->
              total = to_int(total)
              available = to_int(available)
              %{total: total, available: available, unavailable: max(total - available, 0)}

            _ ->
              empty_device_summary()
          end
        else
          empty_device_summary()
        end
      rescue
        _ -> empty_device_summary()
      end

      defp services_summary(scope, time_window) do
        if relation_exists?("platform.services_availability_5m") do
          ServiceRadarWebNGWeb.Stats.services_availability(scope: scope, time: time_window)
        else
          empty_services_summary()
        end
      rescue
        _ -> empty_services_summary()
      end

      defp trace_summary(srql_module, scope, time_window) do
        ServiceRadarWebNGWeb.Stats.traces_summary_with_computed(
          scope: scope,
          time: time_window,
          srql_module: srql_module
        )
      rescue
        _ -> empty_trace_summary()
      end
    end
  end
end
