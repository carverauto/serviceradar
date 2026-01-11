defmodule ServiceRadar.EventWriter.Processors.LogsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Cluster.TenantGuard
  alias ServiceRadar.EventWriter.Processors.Logs
  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Opentelemetry.Proto.Common.V1.{AnyValue, InstrumentationScope, KeyValue}
  alias Opentelemetry.Proto.Logs.V1.{LogRecord, ResourceLogs, ScopeLogs}
  alias Opentelemetry.Proto.Resource.V1.Resource

  describe "table_name/0" do
    test "returns correct table name" do
      assert Logs.table_name() == "logs"
    end
  end

  describe "parse_message/1" do
    test "parses valid OTEL log message" do
      json_data =
        Jason.encode!(%{
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

      result =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Logs.parse_message(message)
        end)

      assert result.timestamp == ~U[2024-01-15 10:30:00Z]
      assert result.trace_id == "trace-123"
      assert result.span_id == "span-456"
      assert result.severity_text == "INFO"
      assert result.severity_number == 9
      assert result.body == "Application started successfully"
      assert result.service_name == "my-service"
      assert result.service_version == "1.0.0"
      assert result.service_instance == "instance-1"
      assert result.scope_name == "my-scope"
      assert result.attributes["key"] == "value"
      assert result.attributes["serviceradar.ingest"]["subject"] == "logs.app"
      assert result.resource_attributes == %{"host.name" => "server1"}
      assert result.id
      assert result.tenant_id == "11111111-1111-1111-1111-111111111111"
      assert %DateTime{} = result.created_at
    end

    test "parses camelCase fields" do
      json_data =
        Jason.encode!(%{
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

      result =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Logs.parse_message(message)
        end)

      assert result.trace_id == "trace-camel"
      assert result.span_id == "span-camel"
      assert result.severity_text == "ERROR"
      assert result.severity_number == 17
      assert result.service_name == "camel-service"
      assert result.scope_name == "camel-scope"
      assert result.scope_version == "1.0.0"
      assert result.body == "Error occurred"
    end

    test "extracts body from various fields" do
      result1 =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Logs.parse_message(%{data: Jason.encode!(%{"body" => "from body"}), metadata: %{}})
        end)

      assert result1.body == "from body"

      result2 =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Logs.parse_message(%{data: Jason.encode!(%{"body" => %{"nested" => "data"}}), metadata: %{}})
        end)

      assert result2.body == ~s({"nested":"data"})

      result3 =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Logs.parse_message(%{data: Jason.encode!(%{"message" => "from message"}), metadata: %{}})
        end)

      assert result3.body == "from message"

      result4 =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Logs.parse_message(%{data: Jason.encode!(%{"msg" => "from msg"}), metadata: %{}})
        end)

      assert result4.body == "from msg"

      result5 =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Logs.parse_message(%{data: Jason.encode!(%{"short_message" => "from short_message"}), metadata: %{}})
        end)

      assert result5.body == "from short_message"
    end

    test "handles nanosecond timestamps" do
      timestamp_ns = 1_705_315_800_000_000_000

      json_data =
        Jason.encode!(%{
          "time_unix_nano" => timestamp_ns,
          "body" => "test"
        })

      message = %{data: json_data, metadata: %{}}

      result =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Logs.parse_message(message)
        end)

      assert %DateTime{} = result.timestamp
    end

    test "returns nil for invalid JSON" do
      message = %{data: "not valid json", metadata: %{}}

      result =
        with_tenant("11111111-1111-1111-1111-111111111111", fn ->
          Logs.parse_message(message)
        end)

      assert result == nil
    end

    test "parses protobuf ExportLogsServiceRequest" do
      trace_id = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>
      span_id = <<1, 2, 3, 4, 5, 6, 7, 8>>

      log_record = %LogRecord{
        time_unix_nano: 1_705_315_800_000_000_000,
        severity_number: :SEVERITY_NUMBER_INFO,
        severity_text: "INFO",
        body: %AnyValue{value: {:string_value, "protobuf log"}},
        trace_id: trace_id,
        span_id: span_id,
        attributes: [
          %KeyValue{key: "custom", value: %AnyValue{value: {:string_value, "value"}}}
        ]
      }

      scope = %InstrumentationScope{name: "scope", version: "1.2.3"}

      scope_logs = %ScopeLogs{
        scope: scope,
        log_records: [log_record]
      }

      resource = %Resource{
        attributes: [
          %KeyValue{key: "service.name", value: %AnyValue{value: {:string_value, "proto-service"}}},
          %KeyValue{key: "service.version", value: %AnyValue{value: {:string_value, "0.1.0"}}}
        ]
      }

      resource_logs = %ResourceLogs{
        resource: resource,
        scope_logs: [scope_logs]
      }

      request = %ExportLogsServiceRequest{resource_logs: [resource_logs]}
      payload = ExportLogsServiceRequest.encode(request)

      result =
        with_tenant("22222222-2222-2222-2222-222222222222", fn ->
          Logs.parse_message(%{data: payload, metadata: %{}})
        end)

      assert is_list(result)
      assert length(result) == 1

      row = hd(result)

      assert row.body == "protobuf log"
      assert row.service_name == "proto-service"
      assert row.service_version == "0.1.0"
      assert row.scope_name == "scope"
      assert row.scope_version == "1.2.3"
      assert row.trace_id == Base.encode16(trace_id, case: :lower)
      assert row.span_id == Base.encode16(span_id, case: :lower)
      assert row.attributes["custom"] == "value"
      assert row.id
      assert row.tenant_id == "22222222-2222-2222-2222-222222222222"
    end
  end

  defp with_tenant(tenant_id, fun) when is_function(fun, 0) do
    previous = TenantGuard.get_process_tenant()
    TenantGuard.set_process_tenant(tenant_id)

    try do
      fun.()
    after
      restore_tenant(previous)
    end
  end

  defp restore_tenant(nil), do: Process.delete(:serviceradar_tenant)
  defp restore_tenant(tenant_id), do: TenantGuard.set_process_tenant(tenant_id)
end
