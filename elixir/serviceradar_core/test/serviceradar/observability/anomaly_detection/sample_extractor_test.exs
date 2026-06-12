defmodule ServiceRadar.Observability.AnomalyDetection.SampleExtractorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.AnomalyDetection.SampleExtractor

  test "extracts sysmon memory utilization samples" do
    [sample] =
      SampleExtractor.extract(%{
        data: Jason.encode!(sysmon_envelope("memory")),
        metadata: %{subject: "metrics.sysmon.memory"}
      })

    assert sample.series_key == "sysmon:memory:host-1"
    assert sample.value == 50.0
    assert sample.observed_at_unix_nano == 1_781_222_400_000_000_000
    assert sample.metric_class == "sysmon.memory"
  end

  test "extracts snmp scalar samples" do
    [sample] =
      SampleExtractor.extract(%{
        data: Jason.encode!(snmp_envelope()),
        metadata: %{subject: "metrics.snmp.interface.ifHCInOctets"}
      })

    assert sample.series_key =~ "snmp:"
    assert sample.value == 1234.5
    assert sample.metric_class == "snmp"
  end

  test "extracts otel json duration samples" do
    [sample] =
      SampleExtractor.extract(%{
        data:
          Jason.encode!(%{
            "timestamp" => "2026-06-12T00:00:00Z",
            "service_name" => "api",
            "span_name" => "GET /devices",
            "span_id" => "0000000000abc123",
            "duration_ms" => 42.5
          }),
        metadata: %{subject: "otel.metrics.derived"}
      })

    assert sample.series_key == "otel:span_duration:api:GET /devices:0000000000abc123"
    assert sample.value == 42.5
    assert sample.metric_class == "otel.span_duration"
  end

  test "extracts flow byte samples from json payloads" do
    [sample] =
      SampleExtractor.extract(%{
        data:
          Jason.encode!(%{
            "timestamp" => "2026-06-12T00:00:00Z",
            "src_addr" => "10.0.0.1",
            "dst_addr" => "10.0.0.2",
            "protocol" => 6,
            "bytes" => 9000,
            "packets" => 9,
            "sampler_address" => "10.0.0.10"
          }),
        metadata: %{subject: "flows.raw.netflow"}
      })

    assert sample.series_key == "flow:flows.raw.netflow:10.0.0.10:10.0.0.1:10.0.0.2:6"
    assert sample.value == 9000.0
    assert sample.metric_class == "flow"
  end

  defp sysmon_envelope(family) do
    %{
      "schema" => "serviceradar.sysmon.metrics.v1",
      "source" => "sysmon-metrics",
      "metric_family" => family,
      "agent_id" => "agent-1",
      "gateway_id" => "gateway-1",
      "partition" => "default",
      "sample" => %{
        "timestamp" => "2026-06-12T00:00:00Z",
        "host_id" => "host-1",
        "agent_id" => "agent-1",
        "memory" => %{"used_bytes" => 50, "total_bytes" => 100}
      }
    }
  end

  defp snmp_envelope do
    %{
      "schema" => "serviceradar.snmp.interface_metric.v1",
      "source" => "snmp-metrics",
      "timestamp" => "2026-06-12T00:00:00Z",
      "gateway_id" => "gateway-1",
      "agent_id" => "agent-1",
      "partition" => "default",
      "metric_name" => "ifHCInOctets",
      "metric_type" => "snmp",
      "value" => 1234.5,
      "target_device_ip" => "10.0.0.20",
      "if_index" => 7,
      "tags" => %{"target" => "10.0.0.20", "interface_uid" => "ifindex:7"},
      "metadata" => %{"oid" => ".1.3.6.1.2.1.31.1.1.1.6.7"}
    }
  end
end
