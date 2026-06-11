defmodule ServiceRadar.EventWriter.Processors.OtelMetricsTest do
  use ExUnit.Case, async: true

  alias Opentelemetry.Proto.Collector.Metrics.V1.ExportMetricsServiceRequest
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.KeyValue
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

  describe "table_name/0" do
    test "returns correct table name" do
      assert OtelMetrics.table_name() == "otel_metrics"
    end
  end

  describe "parse_message/1" do
    test "parses valid JSON metric message" do
      json_data =
        Jason.encode!(%{
          "timestamp" => "2024-01-15T10:30:00Z",
          "trace_id" => "0123456789abcdef0123456789abcdef",
          "span_id" => "0123456789abcdef",
          "service_name" => "test-service",
          "span_name" => "test-operation",
          "span_kind" => "SERVER",
          "duration_ms" => 150.5,
          "http_method" => "GET",
          "http_route" => "/api/test",
          "http_status_code" => 200,
          "is_slow" => false
        })

      message = %{data: json_data, metadata: %{subject: "otel.metrics.test"}}
      result = OtelMetrics.parse_message(message)

      assert result.trace_id == "0123456789abcdef0123456789abcdef"
      assert result.span_id == "0123456789abcdef"
      assert result.service_name == "test-service"
      assert result.span_name == "test-operation"
      assert result.span_kind == "SERVER"
      assert result.duration_ms == 150.5
      assert result.http_method == "GET"
      assert result.http_route == "/api/test"
      assert result.http_status_code == "200"
      assert result.is_slow == false
      assert %DateTime{} = result.timestamp
      assert %DateTime{} = result.created_at
    end

    test "parses camelCase fields" do
      json_data =
        Jason.encode!(%{
          "traceId" => "ABCDEF0123456789ABCDEF0123456789",
          "spanId" => "ABCDEF0123456789",
          "serviceName" => "camel-service",
          "spanName" => "camel-operation",
          "durationMs" => 200.0,
          "httpMethod" => "POST",
          "httpStatusCode" => 201
        })

      message = %{data: json_data, metadata: %{}}
      result = OtelMetrics.parse_message(message)

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
      json_data = Jason.encode!(%{})
      message = %{data: json_data, metadata: %{}}
      result = OtelMetrics.parse_message(message)

      assert result.service_name == "unknown"
      assert result.span_name == "unknown"
      assert result.trace_id == nil
      assert result.span_id == nil
      assert %DateTime{} = result.timestamp
    end

    test "parses duration_seconds and converts to duration_ms" do
      json_data =
        Jason.encode!(%{
          "duration_seconds" => 1.5,
          "service_name" => "test"
        })

      message = %{data: json_data, metadata: %{}}
      result = OtelMetrics.parse_message(message)

      assert result.duration_ms == 1500.0
      assert result.duration_seconds == 1.5
    end

    test "handles integer timestamps" do
      # Unix timestamp in milliseconds
      timestamp_ms = 1_705_315_800_000

      json_data =
        Jason.encode!(%{
          "timestamp" => timestamp_ms,
          "service_name" => "test"
        })

      message = %{data: json_data, metadata: %{}}
      result = OtelMetrics.parse_message(message)

      assert %DateTime{} = result.timestamp
    end

    test "returns nil for invalid JSON" do
      message = %{data: "not valid json", metadata: %{}}
      result = OtelMetrics.parse_message(message)

      assert result == nil
    end

    test "handles gRPC fields" do
      json_data =
        Jason.encode!(%{
          "service_name" => "grpc-service",
          "grpc_service" => "MyService",
          "grpc_method" => "GetData",
          "grpc_status_code" => 0
        })

      message = %{data: json_data, metadata: %{}}
      result = OtelMetrics.parse_message(message)

      assert result.grpc_service == "MyService"
      assert result.grpc_method == "GetData"
      assert result.grpc_status_code == "0"
    end
  end

  describe "parse_message/1 with protobuf metric points" do
    @point_time 1_705_315_800_123_456_789

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
      assert is_binary(sum_row.attributes)
      assert sum_row.attributes =~ "destination"
      assert sum_row.attributes_hash =~ ~r/^[0-9a-f]{32}$/

      assert sum_row.attributes_hash ==
               :md5 |> :crypto.hash(sum_row.attributes) |> Base.encode16(case: :lower)

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

      # Histogram point
      assert histogram_row.metric_name == "http_request_duration"
      assert histogram_row.metric_type == "histogram"
      assert histogram_row.unit == "ms"
      assert histogram_row.temporality == "delta"
      assert histogram_row.value == nil
      assert histogram_row.count == 10
      assert histogram_row.sum == 123.5
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
    end
  end
end
