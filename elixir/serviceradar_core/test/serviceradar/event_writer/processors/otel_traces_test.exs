defmodule ServiceRadar.EventWriter.Processors.OtelTracesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.OtelTraces

  describe "table_name/0" do
    test "returns correct table name" do
      assert OtelTraces.table_name() == "otel_traces"
    end
  end

  describe "parse_message/1" do
    test "parses valid OTEL trace message" do
      json_data = Jason.encode!(%{
        "timestamp" => "2024-01-15T10:30:00Z",
        "trace_id" => "trace-abc123",
        "span_id" => "span-def456",
        "parent_span_id" => "span-parent",
        "name" => "HTTP GET /api/users",
        "kind" => 2,
        "start_time_unix_nano" => 1705315800000000000,
        "end_time_unix_nano" => 1705315800100000000,
        "service_name" => "api-gateway",
        "service_version" => "1.5.0",
        "service_instance" => "pod-123",
        "scope_name" => "opentelemetry.sdk",
        "scope_version" => "1.0.0",
        "status_code" => 1,
        "status_message" => "OK",
        "attributes" => %{"http.method" => "GET", "http.url" => "/api/users"},
        "resource_attributes" => %{"service.name" => "api-gateway"},
        "events" => [%{"name" => "request_start", "timestamp" => 1705315800000000000}],
        "links" => []
      })

      message = %{data: json_data, metadata: %{subject: "otel.traces.test"}}
      result = OtelTraces.parse_message(message)

      assert result.trace_id == "trace-abc123"
      assert result.span_id == "span-def456"
      assert result.parent_span_id == "span-parent"
      assert result.name == "HTTP GET /api/users"
      assert result.kind == 2
      assert result.start_time_unix_nano == 1705315800000000000
      assert result.end_time_unix_nano == 1705315800100000000
      assert result.service_name == "api-gateway"
      assert result.service_version == "1.5.0"
      assert result.status_code == 1
      assert result.status_message == "OK"
      assert result.attributes != nil
      assert result.resource_attributes != nil
      assert result.events != nil
      assert %DateTime{} = result.timestamp
      assert %DateTime{} = result.created_at
    end

    test "parses camelCase fields" do
      json_data = Jason.encode!(%{
        "traceId" => "trace-camel",
        "spanId" => "span-camel",
        "parentSpanId" => "parent-camel",
        "startTimeUnixNano" => 1705315800000000000,
        "endTimeUnixNano" => 1705315800100000000,
        "serviceName" => "camel-service",
        "serviceVersion" => "2.0.0",
        "serviceInstance" => "camel-instance",
        "scopeName" => "camel-scope",
        "scopeVersion" => "1.0.0",
        "statusCode" => 0,
        "statusMessage" => "Success",
        "resourceAttributes" => %{"env" => "prod"}
      })

      message = %{data: json_data, metadata: %{}}
      result = OtelTraces.parse_message(message)

      assert result.trace_id == "trace-camel"
      assert result.span_id == "span-camel"
      assert result.parent_span_id == "parent-camel"
      assert result.start_time_unix_nano == 1705315800000000000
      assert result.end_time_unix_nano == 1705315800100000000
      assert result.service_name == "camel-service"
      assert result.service_version == "2.0.0"
      assert result.service_instance == "camel-instance"
    end

    test "handles bigint overflow in timestamps" do
      # Very large timestamp that could overflow int64
      max_int64 = 9_223_372_036_854_775_807
      overflow_value = max_int64 + 1000

      json_data = Jason.encode!(%{
        "trace_id" => "trace-overflow",
        "span_id" => "span-overflow",
        "start_time_unix_nano" => overflow_value,
        "service_name" => "test"
      })

      message = %{data: json_data, metadata: %{}}
      result = OtelTraces.parse_message(message)

      # Should be capped at max_int64
      assert result.start_time_unix_nano == max_int64
    end

    test "handles missing fields with defaults" do
      json_data = Jason.encode!(%{})
      message = %{data: json_data, metadata: %{}}
      result = OtelTraces.parse_message(message)

      assert result.service_name == "unknown"
      assert result.trace_id == nil
      assert result.span_id == nil
      assert %DateTime{} = result.timestamp
    end

    test "encodes complex attributes as JSON" do
      json_data = Jason.encode!(%{
        "trace_id" => "trace-attrs",
        "span_id" => "span-attrs",
        "attributes" => %{
          "http.method" => "POST",
          "http.status_code" => 200,
          "custom.data" => %{"nested" => "value"}
        },
        "events" => [
          %{"name" => "event1", "attributes" => %{"key" => "value"}},
          %{"name" => "event2"}
        ],
        "links" => [
          %{"trace_id" => "linked-trace", "span_id" => "linked-span"}
        ]
      })

      message = %{data: json_data, metadata: %{}}
      result = OtelTraces.parse_message(message)

      assert is_binary(result.attributes)
      assert String.contains?(result.attributes, "http.method")

      assert is_binary(result.events)
      assert String.contains?(result.events, "event1")

      assert is_binary(result.links)
      assert String.contains?(result.links, "linked-trace")
    end

    test "returns nil for invalid JSON" do
      message = %{data: "not valid json", metadata: %{}}
      result = OtelTraces.parse_message(message)

      assert result == nil
    end

    test "parses string bigint values" do
      json_data = Jason.encode!(%{
        "trace_id" => "trace-string",
        "span_id" => "span-string",
        "start_time_unix_nano" => "1705315800000000000",
        "end_time_unix_nano" => "1705315800100000000"
      })

      message = %{data: json_data, metadata: %{}}
      result = OtelTraces.parse_message(message)

      assert result.start_time_unix_nano == 1705315800000000000
      assert result.end_time_unix_nano == 1705315800100000000
    end
  end
end
