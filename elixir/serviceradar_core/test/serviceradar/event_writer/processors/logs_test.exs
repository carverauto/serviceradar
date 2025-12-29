defmodule ServiceRadar.EventWriter.Processors.LogsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.Logs

  describe "table_name/0" do
    test "returns correct table name" do
      assert Logs.table_name() == "logs"
    end
  end

  describe "parse_message/1" do
    test "parses valid OTEL log message" do
      json_data = Jason.encode!(%{
        "timestamp" => "2024-01-15T10:30:00Z",
        "trace_id" => "trace-123",
        "span_id" => "span-456",
        "severity_text" => "INFO",
        "severity_number" => 9,
        "body" => "Application started successfully",
        "service_name" => "my-service",
        "service_version" => "1.0.0",
        "service_instance" => "instance-1",
        "scope_name" => "my-scope",
        "attributes" => %{"key" => "value"},
        "resource_attributes" => %{"host.name" => "server1"}
      })

      message = %{data: json_data, metadata: %{subject: "logs.app"}}
      result = Logs.parse_message(message)

      assert result.trace_id == "trace-123"
      assert result.span_id == "span-456"
      assert result.severity_text == "INFO"
      assert result.severity_number == 9
      assert result.body == "Application started successfully"
      assert result.service_name == "my-service"
      assert result.service_version == "1.0.0"
      assert result.service_instance == "instance-1"
      assert result.scope_name == "my-scope"
      assert result.attributes == ~s({"key":"value"})
      assert result.resource_attributes == ~s({"host.name":"server1"})
      assert %DateTime{} = result.timestamp
      assert %DateTime{} = result.created_at
    end

    test "parses camelCase fields" do
      json_data = Jason.encode!(%{
        "traceId" => "trace-camel",
        "spanId" => "span-camel",
        "severityText" => "ERROR",
        "severityNumber" => 17,
        "serviceName" => "camel-service",
        "serviceVersion" => "2.0.0",
        "serviceInstance" => "camel-instance",
        "scopeName" => "camel-scope",
        "scopeVersion" => "1.0.0",
        "resourceAttributes" => %{"env" => "prod"}
      })

      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      assert result.trace_id == "trace-camel"
      assert result.span_id == "span-camel"
      assert result.severity_text == "ERROR"
      assert result.severity_number == 17
      assert result.service_name == "camel-service"
      assert result.service_version == "2.0.0"
      assert result.service_instance == "camel-instance"
      assert result.scope_name == "camel-scope"
      assert result.scope_version == "1.0.0"
    end

    test "generates trace_id and span_id if missing" do
      json_data = Jason.encode!(%{
        "body" => "Log without trace context",
        "service_name" => "test-service"
      })

      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      assert result.trace_id != nil
      assert result.span_id != nil
      assert String.length(result.trace_id) > 0
      assert String.length(result.span_id) > 0
    end

    test "extracts body from various fields" do
      # String body
      result1 = Logs.parse_message(%{
        data: Jason.encode!(%{"body" => "from body"}),
        metadata: %{}
      })
      assert result1.body == "from body"

      # Map body (converted to JSON)
      result2 = Logs.parse_message(%{
        data: Jason.encode!(%{"body" => %{"nested" => "data"}}),
        metadata: %{}
      })
      assert result2.body == ~s({"nested":"data"})

      # message field
      result3 = Logs.parse_message(%{
        data: Jason.encode!(%{"message" => "from message"}),
        metadata: %{}
      })
      assert result3.body == "from message"

      # msg field
      result4 = Logs.parse_message(%{
        data: Jason.encode!(%{"msg" => "from msg"}),
        metadata: %{}
      })
      assert result4.body == "from msg"

      # short_message field (GELF)
      result5 = Logs.parse_message(%{
        data: Jason.encode!(%{"short_message" => "from short_message"}),
        metadata: %{}
      })
      assert result5.body == "from short_message"
    end

    test "uses level field for severity_text" do
      json_data = Jason.encode!(%{
        "level" => "WARNING",
        "body" => "test"
      })

      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      assert result.severity_text == "WARNING"
    end

    test "handles nanosecond timestamps" do
      # Unix timestamp in nanoseconds
      timestamp_ns = 1705315800000000000

      json_data = Jason.encode!(%{
        "time_unix_nano" => timestamp_ns,
        "body" => "test"
      })

      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      assert %DateTime{} = result.timestamp
    end

    test "returns nil for invalid JSON" do
      message = %{data: "not valid json", metadata: %{}}
      result = Logs.parse_message(message)

      assert result == nil
    end

    test "handles missing fields with defaults" do
      json_data = Jason.encode!(%{})
      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      assert result.service_name == "unknown"
      assert result.trace_id != nil  # Generated
      assert result.span_id != nil   # Generated
      assert %DateTime{} = result.timestamp
    end
  end
end
