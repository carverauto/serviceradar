defmodule ServiceRadarWebNGWeb.DeviceLive.InterfaceDataReferenceLinesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData

  @moduletag :unit
  @moduletag :db_free

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
    assert Enum.any?(lines, &(&1.label == "Interface rate" and &1.series == "ifOutOctets"))
  end
end
