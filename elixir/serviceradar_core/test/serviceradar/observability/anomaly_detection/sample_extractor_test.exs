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
  alias Serviceradar.Metric.V1.IngestIdentity
  alias Serviceradar.Metric.V1.Metric, as: SrMetric
  alias Serviceradar.Metric.V1.MetricBatch
  alias Serviceradar.Metric.V1.MetricPoint
  alias Serviceradar.Metric.V1.MetricResource
  alias Serviceradar.Metric.V1.StringMapEntry
  alias ServiceRadar.Observability.AnomalyDetection.SampleExtractor

  @ingress_id "00000645-50de-8e80-8000-000000000001"
  @ingress_time 1_765_500_000_000_000_000
  @point_time_a 1_781_222_400_000_000_000
  @point_time_b 1_781_222_460_000_000_000

  test "extracts sysmon memory utilization samples" do
    [sample] =
      SampleExtractor.extract(%{
        data: sysmon_memory_batch(),
        metadata: %{subject: "metrics.sysmon.memory"}
      })

    # series_key is derived from attested fields, NOT the producer hint
    # ("sysmon:memory:host-1"). It is prefixed by the metric class.
    assert String.starts_with?(sample.series_key, "sysmon.memory:")
    refute sample.series_key == "sysmon.memory:sysmon:memory:host-1"
    assert sample.metadata["series_identity_hint"] == "sysmon:memory:host-1"
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
        data: sysmon_memory_batch(ingress_id: @ingress_id, ingress_timestamp: @ingress_time),
        metadata: %{subject: "metrics.sysmon.memory"}
      })

    assert String.starts_with?(sample.event_id, "#{@ingress_id}:")

    assert {@ingress_time, @ingress_id, 1_781_222_400_000_000_000, _sample_hash} =
             sample.order_key

    assert sample.observed_at_unix_nano == 1_781_222_400_000_000_000
    assert sample.metadata["ingress_timestamp_unix_nano"] == @ingress_time
  end

  test "drops sysmon process metrics from anomaly analysis by default" do
    event = [:serviceradar, :observability, :anomaly_detection, :sample_extractor, :batch]
    handler_id = {:sample_extractor_process_drop, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {handler_id, measurements, metadata})
      end,
      nil
    )

    result =
      try do
        SampleExtractor.extract(%{
          data: sysmon_process_batch("process.count"),
          metadata: %{subject: "metrics.sysmon.process"}
        })
      after
        :telemetry.detach(handler_id)
      end

    assert result == []

    assert [] =
             SampleExtractor.extract(%{
               data: sysmon_process_batch("process.cpu_usage"),
               metadata: %{subject: "metrics.sysmon.process"}
             })

    assert_receive {^handler_id,
                    %{
                      accepted_samples: 0,
                      dropped_samples: 1,
                      dropped_process_samples: 1,
                      dropped_unidentified_samples: 0
                    }, %{subject_class: "metrics_sysmon"}}
  end

  test "extracts snmp scalar samples" do
    [sample] =
      SampleExtractor.extract(%{
        data: snmp_batch(1234.5, @point_time_a),
        metadata: %{subject: "metrics.snmp.interface.ifHCInOctets"}
      })

    assert sample.series_key =~ "snmp:"
    assert sample.value == 1234.5
    assert sample.metric_class == "snmp"
  end

  test "SNMP target_device_ip resolves to the IP-bearing host tag, not the target name (finding 1)" do
    # snmp_batch tags are {"target" => "router-a", "host" => "10.0.0.20"}.
    # The IP must drive target_device_ip (and therefore the derived series key),
    # not the logical target name.
    [sample] =
      SampleExtractor.extract(%{
        data: snmp_batch(1234.5, @point_time_a),
        metadata: %{subject: "metrics.snmp.interface.ifHCInOctets"}
      })

    assert sample.metadata.target_device_ip == "10.0.0.20"
  end

  test "derives series_key from attested fields even when a different hint is present (finding 2a)" do
    event = [:serviceradar, :observability, :series_identity_hint, :mismatch]
    handler_id = {:sample_extractor_series_hint_mismatch, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {handler_id, measurements, metadata})
      end,
      nil
    )

    [sample] =
      try do
        SampleExtractor.extract(%{
          data: sysmon_memory_batch(series_identity_hint: "spoofed-canonical-key"),
          metadata: %{subject: "metrics.sysmon.memory"}
        })
      after
        :telemetry.detach(handler_id)
      end

    # The hint must never become the canonical key; it is debug metadata only.
    refute sample.series_key == "sysmon.memory:spoofed-canonical-key"
    assert String.starts_with?(sample.series_key, "sysmon.memory:")
    assert sample.metadata["series_identity_hint"] == "spoofed-canonical-key"
    assert_receive {^handler_id, %{count: 1}, %{source: :sample_extractor}}
  end

  test "drops an identity-less sysmon sample WITH a hint (hint cannot rescue identity) (finding 2b)" do
    assert [] =
             SampleExtractor.extract(%{
               data: identityless_sysmon_batch(series_identity_hint: "sysmon:memory:host-1"),
               metadata: %{subject: "metrics.sysmon.memory"}
             })
  end

  test "drops an identity-less sysmon sample without a hint (finding 2b)" do
    assert [] =
             SampleExtractor.extract(%{
               data: identityless_sysmon_batch(series_identity_hint: ""),
               metadata: %{subject: "metrics.sysmon.memory"}
             })
  end

  test "preserves SNMP cumulative-counter semantics in sample metadata" do
    # Counter rate-normalization now happens at the edge (serviceradar-anomaly-addon);
    # the extractor's job is to preserve the counter semantics the edge gate keys on.
    [first] =
      SampleExtractor.extract(%{
        data: snmp_batch(1_000, @point_time_a),
        metadata: %{subject: "metrics.snmp.interface.ifHCInOctets"}
      })

    assert first.metadata[:metric_type] == "snmp"
    assert first.metadata[:kind] == "sum"
    assert first.metadata[:temporality] == "cumulative"
    assert first.metadata[:is_monotonic] == true
    assert first.metadata[:counter_width] == 64
  end

  test "extracts generic scalar metric samples" do
    [sample] =
      SampleExtractor.extract(%{
        data: plugin_metric_batch(),
        metadata: %{subject: "metrics.timeseries.cpu.proxmox_guest_cpu_ratio_max"}
      })

    assert sample.series_key =~ "cpu:"
    assert sample.value == 0.91
    assert sample.metric_class == "cpu"
    assert sample.metadata[:metric_name] == "proxmox_guest_cpu_ratio_max"
  end

  test "extracts every point from a ServiceRadar metric batch in order" do
    samples =
      SampleExtractor.extract(%{
        data:
          metric_batch(
            [
              %SrMetric{
                name: "custom.temperature_celsius",
                metric_type: "environment.temperature",
                kind: :METRIC_KIND_GAUGE,
                unit: "Cel",
                tags: entries(%{"source_zone" => "rack-a", "sensor" => "metric-default"}),
                metadata: entries(%{"calibration" => "metric-default"}),
                points: [
                  %MetricPoint{
                    value: 61.5,
                    raw_value: "61.5",
                    raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
                    observed_at_unix_nano: @point_time_a,
                    attributes: entries(%{"sensor" => "cpu0"}),
                    metadata: entries(%{"calibration" => "point-a"}),
                    series_identity_hint: "sensor:cpu0"
                  },
                  %MetricPoint{
                    value: 63.0,
                    raw_value: "63.0",
                    raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
                    observed_at_unix_nano: @point_time_b,
                    attributes: entries(%{"sensor" => "cpu1"}),
                    metadata: entries(%{"calibration" => "point-b"}),
                    series_identity_hint: "sensor:cpu1"
                  }
                ]
              }
            ],
            source: "native-addon",
            service_name: "sample-native-addon",
            service_type: "native-addon",
            ingress_id: @ingress_id,
            ingress_timestamp: @ingress_time
          ),
        metadata: %{subject: "metrics.timeseries.environment.temperature"}
      })

    # Keys are derived from attested fields (the differing "sensor" tag keeps
    # the two points distinct), not from the producer hints "sensor:cpu0/1".
    assert Enum.all?(
             samples,
             &String.starts_with?(&1.series_key, "environment.temperature:")
           )

    assert samples |> Enum.map(& &1.series_key) |> Enum.uniq() |> length() == 2
    refute Enum.any?(samples, &(&1.series_key == "environment.temperature:sensor:cpu0"))

    assert Enum.map(samples, & &1.metadata["series_identity_hint"]) == [
             "sensor:cpu0",
             "sensor:cpu1"
           ]

    assert Enum.map(samples, & &1.value) == [61.5, 63.0]
    assert Enum.map(samples, & &1.observed_at_unix_nano) == [@point_time_a, @point_time_b]
    assert Enum.map(samples, & &1.metadata.tags["sensor"]) == ["cpu0", "cpu1"]
    assert Enum.map(samples, & &1.metadata["calibration"]) == ["point-a", "point-b"]
    assert Enum.map(samples, & &1.metadata[:kind]) == ["gauge", "gauge"]
    assert samples |> Enum.map(& &1.event_id) |> Enum.uniq() |> length() == 2
    assert Enum.all?(samples, &String.starts_with?(&1.event_id, "#{@ingress_id}:"))
  end

  test "rejects JSON metric payloads on the canonical metrics stream" do
    assert [] =
             SampleExtractor.extract(%{
               data:
                 Jason.encode!(%{"schema_version" => "serviceradar.metric.v1", "metrics" => []}),
               metadata: %{subject: "metrics.timeseries.cpu"}
             })
  end

  test "extracts otel protobuf-derived duration samples" do
    [sample] =
      SampleExtractor.extract(%{
        data: otel_derived_duration_batch(),
        metadata: %{subject: "otel.metrics.derived"}
      })

    assert sample.series_key == "otel:span_duration:api:GET /devices:0000000000abc123"
    assert sample.value == 42.5
    assert sample.metric_class == "otel.span_duration"
  end

  test "uses NATS ingress headers for otel event ordering" do
    [sample] =
      SampleExtractor.extract(%{
        data: otel_derived_duration_batch(),
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

  describe "series_key_from_source_identity/1 (edge re-keying parity, §3.4b)" do
    # An edge add-on forwards source_identity (the raw attested fields it saw on
    # the same MetricBatch). Re-keying it must yield the IDENTICAL series_key the
    # central extractor derives from that batch, so edge verdicts land on the same
    # series during the edge<->central rollout join and the seasonal-worker join.

    test "snmp interface verdict re-keys to the live extractor key (if_index dimension)" do
      [live] =
        SampleExtractor.extract(%{
          data: snmp_batch(1234.5, @point_time_a),
          metadata: %{subject: "metrics.snmp.interface.ifHCInOctets"}
        })

      # Fields the edge add-on forwards from the same batch's resource/metric/point.
      source_identity = %{
        "series_key" => "agent-1|ifHCInOctets|ifindex:7",
        "metric_class" => "snmp",
        "metric_name" => "ifHCInOctets",
        "agent_id" => "agent-1",
        "host_id" => "",
        "device_id" => "",
        "host_ip" => "",
        "partition" => "default",
        "if_index" => 7,
        "interface_uid" => "ifindex:7",
        "tags" => %{"target" => "router-a", "host" => "10.0.0.20"}
      }

      assert SampleExtractor.series_key_from_source_identity(source_identity) == live.series_key
    end

    test "sysmon verdict re-keys to the live extractor key (excluded host_id tag dropped)" do
      [live] =
        SampleExtractor.extract(%{
          data: sysmon_memory_batch(),
          metadata: %{subject: "metrics.sysmon.memory"}
        })

      source_identity = %{
        "series_key" => "sysmon:memory:host-1",
        "metric_class" => "sysmon.memory",
        "metric_name" => "memory.used_percent",
        "agent_id" => "agent-1",
        "host_id" => "",
        "device_id" => "",
        "host_ip" => "",
        "partition" => "default",
        "tags" => %{"host_id" => "host-1"}
      }

      assert SampleExtractor.series_key_from_source_identity(source_identity) == live.series_key
    end

    test "returns nil without a metric_class so the caller keeps the producer hint" do
      assert SampleExtractor.series_key_from_source_identity(%{"agent_id" => "agent-1"}) == nil
      assert SampleExtractor.series_key_from_source_identity(%{}) == nil
      assert SampleExtractor.series_key_from_source_identity(nil) == nil
    end
  end

  defp sysmon_memory_batch(opts \\ []) do
    metric_batch(
      [
        %SrMetric{
          name: "memory.used_percent",
          metric_type: "sysmon.memory",
          kind: :METRIC_KIND_GAUGE,
          unit: "%",
          tags: entries(%{"host_id" => "host-1"}),
          metadata: entries(%{"used_bytes" => "50", "total_bytes" => "100"}),
          points: [
            %MetricPoint{
              value: 50.0,
              raw_value: "50.0",
              raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
              observed_at_unix_nano: @point_time_a,
              series_identity_hint:
                Keyword.get(opts, :series_identity_hint, "sysmon:memory:host-1")
            }
          ]
        }
      ],
      source: "sysmon-metrics",
      service_name: "sysmon",
      service_type: "sysmon",
      ingress_id: Keyword.get(opts, :ingress_id, ""),
      ingress_timestamp: Keyword.get(opts, :ingress_timestamp, 0)
    )
  end

  defp sysmon_process_batch(metric_name) do
    metric_batch(
      [
        %SrMetric{
          name: metric_name,
          metric_type: "sysmon.process",
          kind: :METRIC_KIND_GAUGE,
          unit: "count",
          tags: entries(%{"host_id" => "host-1", "process_name" => "postgres"}),
          points: [
            %MetricPoint{
              value: 12.0,
              raw_value: "12.0",
              raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
              observed_at_unix_nano: @point_time_a,
              series_identity_hint: "sysmon:process:host-1:postgres"
            }
          ]
        }
      ],
      source: "sysmon-metrics",
      service_name: "sysmon",
      service_type: "sysmon"
    )
  end

  # A sysmon batch whose resource carries NO gateway-attested identity
  # (agent_id/device_id/host_id/host_ip all empty). Used to prove the
  # anti-spoof guard drops it regardless of any producer-set series hint.
  defp identityless_sysmon_batch(opts) do
    MetricBatch.encode(%MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{
        agent_id: "",
        device_id: "",
        host_id: "",
        host_ip: "",
        gateway_id: "gateway-1",
        partition: "default",
        service_name: "sysmon",
        service_type: "sysmon"
      },
      ingest_identity: %IngestIdentity{
        source: "sysmon-metrics",
        payload_kind: "serviceradar.metric.v1",
        producer_id: "agent-1",
        producer_kind: "agent"
      },
      emitted_at_unix_nano: @point_time_a,
      metrics: [
        %SrMetric{
          name: "memory.used_percent",
          metric_type: "sysmon.memory",
          kind: :METRIC_KIND_GAUGE,
          unit: "%",
          points: [
            %MetricPoint{
              value: 50.0,
              raw_value: "50.0",
              raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
              observed_at_unix_nano: @point_time_a,
              series_identity_hint: Keyword.get(opts, :series_identity_hint, "")
            }
          ]
        }
      ]
    })
  end

  defp snmp_batch(value, observed_at) do
    metric_batch(
      [
        %SrMetric{
          name: "ifHCInOctets",
          metric_type: "snmp",
          kind: :METRIC_KIND_SUM,
          temporality: :METRIC_TEMPORALITY_CUMULATIVE,
          is_monotonic: true,
          unit: "By",
          counter_width: 64,
          tags: entries(%{"target" => "router-a", "host" => "10.0.0.20"}),
          metadata: entries(%{"oid" => ".1.3.6.1.2.1.31.1.1.1.6.7"}),
          points: [
            %MetricPoint{
              value: value * 1.0,
              raw_value: to_string(value),
              raw_value_type: :METRIC_VALUE_TYPE_UINT64,
              observed_at_unix_nano: observed_at,
              if_index: 7,
              interface_uid: "ifindex:7"
            }
          ]
        }
      ],
      source: "snmp-metrics",
      service_name: "snmp",
      service_type: "snmp"
    )
  end

  defp plugin_metric_batch do
    metric_batch(
      [
        %SrMetric{
          name: "proxmox_guest_cpu_ratio_max",
          metric_type: "cpu",
          kind: :METRIC_KIND_GAUGE,
          unit: "ratio",
          tags:
            entries(%{"producer_id" => "proxmox-inventory", "producer_kind" => "plugin_result"}),
          metadata: entries(%{"status" => "WARNING"}),
          points: [
            %MetricPoint{
              value: 0.91,
              raw_value: "0.91",
              raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
              observed_at_unix_nano: @point_time_a
            }
          ]
        }
      ],
      source: "plugin-result",
      service_name: "plugin",
      service_type: "plugin"
    )
  end

  defp otel_derived_duration_batch do
    metric_batch(
      [
        %SrMetric{
          name: "otel.span.duration_ms",
          metric_type: "otel_span_derived",
          kind: :METRIC_KIND_GAUGE,
          unit: "ms",
          tags: entries(%{"metric_family" => "otel_span_derived"}),
          points: [
            %MetricPoint{
              value: 42.5,
              raw_value: "42.5",
              raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
              observed_at_unix_nano: @point_time_a,
              attributes:
                entries(%{
                  "service_name" => "api",
                  "span_name" => "GET /devices"
                }),
              metadata:
                entries(%{
                  "timestamp" => "2026-06-12T00:00:00Z",
                  "span_id" => "0000000000abc123",
                  "metric_type" => "span",
                  "duration_seconds" => "0.0425"
                })
            }
          ]
        }
      ],
      source: "otel-metrics-derived",
      service_name: "otel-derived",
      service_type: "otel"
    )
  end

  defp metric_batch(metrics, opts) do
    MetricBatch.encode(%MetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %MetricResource{
        agent_id: "agent-1",
        gateway_id: "gateway-1",
        partition: "default",
        service_name: Keyword.fetch!(opts, :service_name),
        service_type: Keyword.fetch!(opts, :service_type)
      },
      ingest_identity: %IngestIdentity{
        source: Keyword.fetch!(opts, :source),
        payload_kind: "serviceradar.metric.v1",
        producer_id: "agent-1",
        producer_kind: "agent"
      },
      ingress_id: Keyword.get(opts, :ingress_id, ""),
      ingress_timestamp_unix_nano: Keyword.get(opts, :ingress_timestamp, 0),
      emitted_at_unix_nano: @point_time_a,
      metrics: metrics
    })
  end

  defp entries(map) do
    Enum.map(map, fn {key, value} -> %StringMapEntry{key: key, value: to_string(value)} end)
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
