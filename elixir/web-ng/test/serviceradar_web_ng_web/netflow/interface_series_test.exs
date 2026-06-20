defmodule ServiceRadarWebNGWeb.NetFlow.InterfaceSeriesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.NetFlow.InterfaceSeries

  test "P95 uses each bucket's busier direction instead of summing paired interface rows" do
    rows = [
      %{sampler: "198.51.100.10", interface_name: "xe-0/0/0", direction: :ingress, t: "2026-06-19T10:00:00Z", v: 1_000},
      %{sampler: "198.51.100.10", interface_name: "xe-0/0/0", direction: :egress, t: "2026-06-19T10:00:00Z", v: 8_000},
      %{sampler: "198.51.100.10", interface_name: "xe-0/0/0", direction: :ingress, t: "2026-06-19T10:05:00Z", v: 7_000},
      %{sampler: "198.51.100.10", interface_name: "xe-0/0/0", direction: :egress, t: "2026-06-19T10:05:00Z", v: 2_000}
    ]

    assert %{{"198.51.100.10", "xe-0/0/0"} => 128.0} =
             InterfaceSeries.busier_direction_p95_bps(rows, 500)
  end
end
