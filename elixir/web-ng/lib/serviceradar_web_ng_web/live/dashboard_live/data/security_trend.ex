defmodule ServiceRadarWebNGWeb.DashboardLive.Data.SecurityTrend do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp security_trend(time_window) do
        time_window
        |> cutoff_for_time_window()
        |> ServiceRadarWebNGWeb.Stats.events_hourly_trend()
        |> Enum.map(fn point -> Map.put(point, :label, format_bucket(point.bucket)) end)
      rescue
        _ -> []
      end
    end
  end
end
