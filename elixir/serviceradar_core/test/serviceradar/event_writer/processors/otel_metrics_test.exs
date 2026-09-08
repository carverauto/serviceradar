defmodule ServiceRadar.EventWriter.Processors.OtelMetricsTest do
  use ExUnit.Case, async: true

  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.ArrayValue
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Common.V1.KeyValueList
  alias Opentelemetry.Proto.Metrics.V1.Gauge
  alias Opentelemetry.Proto.Metrics.V1.Histogram
  alias Opentelemetry.Proto.Metrics.V1.HistogramDataPoint
  alias Opentelemetry.Proto.Metrics.V1.Metric
  alias Opentelemetry.Proto.Metrics.V1.NumberDataPoint
  alias Opentelemetry.Proto.Metrics.V1.ResourceMetrics
  alias Opentelemetry.Proto.Metrics.V1.ScopeMetrics
  alias Opentelemetry.Proto.Metrics.V1.Sum
  alias Opentelemetry.Proto.Resource.V1.Resource
  alias ServiceRadar.EventWriter.Processors.OtelMetrics
  alias Serviceradar.Metric.V1.IngestIdentity, as: SRIngestIdentity
  alias Serviceradar.Metric.V1.Metric, as: SRMetric
  alias Serviceradar.Metric.V1.MetricBatch, as: SRMetricBatch
  alias Serviceradar.Metric.V1.MetricPoint, as: SRMetricPoint
  alias Serviceradar.Metric.V1.MetricResource, as: SRMetricResource
  alias Serviceradar.Metric.V1.StringMapEntry, as: SRStringMapEntry

  describe "table_name/0" do
    test "returns correct table name" do
      assert OtelMetrics.table_name() == "otel_metrics"
    end
  end

  describe "parse_message/1" do
    test "parses valid derived MetricBatch message" do
      message = %{
        data:
          derived_metric_payload(
            trace_id: "0123456789abcdef0123456789abcdef",
            span_id: "0123456789abcdef",
            service_name: "test-service",
            span_name: "test-operation",
            span_kind: "SERVER",
            duration_ms: 150.5,
            duration_seconds: "0.1505",
            metric_type: "http",
            http_method: "GET",
            http_route: "/api/test",
            http_status_code: "200",
            is_slow: "false"
          ),
        metadata: %{subject: "otel.metrics.derived"}
      }

      [result] = OtelMetrics.parse_message(message)

      assert result.trace_id == "0123456789abcdef0123456789abcdef"
      assert result.span_id == "0123456789abcdef"
      assert result.service_name == "test-service"
      assert result.span_name == "test-operation"
      assert result.span_kind == "SERVER"
      assert result.duration_ms == 150.5
      assert result.duration_seconds == 0.1505
      assert result.metric_type == "http"
      assert result.http_method == "GET"
      assert result.http_route == "/api/test"
      assert result.http_status_code == "200"
      assert result.is_slow == false
      assert %DateTime{} = result.timestamp
      assert %DateTime{} = result.created_at
    end

    test "normalizes uppercase ids from derived MetricBatch metadata" do
      message = %{
        data:
          derived_metric_payload(
            trace_id: "ABCDEF0123456789ABCDEF0123456789",
            span_id: "ABCDEF0123456789",
            service_name: "camel-service",
            span_name: "camel-operation",
            duration_ms: 200.0,
            http_method: "POST",
            http_status_code: "201"
          ),
        metadata: %{subject: "otel.metrics.derived"}
      }

      [result] = OtelMetrics.parse_message(message)

      # Uppercase hex ids are downcased to the canonical form
      assert result.trace_id == "abcdef0123456789abcdef0123456789"
      assert result.span_id == "abcdef0123456789"
      assert result.service_name == "camel-service"
      assert result.span_name == "camel-operation"
      assert result.duration_ms == 200.0
      assert result.http_method == "POST"
      assert result.http_status_code == "201"
    end

    test "handles missing fields with defaults" do
      message = %{data: derived_metric_payload([]), metadata: %{subject: "otel.metrics.derived"}}
      [result] = OtelMetrics.parse_message(message)

      assert result.service_name == "unknown"
      assert result.span_name == "unknown"
      assert result.trace_id == nil
      assert result.span_id == nil
      assert %DateTime{} = result.timestamp
    end

    test "rejects legacy JSON derived metric message" do
      json_data = Jason.encode!(%{"duration_ms" => 1500.0, "service_name" => "test"})
      message = %{data: json_data, metadata: %{subject: "otel.metrics.derived"}}

      assert OtelMetrics.parse_message(message) == nil
    end

    test "returns nil for invalid protobuf" do
      message = %{data: "not valid protobuf", metadata: %{subject: "otel.metrics.derived"}}
      result = OtelMetrics.parse_message(message)

      assert result == nil
    end

    test "handles gRPC fields" do
      message = %{
        data:
          derived_metric_payload(
            service_name: "grpc-service",
            grpc_service: "MyService",
            grpc_method: "GetData",
            grpc_status_code: "0"
          ),
        metadata: %{subject: "otel.metrics.derived"}
      }

      [result] = OtelMetrics.parse_message(message)

      assert result.grpc_service == "MyService"
      assert result.grpc_method == "GetData"
      assert result.grpc_status_code == "0"
    end
  end

  defp derived_metric_payload(opts) do
    attrs =
      opts
      |> Keyword.take([
        :service_name,
        :span_name,
        :span_kind,
        :http_method,
        :http_route,
        :http_status_code,
        :grpc_service,
        :grpc_method,
        :grpc_status_code
      ])
      |> sr_entries()

    metadata =
      opts
      |> Keyword.take([
        :trace_id,
        :span_id,
        :duration_seconds,
        :metric_type,
        :is_slow,
        :component,
        :level
      ])
      |> sr_entries()

    SRMetricBatch.encode(%SRMetricBatch{
      schema_version: "serviceradar.metric.v1",
      resource: %SRMetricResource{service_name: "otel-derived", service_type: "otel"},
      ingest_identity: %SRIngestIdentity{
        source: "otel-metrics-derived",
        payload_kind: "serviceradar.metric.v1",
        producer_id: "otel-collector",
        producer_kind: "otel-collector"
      },
      metrics: [
        %SRMetric{
          name: "otel.span.duration_ms",
          metric_type: "otel_span_derived",
          kind: :METRIC_KIND_GAUGE,
          unit: "ms",
          points: [
            %SRMetricPoint{
              value: Keyword.get(opts, :duration_ms, 0.0),
              raw_value: to_string(Keyword.get(opts, :duration_ms, 0.0)),
              raw_value_type: :METRIC_VALUE_TYPE_DOUBLE,
              observed_at_unix_nano:
                Keyword.get(opts, :observed_at_unix_nano, 1_705_315_800_000_000_000),
              attributes: attrs,
              metadata: metadata
            }
          ]
        }
      ]
    })
  end

  defp sr_entries(entries) do
    entries
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn {key, value} ->
      %SRStringMapEntry{key: Atom.to_string(key), value: to_string(value)}
    end)
  end

  describe "parse_message/1 with protobuf metric points" do
    @point_time 1_705_315_800_123_456_789
    @point_start_time 1_705_315_700_000_000_000

    # attributes_hash recipe v2 literals — the Go gateway asserts the SAME
    # values for these fixtures. Hash input:
    #   canonical_bytes(attrs) <> "\n" <> service_instance_id <> "\n" <> scope_name
    #
    #   {"destination":"slack"}\n\n      -> @hash_destination_slack
    #   {}\n\n                           -> @hash_empty_attrs
    #   {"a":"1","b":"2"}\n\n            -> @hash_ordered_ab
    @hash_destination_slack "0a400c7afa11f7cb8f6b057bfc2ced04"
    @hash_empty_attrs "5ad5cc4d26869082efd29c436b57384a"
    @hash_ordered_ab "08d15b1d3dba45bfb72b5ba30c440f5c"

    defp build_metrics_request do
      sum_metric = %Metric{
        name: "falcosecurity_falcosidekick_outputs",
        unit: "1",
        data:
          {:sum,
           %Sum{
             aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE,
             is_monotonic: true,
             data_points: [
               %NumberDataPoint{
                 time_unix_nano: @point_time,
                 value: {:as_int, 42},
                 attributes: [
                   %KeyValue{
                     key: "destination",
                     value: %AnyValue{value: {:string_value, "slack"}}
                   }
                 ]
               }
             ]
           }}
      }

      gauge_metric = %Metric{
        name: "process_cpu_usage",
        data:
          {:gauge,
           %Gauge{
             data_points: [
               %NumberDataPoint{
                 time_unix_nano: @point_time,
                 value: {:as_double, 0.5}
               }
             ]
           }}
      }

      histogram_metric = %Metric{
        name: "http_request_duration",
        unit: "ms",
        data:
          {:histogram,
           %Histogram{
             aggregation_temporality: :AGGREGATION_TEMPORALITY_DELTA,
             data_points: [
               %HistogramDataPoint{
                 time_unix_nano: @point_time,
                 count: 10,
                 sum: 123.5,
                 bucket_counts: [1, 2, 7],
                 explicit_bounds: [10.0, 100.0]
               }
             ]
           }}
      }

      %ExportMetricsServiceRequest{
        resource_metrics: [
          %ResourceMetrics{
            resource: %Resource{
              attributes: [
                %KeyValue{
                  key: "service.name",
                  value: %AnyValue{value: {:string_value, "metrics-service"}}
                }
              ]
            },
            scope_metrics: [
              %ScopeMetrics{metrics: [sum_metric, gauge_metric, histogram_metric]}
            ]
          }
        ]
      }
    end

    test "decodes sum, gauge, and histogram points into otel_metric_points rows" do
      payload = ExportMetricsServiceRequest.encode(build_metrics_request())

      result = OtelMetrics.parse_message(%{data: payload, metadata: %{}})

      assert is_list(result)
      assert length(result) == 3

      [sum_row, gauge_row, histogram_row] = result

      # Sum point
      assert sum_row.metric_name == "falcosecurity_falcosidekick_outputs"
      assert sum_row.metric_type == "sum"
      assert sum_row.unit == "1"
      assert sum_row.temporality == "cumulative"
      assert sum_row.is_monotonic == true
      assert sum_row.service_name == "metrics-service"
      assert sum_row.value == 42.0
      assert sum_row.count == nil
      assert sum_row.attributes == ~s({"destination":"slack"})

      # Identity defaults: no service.instance.id, no scope, no start time
      assert sum_row.service_instance_id == ""
      assert sum_row.scope_name == ""
      assert sum_row.start_time_unix_nano == nil

      # Recipe v2 literal (cross-checked against the Go implementation):
      # md5("{\"destination\":\"slack\"}\n\n")
      assert sum_row.attributes_hash == @hash_destination_slack

      # Point timestamps preserve microsecond precision
      assert sum_row.timestamp == DateTime.from_unix!(div(@point_time, 1000), :microsecond)
      assert sum_row.timestamp.microsecond == {123_456, 6}

      # Gauge point
      assert gauge_row.metric_name == "process_cpu_usage"
      assert gauge_row.metric_type == "gauge"
      assert gauge_row.unit == nil
      assert gauge_row.temporality == nil
      assert gauge_row.is_monotonic == nil
      assert gauge_row.value == 0.5
      assert gauge_row.attributes == "{}"
      # md5("{}\n\n")
      assert gauge_row.attributes_hash == @hash_empty_attrs

      # Histogram point
      assert histogram_row.metric_name == "http_request_duration"
      assert histogram_row.metric_type == "histogram"
      assert histogram_row.unit == "ms"
      assert histogram_row.temporality == "delta"
      assert histogram_row.value == nil
      assert histogram_row.count == 10
      assert histogram_row.sum == 123.5
      assert histogram_row.attributes_hash == @hash_empty_attrs
      assert Jason.decode!(histogram_row.bucket_counts) == [1, 2, 7]
      assert Jason.decode!(histogram_row.explicit_bounds) == [10.0, 100.0]
    end

    test "attributes_hash is stable across attribute ordering" do
      point = fn attributes ->
        %ExportMetricsServiceRequest{
          resource_metrics: [
            %ResourceMetrics{
              scope_metrics: [
                %ScopeMetrics{
                  metrics: [
                    %Metric{
                      name: "ordered",
                      data:
                        {:gauge,
                         %Gauge{
                           data_points: [
                             %NumberDataPoint{
                               time_unix_nano: @point_time,
                               value: {:as_double, 1.0},
                               attributes: attributes
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

      kv = fn key, value ->
        %KeyValue{key: key, value: %AnyValue{value: {:string_value, value}}}
      end

      [row_a] =
        OtelMetrics.parse_message(%{
          data: ExportMetricsServiceRequest.encode(point.([kv.("a", "1"), kv.("b", "2")])),
          metadata: %{}
        })

      [row_b] =
        OtelMetrics.parse_message(%{
          data: ExportMetricsServiceRequest.encode(point.([kv.("b", "2"), kv.("a", "1")])),
          metadata: %{}
        })

      assert row_a.attributes_hash == row_b.attributes_hash
      # Recipe v2 literal: md5("{\"a\":\"1\",\"b\":\"2\"}\n\n")
      assert row_a.attributes_hash == @hash_ordered_ab
      assert row_a.attributes == ~s({"a":"1","b":"2"})
    end

    test "folds service_instance_id, scope_name, and start_time into point identity" do
      request = %ExportMetricsServiceRequest{
        resource_metrics: [
          %ResourceMetrics{
            resource: %Resource{
              attributes: [
                %KeyValue{
                  key: "service.name",
                  value: %AnyValue{value: {:string_value, "metrics-service"}}
                },
                %KeyValue{
                  key: "service.instance.id",
                  value: %AnyValue{value: {:string_value, "instance-7"}}
                }
              ]
            },
            scope_metrics: [
              %ScopeMetrics{
                scope: %InstrumentationScope{name: "sr.scope", version: "1.2.3"},
                metrics: [
                  %Metric{
                    name: "identity_rich",
                    data:
                      {:gauge,
                       %Gauge{
                         data_points: [
                           %NumberDataPoint{
                             time_unix_nano: @point_time,
                             start_time_unix_nano: @point_start_time,
                             value: {:as_double, 1.0},
                             attributes: rich_attributes()
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

      [row] =
        OtelMetrics.parse_message(%{
          data: ExportMetricsServiceRequest.encode(request),
          metadata: %{}
        })

      assert row.service_name == "metrics-service"
      assert row.service_instance_id == "instance-7"
      assert row.scope_name == "sr.scope"
      assert row.start_time_unix_nano == @point_start_time

      # Recipe v2 literal (cross-checked against the Go implementation).
      # canonical_bytes:
      #   {"arr":["x",1,f4004000000000000,false],"bool":true,"bytes":b/wAB,
      #    "float":f3fe0000000000000,"int":42,"neg":fbff8000000000000,
      #    "nested":{"a":{"deep":[1,2]},"z":"last"},"none":null,
      #    "str":"va\"l\\ue"}
      # hash input suffix: "\n" <> "instance-7" <> "\n" <> "sr.scope"
      assert row.attributes_hash == "94d9dd949b532a243809a41937972918"

      # Display JSON: sorted keys at every level, bytes as Base64 strings
      assert row.attributes ==
               ~s({"arr":["x",1,2.5,false],"bool":true,"bytes":"/wAB",) <>
                 ~s("float":0.5,"int":42,"neg":-1.5,) <>
                 ~s("nested":{"a":{"deep":[1,2]},"z":"last"},"none":null,) <>
                 ~s("str":"va\\"l\\\\ue"})
    end

    defp rich_attributes do
      any = fn value -> %AnyValue{value: value} end

      [
        %KeyValue{
          key: "arr",
          value:
            any.(
              {:array_value,
               %ArrayValue{
                 values: [
                   any.({:string_value, "x"}),
                   any.({:int_value, 1}),
                   any.({:double_value, 2.5}),
                   any.({:bool_value, false})
                 ]
               }}
            )
        },
        %KeyValue{key: "bool", value: any.({:bool_value, true})},
        %KeyValue{key: "bytes", value: any.({:bytes_value, <<255, 0, 1>>})},
        %KeyValue{key: "float", value: any.({:double_value, 0.5})},
        %KeyValue{key: "int", value: any.({:int_value, 42})},
        %KeyValue{key: "neg", value: any.({:double_value, -1.5})},
        %KeyValue{
          key: "nested",
          value:
            any.(
              {:kvlist_value,
               %KeyValueList{
                 values: [
                   %KeyValue{key: "z", value: any.({:string_value, "last"})},
                   %KeyValue{
                     key: "a",
                     value:
                       any.(
                         {:kvlist_value,
                          %KeyValueList{
                            values: [
                              %KeyValue{
                                key: "deep",
                                value:
                                  any.(
                                    {:array_value,
                                     %ArrayValue{
                                       values: [
                                         any.({:int_value, 1}),
                                         any.({:int_value, 2})
                                       ]
                                     }}
                                  )
                              }
                            ]
                          }}
                       )
                   }
                 ]
               }}
            )
        },
        %KeyValue{key: "none", value: %AnyValue{value: nil}},
        %KeyValue{key: "str", value: any.({:string_value, "va\"l\\ue"})}
      ]
    end
  end

  describe "parse_message/1 ingest attribution" do
    @sr_headers [
      {"Sr-Ingest-Identity", "spiffe://serviceradar/gateway/gw-1"},
      {"Sr-Agent-Id", "agent-7"},
      {"Sr-Partition", "site-a"}
    ]

    test "maps Sr-* headers onto span-sample rows" do
      [row] =
        OtelMetrics.parse_message(%{
          data: derived_metric_payload(service_name: "svc", span_name: "op", duration_ms: 12.5),
          metadata: %{subject: "otel.metrics.derived", headers: @sr_headers}
        })

      assert row.ingest_identity == "spiffe://serviceradar/gateway/gw-1"
      assert row.ingest_agent_id == "agent-7"
      assert row.ingest_partition == "site-a"
    end

    test "maps Sr-* headers onto every protobuf metric point row" do
      payload = ExportMetricsServiceRequest.encode(build_metrics_request())

      rows =
        OtelMetrics.parse_message(%{
          data: payload,
          metadata: %{subject: "otel.metrics.raw", headers: @sr_headers}
        })

      assert is_list(rows)
      assert rows != []

      for row <- rows do
        assert row.metric_name
        assert row.ingest_identity == "spiffe://serviceradar/gateway/gw-1"
        assert row.ingest_agent_id == "agent-7"
        assert row.ingest_partition == "site-a"
      end
    end

    test "absent headers default the ingest columns to empty strings" do
      [row] =
        OtelMetrics.parse_message(%{
          data: derived_metric_payload(service_name: "svc", span_name: "op"),
          metadata: %{subject: "otel.metrics.derived"}
        })

      assert row.ingest_identity == ""
      assert row.ingest_agent_id == ""
      assert row.ingest_partition == ""
    end
  end
end
