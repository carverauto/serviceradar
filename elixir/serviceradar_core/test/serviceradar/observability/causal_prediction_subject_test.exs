defmodule ServiceRadar.Observability.CausalPredictionSubjectTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDetection.SeriesKey
  alias ServiceRadar.Observability.CausalPredictionSubject

  test "builds causal prediction subjects with sanitized series tokens" do
    assert CausalPredictionSubject.build("snmp.if_octets:10.0.0.20:7:core *> uplink") ==
             "signals.analytics.predictions.snmp_if_octets:10_0_0_20:7:core____uplink"
  end

  test "uses caller fallback for blank values" do
    assert CausalPredictionSubject.build(" ", "capacity_forecast") ==
             "signals.analytics.predictions.capacity_forecast"
  end

  test "builds the same sanitized subject central routing uses for edge-derived canonical keys" do
    source_identity = %{
      "series_key" => "edge-hint-provisional",
      "metric_class" => "snmp.if_octets",
      "metric_name" => "ifHCInOctets",
      "target_device_ip" => "10.0.0.20",
      "partition" => "spoofed",
      "if_index" => 7,
      "tags" => %{"if_alias" => "core *> uplink"}
    }

    canonical = SeriesKey.from_source_identity(source_identity, partition_id: "prod-east")
    subject = CausalPredictionSubject.build(canonical)

    assert subject == "signals.analytics.predictions.#{CausalPredictionSubject.token(canonical)}"
    assert subject =~ "partition=#{Base.encode16("prod-east", case: :lower)}"
    refute subject =~ Base.encode16("spoofed", case: :lower)
    refute subject =~ "edge-hint-provisional"
    refute subject =~ ".10.0.0.20"
    refute subject =~ "*"
    refute subject =~ ">"
    refute subject =~ " "
  end
end
