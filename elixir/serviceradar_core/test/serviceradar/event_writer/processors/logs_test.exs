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

    test "redacts sensitive NATS credentials before storing log rows" do
      json_data =
        Jason.encode!(%{
          "timestamp" => "2024-01-15T10:30:00Z",
          "severity_text" => "ERROR",
          "body" =>
            ~S|#{label => {gen_server,terminate},state => #{nkey_seed => <<"SENSITIVE_NKEY">>,jwt => <<"SENSITIVE_JWT">>}}|,
          "attributes" => %{
            "jwt" => "SENSITIVE_ATTR_JWT",
            "nested" => %{"nkey_seed" => "SENSITIVE_NESTED_SEED"},
            "safe" => "kept"
          },
          "resource_attributes" => %{"service.name" => "web-ng"}
        })

      result = Logs.parse_message(%{data: json_data, metadata: %{subject: "logs.otel"}})

      assert result.body =~ ~s|nkey_seed => <<"[REDACTED]">>|
      assert result.body =~ ~s|jwt => <<"[REDACTED]">>|
      refute result.body =~ "SENSITIVE_NKEY"
      refute result.body =~ "SENSITIVE_JWT"
      assert result.attributes["jwt"] == "[REDACTED]"
      assert result.attributes["nested"]["nkey_seed"] == "[REDACTED]"
      assert result.attributes["safe"] == "kept"
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
    end

    test "does not reconstruct SNMP trap text outside the logs.snmp Zen path" do
      result =
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

      assert result.body == nil
    end

    test "does not use SNMPv2 sysUpTime TimeTicks as the trap message" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "source" => "192.168.1.10:4161",
              "source_ip" => "192.168.1.10",
              "version" => "V2C",
              "community" => "public",
              "varbinds" => [
                %{"oid" => "1.3.6.1.2.1.1.3.0", "value" => "TIMETICKS: 38611538"},
                %{
                  "oid" => "1.3.6.1.6.3.1.1.4.1.0",
                  "value" => "OBJECT IDENTIFIER: 1.3.6.1.4.1.9.9.41.2.0.1"
                },
                %{
                  "oid" => "1.3.6.1.4.1.9.9.41.1.2.3.1.5.1",
                  "value" =>
                    "OCTET STRING: I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."
                }
              ]
            }),
          metadata: %{subject: "logs.snmp"}
        })

      assert result.body ==
               "SNMP trap 1.3.6.1.4.1.9.9.41.2.0.1 from 192.168.1.10: I 03/08/26 20:28:41 04911 ntp: The NTP Server 162.159.200.1 is unreachable."

      assert result.source_ip == "192.168.1.10"
      assert result.attributes["snmp"]["trap_oid"] == "1.3.6.1.4.1.9.9.41.2.0.1"
      assert result.attributes["snmp"]["community"] == "public"
    end

    test "snmp_severity rebuilds a trap body when the producer copied TimeTicks" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "source" => "10.0.0.8:162",
              "source_ip" => "10.0.0.8",
              "body" => "38611538",
              "varbinds" => [
                %{"oid" => "1.3.6.1.2.1.1.3.0", "value" => "TIMETICKS: 38611538"},
                %{
                  "oid" => "1.3.6.1.6.3.1.1.4.1.0",
                  "value" => "OBJECT IDENTIFIER: 1.3.6.1.6.3.1.1.5.3"
                }
              ]
            }),
          metadata: %{subject: "logs.snmp"}
        })

      assert result.body == "SNMP trap 1.3.6.1.6.3.1.1.5.3 from 10.0.0.8"
    end

    test "keeps the trap sender IP when Zen overwrites source with snmp" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "source" => "192.168.2.55:32768",
              "varbinds" => [
                %{"oid" => "1.3.6.1.2.1.1.3.0", "value" => "TIMETICKS: 12"},
                %{
                  "oid" => "1.3.6.1.6.3.1.1.4.1.0",
                  "value" => "OBJECT IDENTIFIER: 1.3.6.1.6.3.1.1.5.1"
                }
              ]
            }),
          metadata: %{subject: "logs.snmp"}
        })

      assert result.source_ip == "192.168.2.55"
      assert result.body == "SNMP trap 1.3.6.1.6.3.1.1.5.1 from 192.168.2.55"
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

    test "parses severity emitted by syslog normalization" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "host" => "syslog-host-1",
              "full_message" => "full CEF payload",
              "short_message" => "CEF:0|vendor|product|1|100|event|9|msg=blocked",
              "severity" => "Very High"
            }),
          metadata: %{subject: "logs.syslog"}
        })

      assert result.body == "CEF:0|vendor|product|1|100|event|9|msg=blocked"
      assert result.severity_text == "Very High"
      assert result.service_name == "syslog-host-1"
    end

    test "maps a bare numeric syslog level to OTEL severity text and number" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "host" => "unifi-gw",
              "level" => 4,
              "short_message" => "[NETFILTER] iptables drop"
            }),
          metadata: %{subject: "logs.syslog.processed"}
        })

      assert result.severity_text == "WARN"
      assert result.severity_number == 15
    end

    test "does not store a bare level integer as severity_text" do
      result =
        Logs.parse_message(%{
          data: Jason.encode!(%{"level" => 6, "short_message" => "info line"}),
          metadata: %{}
        })

      assert result.severity_text == "INFO"
      assert result.severity_number == 9
    end

    test "promotes partition-qualified syslog peer metadata to source_ip" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "host" => "switch-1",
              "short_message" => "interface changed",
              "_remote_addr" => "default:10.208.254.4",
              "_syslog_format" => "rfc3164",
              "attributes" => %{"device" => "switch-1"}
            }),
          metadata: %{subject: "logs.syslog"}
        })

      assert result.source_ip == "10.208.254.4"
      assert result.attributes["_remote_addr"] == "default:10.208.254.4"
      assert result.attributes["_syslog_format"] == "rfc3164"
      assert result.attributes["device"] == "switch-1"
    end

    test "preserves IPv6 peer metadata without splitting its colons" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "body" => "ipv6 syslog",
              "_remote_addr" => "site-a:2001:db8::42"
            }),
          metadata: %{subject: "logs.syslog"}
        })

      assert result.source_ip == "2001:db8::42"
      assert result.attributes["_remote_addr"] == "site-a:2001:db8::42"
    end

    test "does not create source_ip from invalid peer metadata" do
      result =
        Logs.parse_message(%{
          data: Jason.encode!(%{"body" => "unknown syslog", "_remote_addr" => "not-an-ip"}),
          metadata: %{subject: "logs.syslog"}
        })

      assert result.source_ip == nil
      assert result.attributes["_remote_addr"] == "not-an-ip"
    end

    test "preserves source_ip and fallback markers for opaque syslog records" do
      result =
        Logs.parse_message(%{
          data:
            Jason.encode!(%{
              "short_message" => "<134>LEEF:2.0|Vendor|Product|1|100|An event|",
              "_remote_addr" => "default:10.208.254.4",
              "_syslog_format" => "unknown",
              "_syslog_parse_fallback" => true
            }),
          metadata: %{subject: "logs.syslog"}
        })

      assert result.source_ip == "10.208.254.4"
      assert result.attributes["_remote_addr"] == "default:10.208.254.4"
      assert result.attributes["_syslog_format"] == "unknown"
      assert result.attributes["_syslog_parse_fallback"]
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

  describe "parse_message/1 ingest attribution" do
    @sr_headers [
      {"Sr-Ingest-Identity", "spiffe://serviceradar/gateway/gw-1"},
      {"Sr-Agent-Id", "agent-7"},
      {"Sr-Partition", "site-a"}
    ]

    test "maps Sr-* headers onto the ingest columns" do
      data =
        Jason.encode!(%{
          "timestamp" => "2024-01-15T10:30:00Z",
          "body" => "hello",
          "service_name" => "svc"
        })

      row =
        Logs.parse_message(%{
          data: data,
          metadata: %{subject: "logs.otel", headers: @sr_headers}
        })

      assert row.ingest_identity == "spiffe://serviceradar/gateway/gw-1"
      assert row.ingest_agent_id == "agent-7"
      assert row.ingest_partition == "site-a"
    end

    test "absent headers default the ingest columns to empty strings" do
      data = Jason.encode!(%{"timestamp" => "2024-01-15T10:30:00Z", "body" => "hello"})

      row = Logs.parse_message(%{data: data, metadata: %{subject: "logs.otel"}})

      assert row.ingest_identity == ""
      assert row.ingest_agent_id == ""
      assert row.ingest_partition == ""
    end
  end

  describe "prepare_rows_for_insert/1" do
    test "uses insert placeholders for repeated batch-constant text values" do
      timestamp = ~U[2024-01-15 10:30:00Z]

      rows = [
        %{
          id: Ecto.UUID.generate(),
          timestamp: timestamp,
          body: "first",
          service_name: "shared-service",
          resource_attributes: %{"host.name" => "host-a"},
          attributes: %{"serviceradar.ingest" => %{"subject" => "logs.otel"}},
          ingest_partition: "site-a"
        },
        %{
          id: Ecto.UUID.generate(),
          timestamp: timestamp,
          body: "second",
          service_name: "shared-service",
          resource_attributes: %{"host.name" => "host-a"},
          attributes: %{"serviceradar.ingest" => %{"subject" => "logs.otel"}},
          ingest_partition: "site-a"
        }
      ]

      {prepared_rows, placeholders} = Logs.prepare_rows_for_insert(rows)

      assert placeholders.logs_service_name == "shared-service"
      assert placeholders.logs_attributes == ~s({"serviceradar.ingest":{"subject":"logs.otel"}})
      assert placeholders.logs_resource_attributes == ~s({"host.name":"host-a"})
      assert placeholders.logs_ingest_partition == "site-a"

      assert Enum.all?(prepared_rows, fn row ->
               row.service_name == {:placeholder, :logs_service_name} and
                 row.attributes == {:placeholder, :logs_attributes} and
                 row.resource_attributes == {:placeholder, :logs_resource_attributes} and
                 row.ingest_partition == {:placeholder, :logs_ingest_partition}
             end)

      assert Enum.map(prepared_rows, & &1.body) == ["first", "second"]
    end

    test "leaves mixed or single-use values as ordinary binds" do
      timestamp = ~U[2024-01-15 10:30:00Z]

      rows = [
        %{id: Ecto.UUID.generate(), timestamp: timestamp, body: "one", service_name: "svc-a"},
        %{id: Ecto.UUID.generate(), timestamp: timestamp, body: "two", service_name: "svc-b"}
      ]

      {prepared_rows, placeholders} = Logs.prepare_rows_for_insert(rows)

      refute Map.has_key?(placeholders, :logs_service_name)
      refute Map.has_key?(placeholders, :logs_body)
      assert Enum.map(prepared_rows, & &1.service_name) == ["svc-a", "svc-b"]
      assert Enum.map(prepared_rows, & &1.body) == ["one", "two"]
    end
  end
end
