defmodule ServiceRadar.EventWriter.Processors.LogsTest do
  use ExUnit.Case, async: true

  alias Opentelemetry.Proto.Collector.Logs.V1.ExportLogsServiceRequest
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Logs.V1.LogRecord
  alias Opentelemetry.Proto.Logs.V1.ResourceLogs
  alias Opentelemetry.Proto.Logs.V1.ScopeLogs
  alias Opentelemetry.Proto.Resource.V1.Resource
  alias ServiceRadar.EventWriter.Processors.Logs

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
          "trace_id" => "0123456789abcdef0123456789abcdef",
          "span_id" => "0123456789abcdef",
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

      assert result.timestamp == ~U[2024-01-15 10:30:00Z]
      assert result.trace_id == "0123456789abcdef0123456789abcdef"
      assert result.span_id == "0123456789abcdef"
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
      assert %DateTime{} = result.created_at
    end

    test "parses camelCase fields" do
      json_data =
        Jason.encode!(%{
          "traceId" => "ABCDEF0123456789ABCDEF0123456789",
          "spanId" => "ABCDEF0123456789",
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

      # Uppercase hex ids are downcased to the canonical form
      assert result.trace_id == "abcdef0123456789abcdef0123456789"
      assert result.span_id == "abcdef0123456789"
      assert result.severity_text == "ERROR"
      assert result.severity_number == 17
      assert result.service_name == "camel-service"
      assert result.scope_name == "camel-scope"
      assert result.scope_version == "1.0.0"
      assert result.body == "Error occurred"
    end

    test "extracts body from various fields" do
      result1 =
        Logs.parse_message(%{data: Jason.encode!(%{"body" => "from body"}), metadata: %{}})

      assert result1.body == "from body"

      result2 =
        Logs.parse_message(%{
          data: Jason.encode!(%{"body" => %{"nested" => "data"}}),
          metadata: %{}
        })

      assert result2.body == ~s({"nested":"data"})

      result3 =
        Logs.parse_message(%{data: Jason.encode!(%{"message" => "from message"}), metadata: %{}})

      assert result3.body == "from message"

      result4 = Logs.parse_message(%{data: Jason.encode!(%{"msg" => "from msg"}), metadata: %{}})
      assert result4.body == "from msg"

      result5 =
        Logs.parse_message(%{
          data: Jason.encode!(%{"short_message" => "from short_message"}),
          metadata: %{}
        })

      assert result5.body == "from short_message"

      result6 =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "varbinds" => [
                %{
                  "oid" => "1.3.6.1.2.1.16.9.1.1.2.4911",
                  "value" =>
                    "OCTET STRING: I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
                }
              ]
            }),
          metadata: %{}
        })

      assert result6.body ==
               "I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
    end

    test "uses syslog host as service fallback" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "host" => "docker-mailserver-6bbcfbc66c-p4xjt",
              "short_message" => "dovecot: disconnected"
            }),
          metadata: %{subject: "logs.syslog.processed"}
        })

      assert result.body == "dovecot: disconnected"
      assert result.service_name == "docker-mailserver-6bbcfbc66c-p4xjt"
    end

    test "drops empty nested metadata from unmatched Zen rules" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "attributes" => %{
                "event_type" => nil,
                "security" => %{"signal" => %{"kind" => nil, "source" => nil}},
                "waf" => %{
                  "client_ip" => nil,
                  "rule_id" => nil,
                  "rule_message" => nil
                }
              },
              "short_message" => "regular syslog message"
            }),
          metadata: %{}
        })

      assert result.attributes == %{}
    end

    test "handles nanosecond timestamps" do
      timestamp_ns = 1_705_315_800_000_000_000

      json_data =
        Jason.encode!(%{
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

    test "normalizes non-canonical ids to nil" do
      json_data =
        Jason.encode!(%{
          "trace_id" => "trace-123",
          "span_id" => "span-4567-bad",
          "body" => "garbage ids"
        })

      result = Logs.parse_message(%{data: json_data, metadata: %{}})

      assert result.trace_id == nil
      assert result.span_id == nil
    end

    test "folds legacy double-hex ids arriving via JSON" do
      trace_hex = "0123456789abcdef0123456789abcdef"
      span_hex = "0123456789abcdef"

      json_data =
        Jason.encode!(%{
          "trace_id" => Base.encode16(trace_hex, case: :lower),
          "span_id" => Base.encode16(span_hex, case: :lower),
          "body" => "double hex"
        })

      result = Logs.parse_message(%{data: json_data, metadata: %{}})

      assert result.trace_id == trace_hex
      assert result.span_id == span_hex
    end

    test "protobuf bytes fields carrying ascii hex are not hexed again" do
      # The Erlang OTLP logs exporter copies hex Logger metadata verbatim
      # into the protobuf bytes fields.
      trace_hex = "0123456789abcdef0123456789abcdef"
      span_hex = "0123456789abcdef"

      log_record = %LogRecord{
        time_unix_nano: 1_705_315_800_000_000_000,
        body: %AnyValue{value: {:string_value, "ascii hex ids"}},
        trace_id: trace_hex,
        span_id: span_hex
      }

      request = %ExportLogsServiceRequest{
        resource_logs: [
          %ResourceLogs{scope_logs: [%ScopeLogs{log_records: [log_record]}]}
        ]
      }

      [row] = Logs.parse_message(%{data: ExportLogsServiceRequest.encode(request), metadata: %{}})

      assert row.trace_id == trace_hex
      assert row.span_id == span_hex
    end

    test "protobuf empty and zero ids are stored as nil" do
      log_record = %LogRecord{
        time_unix_nano: 1_705_315_800_000_000_000,
        body: %AnyValue{value: {:string_value, "no span context"}},
        trace_id: <<>>,
        span_id: :binary.copy(<<0>>, 8)
      }

      request = %ExportLogsServiceRequest{
        resource_logs: [
          %ResourceLogs{scope_logs: [%ScopeLogs{log_records: [log_record]}]}
        ]
      }

      [row] = Logs.parse_message(%{data: ExportLogsServiceRequest.encode(request), metadata: %{}})

      assert row.trace_id == nil
      assert row.span_id == nil
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
          %KeyValue{
            key: "service.name",
            value: %AnyValue{value: {:string_value, "proto-service"}}
          },
          %KeyValue{key: "service.version", value: %AnyValue{value: {:string_value, "0.1.0"}}}
        ]
      }

      resource_logs = %ResourceLogs{
        resource: resource,
        scope_logs: [scope_logs]
      }

      request = %ExportLogsServiceRequest{resource_logs: [resource_logs]}
      payload = ExportLogsServiceRequest.encode(request)

      result = Logs.parse_message(%{data: payload, metadata: %{}})

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
    end
  end
end
