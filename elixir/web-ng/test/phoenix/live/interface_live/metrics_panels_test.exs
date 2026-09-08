defmodule ServiceRadarWebNGWeb.InterfaceLive.MetricsPanelsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.InterfaceLive.MetricsPanels

  @moduletag :unit
  @moduletag :db_free

  test "prefers 64-bit packet series and keeps more than six IF-MIB charts" do
    results =
      for {name, value} <- [
            {"ifInUcastPkts", 0.0},
            {"ifHCInUcastPkts", 42.0},
            {"ifOutUcastPkts", 0.0},
            {"ifHCOutUcastPkts", 17.0},
            {"ifInOctets", 1.0},
            {"ifHCInOctets", 9_000.0},
            {"ifOutOctets", 1.0},
            {"ifHCOutOctets", 8_000.0},
            {"ifInErrors", 0.1},
            {"ifOutErrors", 0.2}
          ] do
        %{
          "timestamp" => "2026-01-01T00:00:00Z",
          "value" => value,
          "metric_name" => name
        }
      end

    [panel] =
      MetricsPanels.from_srql(
        %{
          "results" => results,
          "viz" => %{
            "suggestions" => [
              %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "metric_name"}
            ]
          }
        },
        chart_mode: :combined
      )

    series_names = Enum.map(panel.assigns.series_points, &elem(&1, 0))

    assert "ifHCInUcastPkts" in series_names
    assert "ifHCOutUcastPkts" in series_names
    refute "ifInUcastPkts" in series_names
    refute "ifOutUcastPkts" in series_names
    assert length(series_names) == 6
    assert panel.assigns.chart_mode == :combined
    assert panel.assigns.rate_mode == :rate
  end
end
