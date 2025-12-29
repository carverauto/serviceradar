defmodule ServiceRadar.EventWriter.Processors.LogsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.Logs

  describe "table_name/0" do
    test "returns correct table name" do
      assert Logs.table_name() == "ocsf_events"
    end
  end

  describe "parse_message/1" do
    test "parses valid OTEL log message to OCSF format" do
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

      # OCSF Classification
      assert result.class_uid == 1008
      assert result.category_uid == 1
      assert result.type_uid == 100801
      assert result.activity_id == 1
      assert result.severity_id == 1  # Informational for INFO
      assert result.severity == "Informational"

      # Content
      assert result.message == "Application started successfully"

      # OpenTelemetry trace context
      assert result.trace_id == "trace-123"
      assert result.span_id == "span-456"

      # Log-specific fields
      assert result.log_provider == "my-service"
      assert result.log_name == "my-scope"
      assert result.log_level == "INFO"

      # Actor
      assert result.actor.app_name == "my-service"
      assert result.actor.app_ver == "1.0.0"

      # Timestamps
      assert %DateTime{} = result.time
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
        "resourceAttributes" => %{"env" => "prod"},
        "body" => "Error occurred"
      })

      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      assert result.trace_id == "trace-camel"
      assert result.span_id == "span-camel"
      assert result.severity_id == 4  # High for ERROR
      assert result.severity == "High"
      assert result.log_provider == "camel-service"
      assert result.log_name == "camel-scope"
      assert result.log_version == "1.0.0"
      assert result.log_level == "ERROR"
    end

    test "trace_id and span_id are nil if not provided" do
      json_data = Jason.encode!(%{
        "body" => "Log without trace context",
        "service_name" => "test-service"
      })

      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      # In OCSF, trace context is optional
      assert result.trace_id == nil
      assert result.span_id == nil
    end

    test "extracts message from various body fields" do
      # String body
      result1 = Logs.parse_message(%{
        data: Jason.encode!(%{"body" => "from body"}),
        metadata: %{}
      })
      assert result1.message == "from body"

      # Map body (converted to JSON)
      result2 = Logs.parse_message(%{
        data: Jason.encode!(%{"body" => %{"nested" => "data"}}),
        metadata: %{}
      })
      assert result2.message == ~s({"nested":"data"})

      # message field
      result3 = Logs.parse_message(%{
        data: Jason.encode!(%{"message" => "from message"}),
        metadata: %{}
      })
      assert result3.message == "from message"

      # msg field
      result4 = Logs.parse_message(%{
        data: Jason.encode!(%{"msg" => "from msg"}),
        metadata: %{}
      })
      assert result4.message == "from msg"

      # short_message field (GELF)
      result5 = Logs.parse_message(%{
        data: Jason.encode!(%{"short_message" => "from short_message"}),
        metadata: %{}
      })
      assert result5.message == "from short_message"
    end

    test "maps severity levels correctly" do
      severities = [
        {"FATAL", 6, "Fatal"},
        {"CRITICAL", 5, "Critical"},
        {"ERROR", 4, "High"},
        {"WARN", 3, "Medium"},
        {"WARNING", 3, "Medium"},
        {"INFO", 1, "Informational"},
        {"DEBUG", 1, "Informational"},
        {"TRACE", 1, "Informational"}
      ]

      for {level, expected_id, expected_name} <- severities do
        json_data = Jason.encode!(%{
          "level" => level,
          "body" => "test"
        })

        message = %{data: json_data, metadata: %{}}
        result = Logs.parse_message(message)

        assert result.severity_id == expected_id,
          "Expected severity_id #{expected_id} for #{level}, got #{result.severity_id}"
        assert result.severity == expected_name,
          "Expected severity #{expected_name} for #{level}, got #{result.severity}"
      end
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

      assert %DateTime{} = result.time
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

      # OCSF required fields have defaults
      assert result.class_uid == 1008
      assert result.category_uid == 1
      assert result.severity_id == 0  # Unknown
      assert result.severity == "Unknown"
      assert result.log_provider == "unknown"
      assert %DateTime{} = result.time
    end

    test "builds metadata with OCSF version" do
      json_data = Jason.encode!(%{
        "body" => "test",
        "attributes" => %{"custom" => "attr"}
      })

      message = %{data: json_data, metadata: %{subject: "logs.test"}}
      result = Logs.parse_message(message)

      assert result.metadata.version == "1.7.0"
      assert result.metadata.product.vendor_name == "ServiceRadar"
      assert result.metadata.product.name == "EventWriter"
      assert result.metadata.correlation_uid == "logs.test"
      assert result.metadata.original_attributes == %{"custom" => "attr"}
    end

    test "builds observables for IP and hostname" do
      json_data = Jason.encode!(%{
        "body" => "test",
        "hostname" => "server1",
        "host_ip" => "192.168.1.100"
      })

      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      assert length(result.observables) == 2

      hostnames = Enum.filter(result.observables, & &1.type == "Hostname")
      assert length(hostnames) == 1
      assert hd(hostnames).name == "server1"

      ips = Enum.filter(result.observables, & &1.type == "IP Address")
      assert length(ips) == 1
      assert hd(ips).name == "192.168.1.100"
    end

    test "builds device info from log data" do
      json_data = Jason.encode!(%{
        "body" => "test",
        "hostname" => "server1",
        "host_ip" => "192.168.1.100"
      })

      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      assert result.device.hostname == "server1"
      assert result.device.ip == "192.168.1.100"
    end

    test "extracts unmapped fields" do
      json_data = Jason.encode!(%{
        "body" => "test",
        "custom_field" => "custom_value",
        "another_field" => 123
      })

      message = %{data: json_data, metadata: %{}}
      result = Logs.parse_message(message)

      assert result.unmapped["custom_field"] == "custom_value"
      assert result.unmapped["another_field"] == 123
    end
  end
end
