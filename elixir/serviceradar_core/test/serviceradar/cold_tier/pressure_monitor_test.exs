defmodule ServiceRadar.ColdTier.PressureMonitorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.ColdTier.PressureMonitor

  test "parses kubernetes storage quantities" do
    assert PressureMonitor.parse_k8s_quantity("100Gi") == 100 * 1024 ** 3
    assert PressureMonitor.parse_k8s_quantity("250Gi") == 250 * 1024 ** 3
    assert PressureMonitor.parse_k8s_quantity("1Ti") == 1024 ** 4
    assert PressureMonitor.parse_k8s_quantity("1.5Ti") == round(1.5 * 1024 ** 4)
    assert PressureMonitor.parse_k8s_quantity("500G") == 500 * 1000 ** 3
    assert PressureMonitor.parse_k8s_quantity(" 20Gi ") == 20 * 1024 ** 3
    assert PressureMonitor.parse_k8s_quantity("1073741824") == 1_073_741_824
    assert PressureMonitor.parse_k8s_quantity("bogus") == nil
  end
end
