defmodule ServiceRadarWebNGWeb.InterfaceLive.SnmpMetricNamesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.InterfaceLive.SnmpMetricNames

  @moduletag :unit
  @moduletag :db_free

  test "strips collector suffixes from IF-MIB names" do
    assert SnmpMetricNames.base_name("ifHCInUcastPkts::ifindex:21") == "ifHCInUcastPkts"
    assert SnmpMetricNames.base_name("ifInOctets") == "ifInOctets"
  end

  test "expands 32-bit IF-MIB names to include 64-bit aliases" do
    assert SnmpMetricNames.expand(["ifInUcastPkts", "ifOutOctets", "ifInErrors"]) == [
             "ifHCInUcastPkts",
             "ifHCOutOctets",
             "ifInErrors",
             "ifInUcastPkts",
             "ifOutOctets"
           ]
  end

  test "drops 32-bit series when the 64-bit counterpart is present" do
    series = [
      {"ifInUcastPkts", [{~U[2026-01-01 00:00:00Z], 0.0}]},
      {"ifHCInUcastPkts", [{~U[2026-01-01 00:00:00Z], 12.0}]},
      {"ifInErrors", [{~U[2026-01-01 00:00:00Z], 1.0}]}
    ]

    assert [{"ifHCInUcastPkts", _}, {"ifInErrors", _}] = SnmpMetricNames.prefer_hc_series(series)
  end

  test "selected?/2 matches 64-bit and suffixed names against 32-bit selections" do
    selected = ["ifInUcastPkts"]

    assert SnmpMetricNames.selected?("ifHCInUcastPkts", selected)
    assert SnmpMetricNames.selected?("ifInUcastPkts::ifindex:21", selected)
    refute SnmpMetricNames.selected?("ifInErrors", selected)
  end
end
