defmodule ServiceRadar.EventWriter.Processors.OtelMetricsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.OtelMetrics

  describe "table_name/0" do
    test "returns correct table name" do
      assert OtelMetrics.table_name() == "otel_metrics"
    end
  end

  describe "parse_message/1" do
    test "parses valid JSON metric message" do
      json_data = Jason.encode!(%{
        "timestamp" => "2024-01-15T10:30:00Z",
        "trace_id" => "abc123",
        "span_id" => "def456",
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

      assert result.trace_id == "abc123"
      assert result.span_id == "def456"
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
      json_data = Jason.encode!(%{
        "traceId" => "trace-camel",
        "spanId" => "span-camel",
        "serviceName" => "camel-service",
        "spanName" => "camel-operation",
        "durationMs" => 200.0,
        "httpMethod" => "POST",
        "httpStatusCode" => 201
      })

      message = %{data: json_data, metadata: %{}}
      result = OtelMetrics.parse_message(message)

      assert result.trace_id == "trace-camel"
      assert result.span_id == "span-camel"
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
      json_data = Jason.encode!(%{
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
      timestamp_ms = 1705315800000

      json_data = Jason.encode!(%{
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
      json_data = Jason.encode!(%{
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
end
