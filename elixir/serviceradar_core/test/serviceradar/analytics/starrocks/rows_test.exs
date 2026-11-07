defmodule ServiceRadar.Analytics.StarRocks.RowsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.Schema
  alias ServiceRadar.Observability.MtrMetricsIngestor

  @moduletag :db_free

  test "flow records retain attribution with atom and JSON field names" do
    flow = %{
      id: "flow-example-01",
      agent_id: "agent-example-01",
      event_type: "attributed_flow",
      pid: 73,
      comm: "sshd",
      cmdline: "/usr/sbin/sshd -D",
      workload_identity: %{"namespace" => "example"}
    }

    for input <- [flow, flow |> Jason.encode!() |> Jason.decode!()] do
      assert [encoded] = Rows.encode(:flows, [input])
      assert encoded["agent_id"] == "agent-example-01"
      assert encoded["pid"] == 73
      assert encoded["comm"] == "sshd"
      assert encoded["cmdline"] == "/usr/sbin/sshd -D"
      assert Jason.decode!(encoded["workload_identity"]) == %{"namespace" => "example"}
    end
  end

  test "flow encodings retain filterable source and attribution metadata" do
    public_endpoint = %{
      "service_name" => "example-service",
      "gateway_name" => "example-gateway",
      "namespace" => "example-namespace",
      "exposure_class" => "Gateway",
      "route_name" => "example-route"
    }

    payload = %{
      "flow_source" => "netflow",
      "attribution" => %{
        "uid" => 1001,
        "container_id" => "example-container",
        "public_endpoint" => public_endpoint
      }
    }

    for row <- [
          %{id: "flow-example-02", ocsf_payload: payload},
          %{"id" => "flow-example-02", "ocsf_payload" => payload}
        ] do
      assert [encoded] = Rows.encode(:flows, [row])
      assert encoded["flow_source"] == "netflow"
      assert encoded["uid"] == 1001
      assert encoded["container_id"] == "example-container"
      assert Jason.decode!(encoded["public_endpoint"]) == public_endpoint
    end
  end

  test "flow payloads prefer redacted commands and retain legacy commands" do
    for {attribution, expected} <- [
          {%{"redacted_cmdline" => "sshd -D", "cmdline" => "sshd -legacy"}, "sshd -D"},
          {%{"cmdline" => "sshd -legacy"}, "sshd -legacy"}
        ] do
      assert [%{"cmdline" => ^expected}] =
               Rows.encode(:flows, [
                 %{id: "flow-example-01", ocsf_payload: %{"attribution" => attribution}}
               ])
    end
  end

  defp encode_event(overrides) do
    Map.merge(
      %{
        "id" => "evt-alpha-0001",
        "time" => ~U[2026-09-22 12:00:00Z],
        "class_uid" => 1004,
        "message" => "scan complete",
        "metadata" => %{},
        "unmapped" => %{},
        "device" => %{},
        "observables" => []
      },
      overrides
    )
  end

  test "free text past its old column width is stored whole, in events and logs" do
    message = String.duplicate("é", 40_000)
    source = String.duplicate("s", 300)
    body = String.duplicate("b", 70_000)

    assert [%{"message" => ^message, "source" => ^source}] =
             Rows.encode(:events, [encode_event(%{"message" => message, "source" => source})])

    assert [%{"body" => ^body}] =
             Rows.encode(:logs, [
               %{id: "log-alpha-0001", timestamp: ~U[2026-09-22 12:00:00Z], body: body}
             ])
  end

  test "an identifier past its protocol width is stored as NULL and counted, never cut" do
    handler = {__MODULE__, :scalar_invalid, System.unique_integer()}
    parent = self()

    :telemetry.attach_many(
      handler,
      [
        [:serviceradar, :starrocks, :events, :scalar_invalid],
        [:serviceradar, :starrocks, :logs, :scalar_invalid]
      ],
      fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    long_id = String.duplicate("a", 65)

    assert [%{"trace_id" => nil, "span_id" => "00f067aa0ba902b7"}] =
             Rows.encode(:events, [
               encode_event(%{"trace_id" => long_id, "span_id" => "00f067aa0ba902b7"})
             ])

    assert_received {[:serviceradar, :starrocks, :events, :scalar_invalid],
                     %{bytes: 65, max_bytes: 64}, %{field: "trace_id"}}

    assert [%{"source_ip" => nil, "trace_id" => "4bf92f3577b34da6a3ce929d0e0e4736"}] =
             Rows.encode(:logs, [
               %{
                 id: "log-alpha-0001",
                 timestamp: ~U[2026-09-22 12:00:00Z],
                 source_ip: long_id,
                 trace_id: "4bf92f3577b34da6a3ce929d0e0e4736"
               }
             ])

    assert_received {[:serviceradar, :starrocks, :logs, :scalar_invalid],
                     %{bytes: 65, max_bytes: 64}, %{field: "source_ip"}}

    refute_received {_event, _measurements, _metadata}
  end

  test "an event row carries every column of the shipped CREATE, CNPG's fields included" do
    row =
      encode_event(%{
        "actor" => %{"user" => %{"name" => "operator-example"}},
        "src_endpoint" => %{"ip" => "192.0.2.10"},
        "dst_endpoint" => %{"ip" => "198.51.100.20"},
        "status_code" => "E-EXAMPLE-01",
        "status_detail" => "synthetic status detail",
        "log_version" => "1.7.0",
        "raw_data" => "synthetic raw payload",
        "created_at" => ~U[2026-09-22 12:00:01Z]
      })

    assert [encoded] = Rows.encode(:events, [row])
    assert encoded |> Map.keys() |> Enum.sort() == ddl_columns("events")

    assert Jason.decode!(encoded["actor"]) == %{"user" => %{"name" => "operator-example"}}
    assert Jason.decode!(encoded["src_endpoint"]) == %{"ip" => "192.0.2.10"}
    assert Jason.decode!(encoded["dst_endpoint"]) == %{"ip" => "198.51.100.20"}
    assert encoded["status_code"] == "E-EXAMPLE-01"
    assert encoded["status_detail"] == "synthetic status detail"
    assert encoded["log_version"] == "1.7.0"
    assert encoded["raw_data"] == "synthetic raw payload"
    assert encoded["created_at"] == "2026-09-22T12:00:01Z"
  end

  test "a normal event row is unchanged" do
    row = encode_event(%{})

    assert [encoded] = Rows.encode(:events, [row])

    assert encoded["message"] == "scan complete"
    assert encoded["id"] == "evt-alpha-0001"
    assert encoded["metadata"] == "{}"
    assert encoded["observables"] == "[]"
  end

  describe "MTR traces and hops" do
    # A synthetic TCP trace: two hops, the second reporting reply counters,
    # an MPLS label stack and ECMP siblings, both with an AS so no GeoIP
    # lookup runs.
    defp mtr_payload do
      %{
        "results" => [
          %{
            "trace_uuid" => "5e1d2c3b-4a59-4687-9a0b-1c2d3e4f5a6b",
            "check_id" => "check-01",
            "check_name" => "edge path",
            "device_id" => "device-01",
            "target" => "host01.example.com",
            "available" => false,
            "timestamp" => 1_780_000_000,
            "trace" => %{
              "target" => "host01.example.com",
              "target_ip" => "198.51.100.7",
              "total_hops" => 2,
              "protocol" => "tcp",
              "ip_version" => 4,
              "packet_size" => 60,
              "tcp_handshake" => %{"ttl" => 2, "syn_sent" => 3, "synack_received" => 0},
              "hops" => [
                %{
                  "hop_number" => 1,
                  "addr" => "192.0.2.1",
                  "asn" => %{"asn" => 64_500, "org" => "Example Transit"},
                  "sent" => 3,
                  "received" => 3,
                  "loss_pct" => 0.0,
                  "avg_us" => 1_200
                },
                %{
                  "hop_number" => 2,
                  "addr" => "192.0.2.2",
                  "ecmp_addrs" => ["192.0.2.3"],
                  "mpls_labels" => [%{"label" => 16_001, "exp" => 0}],
                  "asn" => %{"asn" => 64_501},
                  "sent" => 3,
                  "received" => 1,
                  "loss_pct" => 66.7,
                  "reply_time_exceeded" => 1
                }
              ]
            }
          }
        ]
      }
    end

    defp mtr_rows do
      {:ok, built} = MtrMetricsIngestor.rows(mtr_payload(), %{agent_id: "agent-01"})
      built
    end

    test "a trace row carries exactly the warehouse columns" do
      [trace] = Rows.encode(:mtr_traces, mtr_rows().traces)

      assert trace |> Map.keys() |> Enum.sort() == ddl_columns("mtr_traces")
      assert trace["id"] == "5e1d2c3b-4a59-4687-9a0b-1c2d3e4f5a6b"
      assert trace["time"] == "2026-05-28T20:26:40Z"
      assert trace["agent_id"] == "agent-01"
      assert trace["target_ip"] == "198.51.100.7"
      assert trace["protocol"] == "tcp"
      assert trace["tcp_syn_sent"] == 3
      assert is_binary(trace["created_at"])
    end

    test "false, zero and absent trace values keep their meaning" do
      [trace] = Rows.encode(:mtr_traces, mtr_rows().traces)

      # `available: false` is a measured miss, not an unknown.
      assert trace["target_reached"] == false
      assert trace["tcp_synack_received"] == 0
      assert trace["gateway_id"] == nil
      assert trace["error"] == nil
      assert trace["tcp_handshake_rtt_avg_us"] == nil
      assert Map.has_key?(trace, "partition")
    end

    test "a hop row carries exactly the warehouse columns, documents and arrays included" do
      [first, second] = Rows.encode(:mtr_hops, mtr_rows().hops)

      assert first |> Map.keys() |> Enum.sort() == ddl_columns("mtr_hops")
      assert first["trace_id"] == "5e1d2c3b-4a59-4687-9a0b-1c2d3e4f5a6b"
      assert first["target_ip"] == "198.51.100.7"
      assert first["device_id"] == "device-01"
      assert first["asn"] == 64_500
      assert first["asn_org"] == "Example Transit"
      assert first["ecmp_addrs"] == []
      assert first["mpls_labels"] == nil
      assert first["avg_us"] == 1_200
      assert first["last_us"] == nil
      assert first["unreachable_code"] == nil
      # The trace reports reply counters, so a hop without one counted zero.
      assert first["reply_time_exceeded"] == 0

      assert second["ecmp_addrs"] == ["192.0.2.3"]
      assert second["mpls_labels"] == %{"labels" => [%{"label" => 16_001, "exp" => 0}]}
      assert second["reply_time_exceeded"] == 1
      assert second["loss_pct"] == 66.7
      assert second["time"] == first["time"]
    end

    test "raw UUID bytes and JSON text are normalized for the load" do
      id = "7b0e6f5c-1d2a-4b3c-8d4e-5f6a7b8c9d0e"

      [hop] =
        Rows.encode(:mtr_hops, [
          %{
            id: Ecto.UUID.dump!(id),
            trace_id: id,
            time: ~U[2026-01-15 10:00:00Z],
            hop_number: 1,
            mpls_labels: ~s({"labels":[{"label":16001}]}),
            ecmp_addrs: nil
          }
        ])

      assert hop["id"] == id
      assert hop["mpls_labels"] == %{"labels" => [%{"label" => 16_001}]}
      assert hop["ecmp_addrs"] == nil
      assert hop["hostname"] == nil
    end

    test "encoded rows survive the Stream Load JSON encoding" do
      built = mtr_rows()

      assert {:ok, _json} = Jason.encode(Rows.encode(:mtr_traces, built.traces))
      assert {:ok, _json} = Jason.encode(Rows.encode(:mtr_hops, built.hops))
    end
  end

  describe "OTel metrics" do
    defp span_sample(overrides \\ %{}) do
      Map.merge(
        %{
          timestamp: ~U[2026-01-15 10:00:00.123456Z],
          trace_id: "0123456789abcdef0123456789abcdef",
          span_id: "0123456789abcdef",
          service_name: "checkout",
          span_name: "GET /cart",
          span_kind: "SERVER",
          duration_ms: 150.5,
          duration_seconds: 0.1505,
          metric_type: "http",
          http_method: "GET",
          http_route: "/cart",
          http_status_code: "200",
          grpc_service: nil,
          grpc_method: nil,
          grpc_status_code: nil,
          is_slow: false,
          component: "api",
          level: "info",
          unit: "ms",
          ingest_identity: "",
          ingest_agent_id: "agent-01",
          ingest_partition: "default"
        },
        overrides
      )
    end

    defp metric_point(overrides \\ %{}) do
      Map.merge(
        %{
          timestamp: ~U[2026-01-15 10:00:00Z],
          metric_name: "http.server.request.count",
          metric_type: "sum",
          unit: "1",
          temporality: "cumulative",
          is_monotonic: true,
          service_name: "checkout",
          attributes: ~s({"http.route":"/cart"}),
          attributes_hash: "a1b2c3",
          value: 0.0,
          count: 0,
          sum: nil,
          bucket_counts: nil,
          explicit_bounds: nil,
          start_time_unix_nano: 1_768_471_200_000_000_000,
          scope_name: "example.meter",
          service_instance_id: "instance-01",
          ingest_identity: "",
          ingest_agent_id: "agent-01",
          ingest_partition: "default"
        },
        overrides
      )
    end

    test "a span sample carries exactly the warehouse columns" do
      [row] = Rows.encode(:otel_metrics, [span_sample()])

      assert row |> Map.keys() |> Enum.sort() == ddl_columns("otel_metrics")
      assert row["timestamp"] == "2026-01-15T10:00:00.123456Z"
      assert row["service_name"] == "checkout"
      assert row["http_route"] == "/cart"
      assert row["duration_ms"] == 150.5
      # A fast span is a measured `false`, not an unknown.
      assert row["is_slow"] == false
      assert row["grpc_service"] == nil
      assert is_binary(row["created_at"])
    end

    test "a metric point carries exactly the warehouse columns" do
      [row] = Rows.encode(:otel_metric_points, [metric_point()])

      assert row |> Map.keys() |> Enum.sort() == ddl_columns("otel_metric_points")
      assert row["metric_name"] == "http.server.request.count"
      assert row["is_monotonic"] == true
      # Zero is a measurement.
      assert row["value"] == 0.0
      assert row["count"] == 0
      assert row["sum"] == nil
      assert row["start_time_unix_nano"] == 1_768_471_200_000_000_000
      assert row["attributes"] == ~s({"http.route":"/cart"})
    end

    test "gauge and counter ingestion metrics keep their delta meaning" do
      [gauge, counter] =
        Rows.encode(:metrics, [
          %{
            timestamp: ~U[2026-09-22 12:00:00Z],
            gateway_id: "gateway-example-01",
            series_key: "lanes:mapper:state",
            agent_id: "agent-example-01",
            metric_name: "result_ingestion_pending_count",
            metric_type: "core.result_ingestion",
            value: 3.0,
            unit: "count",
            partition: "default",
            is_delta: false,
            tags: %{}
          },
          %{
            timestamp: ~U[2026-09-22 12:00:00Z],
            gateway_id: "gateway-example-01",
            series_key: "lanes:mapper:admitted",
            agent_id: "agent-example-01",
            metric_name: "result_ingestion_events_admitted",
            metric_type: "core.result_ingestion",
            value: 4.0,
            unit: "count",
            partition: "default",
            is_delta: true,
            tags: %{}
          }
        ])

      # `is_delta: false` is a gauge reading, not an unknown.
      assert gauge["value"] == 3.0
      assert gauge["is_delta"] == false
      assert counter["value"] == 4.0
      assert counter["is_delta"] == true
    end

    # The id stands for the rest of the CNPG primary key, so a redelivered row
    # upserts in place and two rows CNPG keeps apart stay apart.
    test "a span sample id follows span name, service and span id only" do
      [a] = Rows.encode(:otel_metrics, [span_sample()])
      [redelivered] = Rows.encode(:otel_metrics, [span_sample(%{duration_ms: 99.0})])
      [other_span] = Rows.encode(:otel_metrics, [span_sample(%{span_id: "fedcba9876543210"})])
      [other_service] = Rows.encode(:otel_metrics, [span_sample(%{service_name: "cart"})])

      assert a["id"] =~ ~r/^[0-9a-f]{64}$/
      assert redelivered["id"] == a["id"]
      assert other_span["id"] != a["id"]
      assert other_service["id"] != a["id"]
    end

    test "a metric point id follows metric name, service and attribute set only" do
      [a] = Rows.encode(:otel_metric_points, [metric_point()])
      [redelivered] = Rows.encode(:otel_metric_points, [metric_point(%{value: 3.0})])

      [other_attrs] =
        Rows.encode(:otel_metric_points, [metric_point(%{attributes_hash: "d4e5f6"})])

      [other_metric] = Rows.encode(:otel_metric_points, [metric_point(%{metric_name: "x"})])

      assert redelivered["id"] == a["id"]
      assert other_attrs["id"] != a["id"]
      assert other_metric["id"] != a["id"]
    end

    test "key parts cannot run together, and an absent part differs from an empty one" do
      parts = [
        %{span_name: "ab", service_name: "c"},
        %{span_name: "a", service_name: "bc"},
        %{span_name: "a", service_name: nil},
        %{span_name: "a", service_name: ""}
      ]

      ids =
        for overrides <- parts do
          [row] = Rows.encode(:otel_metrics, [span_sample(overrides)])
          row["id"]
        end

      assert ids |> Enum.uniq() |> length() == 4
    end

    test "encoded rows survive the Stream Load JSON encoding" do
      assert {:ok, _json} = Jason.encode(Rows.encode(:otel_metrics, [span_sample()]))
      assert {:ok, _json} = Jason.encode(Rows.encode(:otel_metric_points, [metric_point()]))
    end
  end

  describe "OTel spans" do
    defp span(overrides \\ %{}) do
      Map.merge(
        %{
          timestamp: ~U[2026-01-15 10:00:00.123456Z],
          trace_id: "0123456789abcdef0123456789abcdef",
          span_id: "0123456789abcdef",
          parent_span_id: nil,
          trace_state: nil,
          name: "GET /cart",
          kind: 2,
          start_time_unix_nano: 1_768_471_200_123_456_000,
          end_time_unix_nano: 1_768_471_200_373_456_000,
          service_name: "checkout",
          service_version: "1.0.0",
          service_instance: "instance-01",
          service_namespace: "",
          deployment_environment: "",
          scope_name: "example.tracer",
          scope_version: nil,
          scope_attributes: nil,
          status_code: 0,
          status_message: nil,
          attributes: ~s({"http.route":"/cart"}),
          resource_attributes: ~s({"service.name":"checkout"}),
          events: "[]",
          links: "[]",
          dropped_attributes_count: 0,
          dropped_events_count: 0,
          dropped_links_count: 0,
          ingest_identity: "",
          ingest_agent_id: "agent-01",
          ingest_partition: "default",
          created_at: ~U[2026-01-15 10:00:05Z]
        },
        overrides
      )
    end

    test "a span carries exactly the warehouse columns" do
      [row] = Rows.encode(:otel_traces, [span()])

      assert row |> Map.keys() |> Enum.sort() == ddl_columns("otel_traces")
      assert row["timestamp"] == "2026-01-15T10:00:00.123456Z"
      assert row["created_at"] == "2026-01-15T10:00:05Z"
      assert row["trace_id"] == "0123456789abcdef0123456789abcdef"
      # A root span's missing parent stays NULL; OK status 0 stays 0.
      assert row["parent_span_id"] == nil
      assert row["status_code"] == 0
      assert row["kind"] == 2
      assert row["start_time_unix_nano"] == 1_768_471_200_123_456_000
      assert row["attributes"] == ~s({"http.route":"/cart"})
    end

    test "encoded spans survive the Stream Load JSON encoding" do
      assert {:ok, _json} = Jason.encode(Rows.encode(:otel_traces, [span()]))
    end

    test "free text past its old column width is stored whole; values over 1 MiB are dropped as NULL" do
      handler = {__MODULE__, :otel_document_dropped, System.unique_integer()}
      parent = self()

      :telemetry.attach(
        handler,
        [:serviceradar, :starrocks, :otel_traces, :document_dropped],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      name = String.duplicate("é", 35_000)
      status_message = String.duplicate("m", 70_000)
      service_name = String.duplicate("s", 2_000)
      ingest_partition = String.duplicate("p", 300)
      oversized_attributes = String.duplicate("é", 600_000)

      assert [
               %{
                 "name" => ^name,
                 "status_message" => ^status_message,
                 "service_name" => ^service_name,
                 "ingest_partition" => ^ingest_partition,
                 "attributes" => nil
               } = row
             ] =
               Rows.encode(:otel_traces, [
                 span(%{
                   name: name,
                   status_message: status_message,
                   service_name: service_name,
                   ingest_partition: ingest_partition,
                   attributes: oversized_attributes
                 })
               ])

      assert_received {[:serviceradar, :starrocks, :otel_traces, :document_dropped],
                       %{bytes: 1_200_000}, %{field: "attributes", reason: :too_large}}

      assert {:ok, _json} = Jason.encode(row)
    end

    test "span identifiers past their protocol width are stored as NULL and counted, never cut" do
      handler = {__MODULE__, :otel_scalar_invalid, System.unique_integer()}
      parent = self()

      :telemetry.attach(
        handler,
        [:serviceradar, :starrocks, :otel_traces, :scalar_invalid],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      kept = span(%{span_id: "1111111111111111", parent_span_id: String.duplicate("c", 17)})

      # trace_id and span_id are the NOT NULL warehouse key: a span whose key
      # would be NULL is left out, and the rest of the batch still loads.
      assert [%{"span_id" => "1111111111111111", "parent_span_id" => nil}] =
               Rows.encode(:otel_traces, [
                 span(%{trace_id: String.duplicate("a", 33)}),
                 kept,
                 span(%{span_id: String.duplicate("b", 17)})
               ])

      assert_received {[:serviceradar, :starrocks, :otel_traces, :scalar_invalid],
                       %{bytes: 33, max_bytes: 32}, %{field: "trace_id"}}

      assert_received {[:serviceradar, :starrocks, :otel_traces, :scalar_invalid],
                       %{bytes: 17, max_bytes: 16}, %{field: "span_id"}}

      assert_received {[:serviceradar, :starrocks, :otel_traces, :scalar_invalid],
                       %{bytes: 17, max_bytes: 16}, %{field: "parent_span_id"}}
    end
  end

  describe "BMP routing events" do
    defp bmp_row(overrides \\ %{}) do
      id = "7b0e6f5c-1d2a-4b3c-8d4e-5f6a7b8c9d0e"

      Map.merge(
        %{
          id: Ecto.UUID.dump!(id),
          time: ~U[2026-01-15 10:00:00Z],
          event_type: "route_update",
          severity_id: 4,
          router_id: "router-a",
          router_ip: "192.0.2.1",
          peer_ip: "198.51.100.20",
          peer_asn: 64_512,
          local_asn: 64_600,
          prefix: "198.51.100.0/24",
          message: "synthetic BMP routing signal",
          metadata: %{"signal_type" => "bmp", "event_identity" => id},
          raw_data: ~s({"synthetic": true}),
          created_at: ~U[2026-01-15 10:00:00Z]
        },
        overrides
      )
    end

    test "a BMP row carries exactly the warehouse columns" do
      [row] = Rows.encode(:bmp_routing_events, [bmp_row()])

      assert row |> Map.keys() |> Enum.sort() == ddl_columns("bmp_routing_events")
      assert row["id"] == "7b0e6f5c-1d2a-4b3c-8d4e-5f6a7b8c9d0e"
      assert row["time"] == "2026-01-15T10:00:00Z"
      assert row["event_type"] == "route_update"
      assert row["severity_id"] == 4
      assert row["router_ip"] == "192.0.2.1"
      assert row["peer_asn"] == 64_512
      assert row["local_asn"] == 64_600

      assert row["metadata"] == %{
               "signal_type" => "bmp",
               "event_identity" => "7b0e6f5c-1d2a-4b3c-8d4e-5f6a7b8c9d0e"
             }

      assert row["raw_data"] == ~s({"synthetic": true})
      assert is_binary(row["created_at"])
    end

    test "absent text and JSON fields keep their meaning" do
      [row] =
        Rows.encode(:bmp_routing_events, [
          bmp_row(%{router_ip: nil, peer_ip: nil, prefix: nil, message: nil, raw_data: nil})
        ])

      assert row["router_ip"] == nil
      assert row["peer_ip"] == nil
      assert row["prefix"] == nil
      assert row["message"] == nil
      assert row["raw_data"] == nil
      assert Map.has_key?(row, "metadata")
    end

    test "free text past its old column width is stored whole; values over 1 MiB are dropped as NULL" do
      handler = {__MODULE__, :bmp_document_dropped, System.unique_integer()}
      parent = self()

      :telemetry.attach(
        handler,
        [:serviceradar, :starrocks, :bmp_routing_events, :document_dropped],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      event_type = String.duplicate("t", 300)
      message = String.duplicate("é", 33_000)
      raw_data = String.duplicate("x", 70_000)

      assert [
               %{
                 "event_type" => ^event_type,
                 "message" => ^message,
                 "raw_data" => ^raw_data
               }
             ] =
               Rows.encode(:bmp_routing_events, [
                 bmp_row(%{event_type: event_type, message: message, raw_data: raw_data})
               ])

      assert [%{"raw_data" => nil}] =
               Rows.encode(:bmp_routing_events, [
                 bmp_row(%{raw_data: String.duplicate("x", 1_048_577)})
               ])

      assert_received {[:serviceradar, :starrocks, :bmp_routing_events, :document_dropped],
                       %{bytes: 1_048_577}, %{field: "raw_data", reason: :too_large}}
    end

    test "BMP identifiers past their protocol width are stored as NULL and counted, never cut" do
      handler = {__MODULE__, :bmp_scalar_invalid, System.unique_integer()}
      parent = self()

      :telemetry.attach(
        handler,
        [:serviceradar, :starrocks, :bmp_routing_events, :scalar_invalid],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert [
               %{
                 "router_id" => nil,
                 "router_ip" => nil,
                 "peer_ip" => nil,
                 "prefix" => nil
               }
             ] =
               Rows.encode(:bmp_routing_events, [
                 bmp_row(%{
                   router_id: String.duplicate("r", 257),
                   router_ip: String.duplicate("1", 65),
                   peer_ip: String.duplicate("2", 65),
                   prefix: String.duplicate("3", 129)
                 })
               ])

      assert_received {[:serviceradar, :starrocks, :bmp_routing_events, :scalar_invalid],
                       %{bytes: 257, max_bytes: 256}, %{field: "router_id"}}

      assert_received {[:serviceradar, :starrocks, :bmp_routing_events, :scalar_invalid],
                       %{bytes: 65, max_bytes: 64}, %{field: "router_ip"}}

      assert_received {[:serviceradar, :starrocks, :bmp_routing_events, :scalar_invalid],
                       %{bytes: 65, max_bytes: 64}, %{field: "peer_ip"}}

      assert_received {[:serviceradar, :starrocks, :bmp_routing_events, :scalar_invalid],
                       %{bytes: 129, max_bytes: 128}, %{field: "prefix"}}
    end

    test "encoded rows survive the Stream Load JSON encoding" do
      assert {:ok, _json} = Jason.encode(Rows.encode(:bmp_routing_events, [bmp_row()]))
    end
  end

  describe "flow process attribution observations" do
    defp observation_row(overrides \\ %{}) do
      Map.merge(
        %{
          observed_at: ~U[2026-01-15 10:00:00Z],
          partition: "default",
          proto: 6,
          local_ip: "192.0.2.10",
          local_port: 8443,
          remote_ip: "198.51.100.20",
          remote_port: 51_234,
          agent_id: "agent-example-01",
          attribution_key: "attr-key-01",
          pid: 1234,
          comm: "nginx",
          cmdline: "nginx -g daemon off;",
          uid: 101,
          container_id: "container-example-01",
          workload_identity: %{"namespace" => "example"},
          executable_ownership: %{"binary_package" => "nginx"}
        },
        overrides
      )
    end

    test "an observation row carries exactly the warehouse columns" do
      [row] = Rows.encode(:flow_attribution_observations, [observation_row()])

      assert row |> Map.keys() |> Enum.sort() ==
               ddl_columns("flow_process_attribution_observations")
    end

    test "free text past its old column width is stored whole; values over 1 MiB are dropped as NULL" do
      handler = {__MODULE__, :obs_document_dropped, System.unique_integer()}
      parent = self()

      :telemetry.attach(
        handler,
        [:serviceradar, :starrocks, :flow_attribution_observations, :document_dropped],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      comm = String.duplicate("c", 300)
      cmdline = String.duplicate("é", 35_000)
      ownership = Jason.encode!(%{"binary_package" => String.duplicate("p", 70_000)})

      assert [
               %{
                 "comm" => ^comm,
                 "cmdline" => ^cmdline,
                 "executable_ownership" => ^ownership,
                 "workload_identity" => nil
               }
             ] =
               Rows.encode(:flow_attribution_observations, [
                 observation_row(%{
                   comm: comm,
                   cmdline: cmdline,
                   executable_ownership: ownership,
                   workload_identity: String.duplicate("w", 1_048_577)
                 })
               ])

      assert_received {
        [:serviceradar, :starrocks, :flow_attribution_observations, :document_dropped],
        %{bytes: 1_048_577},
        %{field: "workload_identity", reason: :too_large}
      }
    end

    test "observation identifiers past their protocol width are stored as NULL and counted, never cut" do
      handler = {__MODULE__, :obs_scalar_invalid, System.unique_integer()}
      parent = self()

      :telemetry.attach(
        handler,
        [:serviceradar, :starrocks, :flow_attribution_observations, :scalar_invalid],
        fn event, measurements, metadata, _ -> send(parent, {event, measurements, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert [%{"agent_id" => nil, "container_id" => nil}] =
               Rows.encode(:flow_attribution_observations, [
                 observation_row(%{
                   agent_id: String.duplicate("a", 257),
                   container_id: String.duplicate("c", 257)
                 })
               ])

      assert_received {
        [:serviceradar, :starrocks, :flow_attribution_observations, :scalar_invalid],
        %{bytes: 257, max_bytes: 256},
        %{field: "agent_id"}
      }

      assert_received {
        [:serviceradar, :starrocks, :flow_attribution_observations, :scalar_invalid],
        %{bytes: 257, max_bytes: 256},
        %{field: "container_id"}
      }
    end
  end

  # The column list of the shipped CREATE, so an encoder that misses or
  # misspells a column fails here rather than loading NULL into it.
  defp ddl_columns(table) do
    create =
      Schema.migrations()
      |> Enum.flat_map(& &1.statements)
      |> Enum.find(&(&1 =~ ~r/^CREATE TABLE IF NOT EXISTS serviceradar\.#{table} \(/))

    ~r/^\s+`?(\w+)`? [A-Z]/m
    |> Regex.scan(create)
    |> Enum.map(&List.last/1)
    |> Enum.sort()
  end
end
