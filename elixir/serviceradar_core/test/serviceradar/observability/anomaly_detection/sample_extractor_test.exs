defmodule ServiceRadar.Observability.AnomalyDetection.SampleExtractorTest do
  use ExUnit.Case, async: true

  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ResourceMetrics
  alias Opentelemetry.Proto.Metrics.V1.ScopeMetrics
  alias Opentelemetry.Proto.Resource.V1.Resource
  alias ServiceRadar.Observability.AnomalyDetection.SampleExtractor

  @ingress_id "00000645-50de-8e80-8000-000000000001"
  @ingress_time 1_765_500_000_000_000_000
  @point_time_a 1_781_222_400_000_000_000
  @point_time_b 1_781_222_460_000_000_000

  test "extracts sysmon memory utilization samples" do
    [sample] =
      SampleExtractor.extract(%{
        data: Jason.encode!(sysmon_envelope("memory")),
        metadata: %{subject: "metrics.sysmon.memory"}
      })

    assert sample.series_key == "sysmon:memory:host-1"
    assert is_binary(sample.event_id)

    assert {1_781_222_400_000_000_000, hash, 1_781_222_400_000_000_000, hash} =
             sample.order_key

    assert sample.value == 50.0
    assert sample.observed_at_unix_nano == 1_781_222_400_000_000_000
    assert sample.metric_class == "sysmon.memory"
  end

  test "uses payload ingress id for sysmon event ordering" do
    [sample] =
      SampleExtractor.extract(%{
        data:
          "memory"
          |> sysmon_envelope()
          |> Map.merge(%{
            "ingress_id" => @ingress_id,
            "ingress_timestamp_unix_nano" => @ingress_time
          })
          |> Jason.encode!(),
        metadata: %{subject: "metrics.sysmon.memory"}
      })

    assert String.starts_with?(sample.event_id, "#{@ingress_id}:")

    assert {@ingress_time, @ingress_id, 1_781_222_400_000_000_000, _sample_hash} =
             sample.order_key

    assert sample.observed_at_unix_nano == 1_781_222_400_000_000_000
    assert sample.metadata["ingress_timestamp_unix_nano"] == @ingress_time
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

  test "extracts generic scalar metric samples" do
    [sample] =
      SampleExtractor.extract(%{
        data: Jason.encode!(plugin_metric_envelope()),
        metadata: %{subject: "metrics.timeseries.cpu.proxmox_guest_cpu_ratio_max"}
      })

    assert sample.series_key =~ "cpu:"
    assert sample.value == 0.91
    assert sample.metric_class == "cpu"
    assert sample.metadata[:metric_name] == "proxmox_guest_cpu_ratio_max"
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

  test "uses NATS ingress headers for otel event ordering" do
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
        metadata: %{
          subject: "otel.metrics.derived",
          headers: [
            {"Sr-Ingress-Id", @ingress_id},
            {"Sr-Ingress-Time-Unix-Nano", Integer.to_string(@ingress_time)}
          ]
        }
      })

    assert String.starts_with?(sample.event_id, "#{@ingress_id}:")

    assert {@ingress_time, @ingress_id, 1_781_222_400_000_000_000, _sample_hash} =
             sample.order_key

    assert sample.observed_at_unix_nano == 1_781_222_400_000_000_000
    assert sample.metadata["ingress_timestamp_unix_nano"] == @ingress_time
  end

  test "keeps every OTLP point in a multi-point ingress batch" do
    samples =
      SampleExtractor.extract(%{
        data: ExportMetricsServiceRequest.encode(otel_multi_point_request()),
        metadata: %{
          subject: "otel.metrics.raw",
          headers: [
            {"Sr-Ingress-Id", @ingress_id},
            {"Sr-Ingress-Time-Unix-Nano", Integer.to_string(@ingress_time)}
          ]
        }
      })

    assert length(samples) == 2

    assert Enum.map(samples, & &1.series_key) == [
             "otel:api:queue_depth:5ad5cc4d26869082efd29c436b57384a",
             "otel:api:queue_depth:5ad5cc4d26869082efd29c436b57384a"
           ]

    assert samples |> Enum.map(& &1.event_id) |> Enum.uniq() |> length() == 2
    assert Enum.all?(samples, &String.starts_with?(&1.event_id, "#{@ingress_id}:"))

    assert Enum.map(samples, & &1.order_key) == [
             {@ingress_time, @ingress_id, @point_time_a, event_hash(Enum.at(samples, 0))},
             {@ingress_time, @ingress_id, @point_time_b, event_hash(Enum.at(samples, 1))}
           ]
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

  defp plugin_metric_envelope do
    %{
      "schema" => "serviceradar.metric.v1",
      "source" => "plugin-result",
      "timestamp" => "2026-06-13T18:20:00Z",
      "gateway_id" => "gateway-1",
      "agent_id" => "agent-1",
      "partition" => "default",
      "metric_name" => "proxmox_guest_cpu_ratio_max",
      "metric_type" => "cpu",
      "value" => 0.91,
      "unit" => "ratio",
      "tags" => %{"producer_id" => "proxmox-inventory", "producer_kind" => "plugin_result"},
      "metadata" => %{"status" => "WARNING"}
    }
  end

  defp otel_multi_point_request do
    %ExportMetricsServiceRequest{
      resource_metrics: [
        %ResourceMetrics{
          resource: %Resource{
            attributes: [
              %KeyValue{
                key: "service.name",
                value: %AnyValue{value: {:string_value, "api"}}
              }
            ]
          },
          scope_metrics: [
            %ScopeMetrics{
              metrics: [
                %Metric{
                  name: "queue_depth",
                  data:
                    {:gauge,
                     %Gauge{
                       data_points: [
                         %NumberDataPoint{
                           time_unix_nano: @point_time_a,
                           value: {:as_double, 10.0}
                         },
                         %NumberDataPoint{
                           time_unix_nano: @point_time_b,
                           value: {:as_double, 11.0}
                         }
                       ]
                     }}
                }
              ]
            }
          ]
        }
      ]
    }
  end

  defp event_hash(sample), do: sample.event_id |> String.split(":", parts: 2) |> List.last()
end
