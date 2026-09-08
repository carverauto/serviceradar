defmodule ServiceRadarWebNGWeb.DashboardLive.Data.SecurityTrend do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      defp security_trend(time_window) do
        time_window
        |> cutoff_for_time_window()
        |> ServiceRadarWebNGWeb.Stats.events_hourly_trend()
      rescue
        _ -> []
      end
    end
  end
end
