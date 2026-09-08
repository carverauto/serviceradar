defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceDataReferenceLinesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData

  @moduletag :unit
  @moduletag :db_free

  defmodule RateSRQL do
    @moduledoc false

    @behaviour ServiceRadarWebNG.SRQLBehaviour

    @impl true
    def query(query, _opts) do
      assert query =~ "agg:rate"
      assert query =~ "bucket:1m"
      refute query =~ "bucket:5m"
      refute query =~ "agg:max"

      now = DateTime.to_iso8601(~U[2026-07-04 12:00:00Z])

      {:ok,
       %{
         "results" => [
           %{"timestamp" => now, "value" => 344_000.0, "metric_name" => "ifInOctets"}
         ],
         "viz" => %{
           "suggestions" => [
             %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "metric_name"}
           ]
         }
       }}
    end

    def query(query), do: query(query, %{})

    @impl true
    def query_request(%{"query" => query}), do: query(query, %{})
  end

  test "converts per-metric interface thresholds to chart reference lines" do
    max_speed = 125_000_000.0

    interface = %{
      "metric_thresholds" => %{
        "ifInOctets" => %{
          "enabled" => true,
          "threshold_type" => "percentage",
          "comparison" => "gte",
          "value" => 80,
          "severity" => "critical"
        },
        "ifInErrors" => %{
          "enabled" => true,
          "threshold_type" => "absolute",
          "comparison" => "gt",
          "value" => 10,
          "severity" => "warning"
        },
        "ifOutErrors" => %{"enabled" => false, "comparison" => "gt", "value" => 1}
      }
    }

    lines = InterfaceData.interface_reference_lines(interface, max_speed)

    assert %{
             value: 100_000_000.0,
             label: "ifInOctets >= 80",
             severity: :critical,
             series: "ifInOctets"
           } in lines

    assert %{value: 10.0, label: "ifInErrors > 10", severity: :warning, series: "ifInErrors"} in lines
    refute Enum.any?(lines, &(&1.series == "ifOutErrors"))

    # The synthetic "Interface rate" capacity reference line is no longer
    # emitted: folding link capacity into the y-domain squashed real traffic to
    # ~0. Only user-defined thresholds render so the chart auto-scales to data.
    refute Enum.any?(lines, &(&1.label == "Interface rate"))
  end

  test "interface metric section treats SRQL rate output as precomputed rates" do
    assert {:ok, [panel]} =
             InterfaceData.load_interface_metric_section(
               RateSRQL,
               "device-1",
               %{"if_index" => 9},
               [%{"if_index" => 9, "if_name" => "eth9"}],
               :scope,
               time_range: "last_1h",
               bucket: "1m",
               limit: 10
             )

    assert panel.assigns.rate_mode == :rate
    assert panel.assigns.chart_mode == :combined
  end
end
