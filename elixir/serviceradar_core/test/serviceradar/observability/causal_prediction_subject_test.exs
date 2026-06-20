defmodule ServiceRadar.Observability.CausalPredictionSubjectTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.CausalPredictionSubject

  test "builds causal prediction subjects with sanitized series tokens" do
    assert CausalPredictionSubject.build("snmp.if_octets:10.0.0.20:7:core *> uplink") ==
             "signals.causal.predictions.snmp_if_octets:10_0_0_20:7:core____uplink"
  end

  test "uses caller fallback for blank values" do
    assert CausalPredictionSubject.build(" ", "capacity_forecast") ==
             "signals.causal.predictions.capacity_forecast"
  end
end
