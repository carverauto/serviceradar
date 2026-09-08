defmodule ServiceRadar.Inventory.NormalizeInterfaceMetricsConfigTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Changes.NormalizeInterfaceMetricsConfig
  alias ServiceRadar.Inventory.InterfaceMetrics

  test "enabling with no selected metrics applies the default counters" do
    assert NormalizeInterfaceMetricsConfig.normalize([], true) ==
             {InterfaceMetrics.default_selected(), true}

    assert NormalizeInterfaceMetricsConfig.normalize(nil, true) ==
             {InterfaceMetrics.default_selected(), true}
  end

  test "keeps an explicit selection when collection is enabled" do
    assert NormalizeInterfaceMetricsConfig.normalize(["ifHCInOctets"], true) ==
             {["ifHCInOctets"], true}
  end

  test "disabling clears the selection" do
    assert NormalizeInterfaceMetricsConfig.normalize(["ifInOctets"], false) == {[], false}
  end

  test "nil enabled follows whether any metrics are selected" do
    assert NormalizeInterfaceMetricsConfig.normalize(["ifOutOctets"], nil) ==
             {["ifOutOctets"], true}

    assert NormalizeInterfaceMetricsConfig.normalize([], nil) == {[], false}
  end
end
