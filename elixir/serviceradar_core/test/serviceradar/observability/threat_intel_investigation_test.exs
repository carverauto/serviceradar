defmodule ServiceRadar.Observability.ThreatIntelInvestigationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.ThreatIntelInvestigation

  test "rejects non-IP input before querying" do
    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "not-an-ip")

    assert {:error, :invalid_ip} = ThreatIntelInvestigation.indicators_for_ip(:unused, "")

    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "10.0.0.0/8")

    assert {:error, :invalid_ip} =
             ThreatIntelInvestigation.indicators_for_ip(:unused, "1; DROP TABLE")

    assert {:error, :invalid_ip} = ThreatIntelInvestigation.indicators_for_ip(:unused, nil)
  end
end
