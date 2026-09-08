defmodule ServiceRadar.EventWriter.Processors.OtelTracesTest do
  use ExUnit.Case, async: true

  alias Opentelemetry.Proto.Collector.Trace.V1.ExportTraceServiceRequest
  alias Opentelemetry.Proto.Common.V1.AnyValue
  alias Opentelemetry.Proto.Common.V1.InstrumentationScope
  alias Opentelemetry.Proto.Common.V1.KeyValue
  alias Opentelemetry.Proto.Resource.V1.Resource
  alias Opentelemetry.Proto.Trace.V1.ResourceSpans
  alias Opentelemetry.Proto.Trace.V1.ScopeSpans
  alias Opentelemetry.Proto.Trace.V1.Span
  alias Opentelemetry.Proto.Trace.V1.Status
  alias ServiceRadar.EventWriter.Processors.OtelTraces

  describe "table_name/0" do
    test "returns correct table name" do
      assert OtelTraces.table_name() == "otel_traces"
    end
  end

  describe "parse_message/1" do
    test "parses valid OTEL trace message" do
      json_data =
        Jason.encode!(%{
          "timestamp" => "2024-01-15T10:30:00Z",
          "trace_id" => "0123456789abcdef0123456789abcdef",
          "span_id" => "0123456789abcdef",
          "parent_span_id" => "fedcba9876543210",
          "name" => "HTTP GET /api/users",
          "kind" => 2,
          "start_time_unix_nano" => 1_705_315_800_000_000_000,
          "end_time_unix_nano" => 1_705_315_800_100_000_000,
          "service_name" => "api-gateway",
          "service_version" => "1.5.0",
          "service_instance" => "pod-123",
          "scope_name" => "opentelemetry.sdk",
          "scope_version" => "1.0.0",
          "status_code" => 1,
          "status_message" => "OK",
          "trace_state" => "congo=t61rcWkgMzE",
          "scope_attributes" => %{"zeta" => 1, "alpha" => "a"},
          "dropped_attributes_count" => 2,
          "dropped_events_count" => 1,
          "dropped_links_count" => 4,
          "service_namespace" => "payments",
          "deployment_environment" => "dev",
          "attributes" => %{"http.method" => "GET", "http.url" => "/api/users"},
          "resource_attributes" => %{"service.name" => "api-gateway"},
          "events" => [%{"name" => "request_start", "timestamp" => 1_705_315_800_000_000_000}],
          "links" => []
        })

      message = %{data: json_data, metadata: %{subject: "otel.traces.test"}}
      result = OtelTraces.parse_message(message)

      assert result.trace_id == "0123456789abcdef0123456789abcdef"
      assert result.span_id == "0123456789abcdef"
      assert result.parent_span_id == "fedcba9876543210"
      assert result.name == "HTTP GET /api/users"
      assert result.kind == 2
      assert result.start_time_unix_nano == 1_705_315_800_000_000_000
      assert result.end_time_unix_nano == 1_705_315_800_100_000_000
      assert result.service_name == "api-gateway"
      assert result.service_version == "1.5.0"
      assert result.status_code == 1
      assert result.status_message == "OK"
      assert result.trace_state == "congo=t61rcWkgMzE"
      # Scope attributes are stored as sorted-key JSON text
      assert result.scope_attributes == ~s({"alpha":"a","zeta":1})
      assert result.dropped_attributes_count == 2
      assert result.dropped_events_count == 1
      assert result.dropped_links_count == 4
      assert result.service_namespace == "payments"
      assert result.deployment_environment == "dev"
      assert result.attributes
      assert result.resource_attributes
      assert result.events
      assert %DateTime{} = result.timestamp
      assert %DateTime{} = result.created_at
    end

    test "parses camelCase fields" do
      json_data =
        Jason.encode!(%{
          "traceId" => "ABCDEF0123456789ABCDEF0123456789",
          "spanId" => "ABCDEF0123456789",
          "parentSpanId" => "0011223344556677",
          "startTimeUnixNano" => 1_705_315_800_000_000_000,
          "endTimeUnixNano" => 1_705_315_800_100_000_000,
          "serviceName" => "camel-service",
          "serviceVersion" => "2.0.0",
          "serviceInstance" => "camel-instance",
          "scopeName" => "camel-scope",
          "scopeVersion" => "1.0.0",
          "statusCode" => 0,
          "statusMessage" => "Success",
          "traceState" => "camel=1",
          "scopeAttributes" => %{"b" => 2, "a" => 1},
          "droppedAttributesCount" => 7,
          "droppedEventsCount" => 8,
          "droppedLinksCount" => 9,
          "serviceNamespace" => "camel-ns",
          "deploymentEnvironment" => "camel-env",
          "resourceAttributes" => %{"env" => "prod"}
        })

      message = %{data: json_data, metadata: %{}}
      result = OtelTraces.parse_message(message)

      # Uppercase hex ids are downcased to the canonical form
      assert result.trace_id == "abcdef0123456789abcdef0123456789"
      assert result.span_id == "abcdef0123456789"
      assert result.parent_span_id == "0011223344556677"
      assert result.start_time_unix_nano == 1_705_315_800_000_000_000
      assert result.end_time_unix_nano == 1_705_315_800_100_000_000
      assert result.service_name == "camel-service"
      assert result.service_version == "2.0.0"
      assert result.service_instance == "camel-instance"
      assert result.trace_state == "camel=1"
      assert result.scope_attributes == ~s({"a":1,"b":2})
      assert result.dropped_attributes_count == 7
      assert result.dropped_events_count == 8
      assert result.dropped_links_count == 9
      assert result.service_namespace == "camel-ns"
      assert result.deployment_environment == "camel-env"
    end

    test "handles bigint overflow in timestamps" do
      # Very large timestamp that could overflow int64
      max_int64 = 9_223_372_036_854_775_807
      overflow_value = max_int64 + 1000

      json_data =
        Jason.encode!(%{
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
      assert result.trace_state == nil
      assert result.scope_attributes == nil
      assert result.dropped_attributes_count == 0
      assert result.dropped_events_count == 0
      assert result.dropped_links_count == 0
      assert result.service_namespace == ""
      assert result.deployment_environment == ""
      assert %DateTime{} = result.timestamp
    end

    test "derives namespace and environment from resource attributes" do
      json_data =
        Jason.encode!(%{
          "trace_id" => "0123456789abcdef0123456789abcdef",
          "span_id" => "0123456789abcdef",
          "resource_attributes" => %{
            "service.namespace" => "checkout",
            "deployment.environment.name" => "staging",
            "deployment.environment" => "prod"
          }
        })

      result = OtelTraces.parse_message(%{data: json_data, metadata: %{}})

      assert result.service_namespace == "checkout"
      # deployment.environment.name wins over deployment.environment
      assert result.deployment_environment == "staging"
    end

    test "falls back to legacy deployment.environment resource attribute" do
      json_data =
        Jason.encode!(%{
          "trace_id" => "0123456789abcdef0123456789abcdef",
          "span_id" => "0123456789abcdef",
          "resource_attributes" => %{"deployment.environment" => "prod"}
        })

      result = OtelTraces.parse_message(%{data: json_data, metadata: %{}})

      assert result.service_namespace == ""
      assert result.deployment_environment == "prod"
    end

    test "normalizes empty trace_state and scope_attributes to nil" do
      json_data =
        Jason.encode!(%{
          "trace_id" => "0123456789abcdef0123456789abcdef",
          "span_id" => "0123456789abcdef",
          "trace_state" => "",
          "scope_attributes" => %{}
        })

      result = OtelTraces.parse_message(%{data: json_data, metadata: %{}})

      assert result.trace_state == nil
      assert result.scope_attributes == nil
    end

    test "encodes complex attributes as JSON" do
      json_data =
        Jason.encode!(%{
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
      json_data =
        Jason.encode!(%{
          "trace_id" => "trace-string",
          "span_id" => "span-string",
          "start_time_unix_nano" => "1705315800000000000",
          "end_time_unix_nano" => "1705315800100000000"
        })

      message = %{data: json_data, metadata: %{}}
      result = OtelTraces.parse_message(message)

      assert result.start_time_unix_nano == 1_705_315_800_000_000_000
      assert result.end_time_unix_nano == 1_705_315_800_100_000_000
    end

    test "normalizes empty and zero parent_span_id to nil" do
      for parent <- ["", "0000000000000000"] do
        json_data =
          Jason.encode!(%{
            "trace_id" => "0123456789abcdef0123456789abcdef",
            "span_id" => "0123456789abcdef",
            "parent_span_id" => parent
          })

        result = OtelTraces.parse_message(%{data: json_data, metadata: %{}})
        assert result.parent_span_id == nil
      end
    end

    test "normalizes non-canonical ids to nil" do
      json_data =
        Jason.encode!(%{
          "trace_id" => "trace-abc123",
          "span_id" => "span-def456",
          "parent_span_id" => "span-parent"
        })

      result = OtelTraces.parse_message(%{data: json_data, metadata: %{}})

      assert result.trace_id == nil
      assert result.span_id == nil
      assert result.parent_span_id == nil
    end
  end

  describe "parse_message/1 with protobuf" do
    @raw_trace_id <<102, 88, 99, 99, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 255>>
    @hex_trace_id "665863630102030405060708090a0bff"
    @root_span_id <<1, 2, 3, 4, 5, 6, 7, 8>>
    @hex_root_span_id "0102030405060708"
    @child_span_hex "090a0b0c0d0e0f10"

    defp build_request do
      root_span = %Span{
        trace_id: @raw_trace_id,
        span_id: @root_span_id,
        parent_span_id: <<>>,
        name: "GET /api/users",
        kind: :SPAN_KIND_SERVER,
        start_time_unix_nano: 1_705_315_800_123_456_789,
        end_time_unix_nano: 1_705_315_800_223_456_789,
        trace_state: "congo=t61rcWkgMzE",
        dropped_attributes_count: 3,
        dropped_events_count: 1,
        dropped_links_count: 2,
        attributes: [
          %KeyValue{key: "http.method", value: %AnyValue{value: {:string_value, "GET"}}}
        ],
        events: [
          %Span.Event{
            time_unix_nano: 1_705_315_800_150_000_000,
            name: "exception"
          }
        ],
        status: %Status{code: :STATUS_CODE_ERROR, message: "boom"}
      }

      # Child span whose bytes fields carry ASCII hex text (the Erlang
      # exporter encoding bug) - must normalize, not double-hex.
      child_span = %Span{
        trace_id: @hex_trace_id,
        span_id: @child_span_hex,
        parent_span_id: @root_span_id,
        name: "SELECT users",
        kind: :SPAN_KIND_INTERNAL,
        start_time_unix_nano: 1_705_315_800_130_000_000,
        end_time_unix_nano: 1_705_315_800_140_000_000
      }

      %ExportTraceServiceRequest{
        resource_spans: [
          %ResourceSpans{
            resource: %Resource{
              attributes: [
                %KeyValue{
                  key: "service.name",
                  value: %AnyValue{value: {:string_value, "proto-service"}}
                },
                %KeyValue{
                  key: "service.version",
                  value: %AnyValue{value: {:string_value, "0.1.0"}}
                },
                %KeyValue{
                  key: "service.namespace",
                  value: %AnyValue{value: {:string_value, "checkout"}}
                },
                %KeyValue{
                  key: "deployment.environment",
                  value: %AnyValue{value: {:string_value, "prod"}}
                }
              ]
            },
            scope_spans: [
              %ScopeSpans{
                scope: %InstrumentationScope{
                  name: "scope",
                  version: "1.2.3",
                  attributes: [
                    %KeyValue{
                      key: "zeta",
                      value: %AnyValue{value: {:int_value, 1}}
                    },
                    %KeyValue{
                      key: "alpha",
                      value: %AnyValue{value: {:string_value, "a"}}
                    }
                  ]
                },
                spans: [root_span, child_span]
              }
            ]
          }
        ]
      }
    end

    test "parses ExportTraceServiceRequest spans into rows" do
      payload = ExportTraceServiceRequest.encode(build_request())

      result = OtelTraces.parse_message(%{data: payload, metadata: %{}})

      assert is_list(result)
      assert length(result) == 2

      [root, child] = result

      # Root span: raw bytes hexed once, empty parent stored as nil
      assert root.trace_id == @hex_trace_id
      assert root.span_id == @hex_root_span_id
      assert root.parent_span_id == nil
      assert root.name == "GET /api/users"
      assert root.kind == 2
      assert root.start_time_unix_nano == 1_705_315_800_123_456_789
      assert root.end_time_unix_nano == 1_705_315_800_223_456_789
      assert root.service_name == "proto-service"
      assert root.service_version == "0.1.0"
      assert root.scope_name == "scope"
      assert root.scope_version == "1.2.3"
      assert %DateTime{} = root.created_at

      # Status ERROR maps to status_code = 2
      assert root.status_code == 2
      assert root.status_message == "boom"

      # Span fidelity fields
      assert root.trace_state == "congo=t61rcWkgMzE"
      assert root.dropped_attributes_count == 3
      assert root.dropped_events_count == 1
      assert root.dropped_links_count == 2

      # Scope attributes stored as sorted-key JSON
      assert root.scope_attributes == ~s({"alpha":"a","zeta":1})

      # Resource namespace/environment extraction
      assert root.service_namespace == "checkout"
      assert root.deployment_environment == "prod"

      # Timestamp derives from start_time_unix_nano at microsecond precision
      assert root.timestamp ==
               DateTime.from_unix!(div(1_705_315_800_123_456_789, 1000), :microsecond)

      assert root.timestamp.microsecond == {123_456, 6}

      # Attributes/events serialize to JSON text like the JSON path
      assert is_binary(root.attributes)
      assert root.attributes =~ "http.method"
      assert is_binary(root.events)
      assert root.events =~ "exception"

      # Child span: ascii-hex-in-bytes ids normalized (no double hex)
      assert child.trace_id == @hex_trace_id
      assert child.span_id == @child_span_hex
      assert child.parent_span_id == @hex_root_span_id
      assert child.kind == 1
      assert child.status_code == 0
      assert child.status_message == nil
      assert child.service_name == "proto-service"

      # Empty trace_state stored as NULL; proto3 zero counts stay 0
      assert child.trace_state == nil
      assert child.dropped_attributes_count == 0
      assert child.dropped_events_count == 0
      assert child.dropped_links_count == 0
      assert child.scope_attributes == ~s({"alpha":"a","zeta":1})
      assert child.service_namespace == "checkout"
      assert child.deployment_environment == "prod"
    end

    test "prefers deployment.environment.name over deployment.environment" do
      request = %ExportTraceServiceRequest{
        resource_spans: [
          %ResourceSpans{
            resource: %Resource{
              attributes: [
                %KeyValue{
                  key: "service.name",
                  value: %AnyValue{value: {:string_value, "env-service"}}
                },
                %KeyValue{
                  key: "deployment.environment.name",
                  value: %AnyValue{value: {:string_value, "staging"}}
                },
                %KeyValue{
                  key: "deployment.environment",
                  value: %AnyValue{value: {:string_value, "prod"}}
                }
              ]
            },
            scope_spans: [
              %ScopeSpans{
                scope: %InstrumentationScope{name: "scope"},
                spans: [
                  %Span{
                    trace_id: @raw_trace_id,
                    span_id: @root_span_id,
                    start_time_unix_nano: 1_705_315_800_123_456_789,
                    end_time_unix_nano: 1_705_315_800_223_456_789
                  }
                ]
              }
            ]
          }
        ]
      }

      [row] =
        OtelTraces.parse_message(%{
          data: ExportTraceServiceRequest.encode(request),
          metadata: %{}
        })

      assert row.deployment_environment == "staging"
      # No service.namespace resource attribute defaults to ''
      assert row.service_namespace == ""
      # Scope without attributes stores NULL, never "{}"
      assert row.scope_attributes == nil
    end

    test "returns nil for undecodable payloads" do
      assert OtelTraces.parse_message(%{data: <<255, 255, 255>>, metadata: %{}}) == nil
    end
  end

  describe "parse_message/1 ingest attribution" do
    @sr_headers [
      {"Sr-Ingest-Identity", "spiffe://serviceradar/gateway/gw-1"},
      {"Sr-Agent-Id", "agent-7"},
      {"Sr-Partition", "site-a"}
    ]

    defp minimal_trace_json do
      Jason.encode!(%{
        "timestamp" => "2024-01-15T10:30:00Z",
        "trace_id" => "0123456789abcdef0123456789abcdef",
        "span_id" => "0123456789abcdef",
        "name" => "op",
        "service_name" => "svc"
      })
    end

    test "maps Sr-* headers onto the ingest columns" do
      message = %{
        data: minimal_trace_json(),
        metadata: %{subject: "otel.traces.raw", headers: @sr_headers}
      }

      row = OtelTraces.parse_message(message)

      assert row.ingest_identity == "spiffe://serviceradar/gateway/gw-1"
      assert row.ingest_agent_id == "agent-7"
      assert row.ingest_partition == "site-a"
    end

    test "absent headers default the ingest columns to empty strings" do
      message = %{data: minimal_trace_json(), metadata: %{subject: "otel.traces.raw"}}

      row = OtelTraces.parse_message(message)

      assert row.ingest_identity == ""
      assert row.ingest_agent_id == ""
      assert row.ingest_partition == ""
    end

    test "attaches the triple to every protobuf span row" do
      request = %ExportTraceServiceRequest{
        resource_spans: [
          %ResourceSpans{
            resource: %Resource{
              attributes: [
                %KeyValue{
                  key: "service.name",
                  value: %AnyValue{value: {:string_value, "svc"}}
                }
              ]
            },
            scope_spans: [
              %ScopeSpans{
                scope: %InstrumentationScope{name: "scope", version: "1.0"},
                spans: [
                  %Span{
                    trace_id: :binary.copy(<<1>>, 16),
                    span_id: :binary.copy(<<2>>, 8),
                    name: "op-a",
                    start_time_unix_nano: 1_705_315_800_000_000_000,
                    end_time_unix_nano: 1_705_315_800_100_000_000
                  },
                  %Span{
                    trace_id: :binary.copy(<<1>>, 16),
                    span_id: :binary.copy(<<3>>, 8),
                    name: "op-b",
                    start_time_unix_nano: 1_705_315_800_000_000_000,
                    end_time_unix_nano: 1_705_315_800_100_000_000
                  }
                ]
              }
            ]
          }
        ]
      }

      message = %{
        data: ExportTraceServiceRequest.encode(request),
        metadata: %{subject: "otel.traces.raw", headers: @sr_headers}
      }

      rows = OtelTraces.parse_message(message)

      assert length(rows) == 2

      for row <- rows do
        assert row.ingest_identity == "spiffe://serviceradar/gateway/gw-1"
        assert row.ingest_agent_id == "agent-7"
        assert row.ingest_partition == "site-a"
      end
    end
  end
end
