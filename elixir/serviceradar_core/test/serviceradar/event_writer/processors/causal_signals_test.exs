defmodule ServiceRadar.EventWriter.Processors.CausalSignalsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.CausalSignals
  alias ServiceRadar.Observability.CapacityForecasting.VerdictEmitter
  alias ServiceRadar.Observability.SeasonalDisposition.VerdictEmitter, as: SeasonalVerdictEmitter

  defmodule BulkInsertStub do
    @moduledoc false
    def insert_all(table, rows, opts) do
      send(Process.get(:causal_signals_test_pid), {:bulk_insert, table, rows, opts})
      {length(rows), []}
    end
  end

  defmodule AlertQueueStub do
    @moduledoc false
    def enqueue_events(events) do
      send(Process.get(:causal_signals_test_pid), {:alert_evaluation_events, events})
      :ok
    end
  end

  defmodule DedupingBulkInsertStub do
    @moduledoc false
    def insert_all(table, rows, opts) do
      seen = Process.get(:causal_signals_seen_rows, MapSet.new())

      {new_rows, next_seen} =
        Enum.reduce(rows, {[], seen}, fn row, {new_rows, seen_rows} ->
          key = {table, Map.fetch!(row, :time), Map.fetch!(row, :id)}

          if MapSet.member?(seen_rows, key) do
            {new_rows, seen_rows}
          else
            {[row | new_rows], MapSet.put(seen_rows, key)}
          end
        end)

      new_rows = Enum.reverse(new_rows)
      Process.put(:causal_signals_seen_rows, next_seen)

      send(
        Process.get(:causal_signals_test_pid),
        {:deduping_bulk_insert, table, rows, new_rows, opts}
      )

      {length(new_rows), []}
    end
  end

  describe "table_name/0" do
    test "returns ocsf_events" do
      assert CausalSignals.table_name() == "ocsf_events"
    end
  end

  describe "parse_message/1" do
    test "normalizes BMP payload into causal envelope row" do
      payload = %{
        "event_id" => "bmp-123",
        "timestamp" => "2026-02-16T12:00:00Z",
        "severity" => "high",
        "peer_ip" => "192.0.2.10",
        "peer_asn" => "64513",
        "router_id" => "router-a",
        "router_ip" => "10.0.0.1",
        "device_id" => "mac-aabbccddeeff",
        "message" => "BGP peer down"
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "bmp.events.peer", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      assert row
      assert is_binary(row.id)
      assert byte_size(row.id) == 16
      assert row.class_uid == 1008
      assert row.type_uid == 100_811
      assert row.severity_id == 4
      assert row.metadata["signal_type"] == "bmp"
      assert row.metadata["event_type"] == "peer"
      assert row.metadata["schema_version"] == "1.0"
      assert row.metadata["primary_domain"] == "routing"
      assert row.metadata["source_identity"]["router_id"] == "router-a"
      assert row.metadata["routing_correlation"]["peer_asn"] == 64_513
      assert row.metadata["routing_correlation"]["router_ip"] == "10.0.0.1"
      assert "192.0.2.10" in row.metadata["routing_correlation"]["topology_keys"]
      assert row.device["uid"] == "mac-aabbccddeeff"
      assert row.src_endpoint["ip"] == "192.0.2.10"
      assert row.src_endpoint["asn"] == 64_513
    end

    test "normalizes SIEM payload and clamps numeric severity" do
      payload = %{
        "id" => "siem-evt-1",
        "time" => "2026-02-16T12:10:00Z",
        "severity_id" => 9,
        "message" => "intrusion detected"
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "siem.events.alert", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      assert row
      assert row.type_uid == 100_812
      assert row.severity_id == 6
      assert row.severity == "Fatal"
      assert row.metadata["signal_type"] == "siem"
      assert row.metadata["primary_domain"] == "security"
    end

    test "returns nil on invalid JSON" do
      row =
        CausalSignals.parse_message(%{data: "not-json", metadata: %{subject: "bmp.events.peer"}})

      assert row == nil
    end

    test "uses deterministic ID for identical payloads" do
      payload = %{
        "event_id" => "stable-id",
        "timestamp" => "2026-02-16T12:20:00Z",
        "severity" => "medium"
      }

      metadata = %{subject: "bmp.events.peer", received_at: DateTime.utc_now()}
      message = %{data: Jason.encode!(payload), metadata: metadata}

      row1 = CausalSignals.parse_message(message)
      row2 = CausalSignals.parse_message(message)

      assert row1.id == row2.id
    end

    test "normalizes inventory package-change signals as a first-class causal domain" do
      payload = %{
        "event_id" => "inventory:agent-a:scan-a:added:coord-hash",
        "signal_type" => "inventory",
        "event_type" => "added",
        "timestamp" => "2026-06-02T12:00:00Z",
        "severity" => "low",
        "signal_domain" => "inventory",
        "message" => "endpoint package added",
        "device_uid" => "sr:test-device",
        "package" => %{
          "purl_canonical" => "pkg:deb/debian/nginx@1.24.0?arch=amd64",
          "cpes" => ["cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*"]
        }
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "signals.causal.inventory.added", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)
      replayed_row = CausalSignals.parse_message(message)

      assert row
      assert row.id == replayed_row.id
      assert row.type_uid == 100_813
      assert row.metadata["signal_type"] == "inventory"
      assert row.metadata["primary_domain"] == "inventory"
      assert row.metadata["signal_domains"] == ["inventory"]
      assert row.metadata["event_type"] == "added"
      assert row.metadata["source"]["subject"] == "signals.causal.inventory.added"

      assert row.metadata["explainability"]["source_signal_refs"] == [
               "inventory:agent-a:scan-a:added:coord-hash"
             ]

      assert row.device == %{}
    end

    test "emits inventory vulnerability matches as OCSF vulnerability findings" do
      payload = %{
        "event_id" => "inventory-vuln:agent-a:scan-a:CVE-2026-1234:coord-hash",
        "signal_type" => "inventory",
        "event_type" => "vulnerability_match",
        "timestamp" => "2026-06-02T12:30:00Z",
        "signal_domain" => "inventory",
        "device_uid" => "sr:test-device",
        "cvss_score" => 9.8,
        "cve" => "CVE-2026-1234",
        "package" => %{
          "package_manager" => "dpkg",
          "name" => "nginx",
          "version" => "1.24.0-2ubuntu7",
          "purl_canonical" => "pkg:deb/ubuntu/nginx@1.24.0-2ubuntu7?arch=amd64",
          "cpes" => ["cpe:2.3:a:nginx:nginx:1.24.0:*:*:*:*:*:*:*"]
        }
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{
          subject: "signals.causal.inventory.vulnerability_match",
          received_at: DateTime.utc_now()
        }
      }

      row = CausalSignals.parse_message(message)

      assert row
      assert row.class_uid == 2002
      assert row.category_uid == 2
      assert row.type_uid == 200_201
      assert row.activity_id == 1
      assert row.severity_id == 5
      assert row.severity == "Critical"
      assert row.device == %{"uid" => "sr:test-device"}
      assert row.metadata["signal_type"] == "inventory"
      assert row.metadata["primary_domain"] == "security"
      assert row.metadata["service_radar"]["source_type"] == "endpoint_inventory"
      assert row.metadata["service_radar"]["addon_id"] == "endpoint-inventory"
      assert row.metadata["service_radar"]["device_uid"] == "sr:test-device"
      assert row.metadata["service_radar"]["ocsf_class"] == "vulnerability_finding"
      assert "security" in row.metadata["signal_domains"]
      assert "inventory" in row.metadata["signal_domains"]
      assert %{"type" => "cve", "id" => "CVE-2026-1234"} in row.metadata["grouped_contexts"]

      assert %{
               "type" => "package",
               "id" => "pkg:deb/ubuntu/nginx@1.24.0-2ubuntu7?arch=amd64"
             } in row.metadata["grouped_contexts"]

      assert row.metadata["vulnerability_finding"]["cvss_score"] == 9.8
      assert row.metadata["vulnerability_finding"]["cve"] == "CVE-2026-1234"
      assert row.unmapped["package"]["name"] == "nginx"
    end

    test "suppresses inventory vulnerability findings without canonical device UID" do
      payload = %{
        "event_id" => "inventory-vuln:agent-a:scan-a:CVE-2026-1234:coord-hash",
        "signal_type" => "inventory",
        "event_type" => "vulnerability_match",
        "timestamp" => "2026-06-02T12:30:00Z",
        "cvss_score" => 9.8,
        "cve" => "CVE-2026-1234",
        "package" => %{"name" => "nginx", "version" => "1.24.0-2ubuntu7"}
      }

      row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.causal.inventory.vulnerability_match",
            received_at: DateTime.utc_now()
          }
        })

      assert row == nil
    end

    test "includes grouped contexts and explainability metadata" do
      payload = %{
        "event_id" => "ctx-1",
        "timestamp" => "2026-02-16T12:20:00Z",
        "severity" => "high",
        "signal_domains" => ["routing", "security"],
        "security_zones" => ["zone-a", "zone-b"],
        "bgp_prefix_groups" => ["as64512-core"]
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "bmp.events.peer", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      assert row
      assert row.metadata["primary_domain"] == "security"
      assert row.metadata["signal_domains"] == ["routing", "security"]
      assert length(row.metadata["grouped_contexts"]) == 3
      assert row.metadata["explainability"]["primary_domain"] == "security"
      assert row.metadata["explainability"]["source_signal_refs"] == ["ctx-1"]
      assert row.metadata["guardrails"]["contexts_truncated"] == false
    end

    test "enforces grouped context guardrail truncation" do
      zones = Enum.map(1..40, &"zone-#{&1}")

      payload = %{
        "event_id" => "ctx-truncate",
        "timestamp" => "2026-02-16T12:20:00Z",
        "severity" => "medium",
        "signal_domain" => "security",
        "security_zones" => zones
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "siem.events.alert", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      assert row
      assert length(row.metadata["grouped_contexts"]) == 32
      assert row.metadata["guardrails"]["contexts_truncated"] == true
      assert row.metadata["guardrails"]["input_context_count"] == 40
      assert row.metadata["guardrails"]["applied_context_count"] == 32
    end

    test "normalizes routing correlation keys for topology joins" do
      payload = %{
        "event_id" => "join-1",
        "timestamp" => "2026-02-16T12:20:00Z",
        "severity" => "critical",
        "deviceId" => "router-edge-01",
        "peer_ip" => "198.51.100.77",
        "peerAsn" => "64522",
        "localAsn" => 64_512,
        "prefix" => "203.0.113.0/24",
        "vrf" => "default"
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "bmp.events.update", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)

      assert row
      assert row.metadata["source_identity"]["device_uid"] == "router-edge-01"
      assert row.metadata["routing_correlation"]["local_asn"] == 64_512
      assert row.metadata["routing_correlation"]["peer_asn"] == 64_522
      assert row.metadata["routing_correlation"]["vrf"] == "default"
      assert row.metadata["routing_correlation"]["prefix"] == "203.0.113.0/24"
      assert "router-edge-01" in row.metadata["routing_correlation"]["topology_keys"]
      assert "198.51.100.77" in row.metadata["explainability"]["routing_topology_keys"]
    end

    test "uses explicit event_type when provided by collector payload" do
      payload = %{
        "event_id" => "evt-typed-1",
        "event_type" => "route_withdraw",
        "timestamp" => "2026-02-16T12:21:00Z",
        "severity" => "low"
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{subject: "bmp.events.peer_down", received_at: DateTime.utc_now()}
      }

      row = CausalSignals.parse_message(message)
      assert row
      assert row.metadata["event_type"] == "route_withdraw"
    end

    test "normalizes arancini update payload into bmp causal envelope" do
      payload = load_event_writer_fixture!("arancini_update_route_update.json")
      assert_arancini_contract_keys!(payload)

      message = %{
        data: Jason.encode!(payload),
        metadata: %{
          subject: "arancini.updates.v4_10_0_0_1.64513.1_1",
          received_at: DateTime.utc_now()
        }
      }

      row = CausalSignals.parse_message(message)

      assert row
      assert row.type_uid == 100_811
      assert row.metadata["signal_type"] == "bmp"
      assert row.metadata["event_type"] == "route_update"
      assert row.metadata["source"]["system"] == "arancini"
      assert row.metadata["routing_correlation"]["router_ip"] == "10.0.0.1"
      assert row.metadata["routing_correlation"]["peer_ip"] == "192.0.2.10"
      assert row.metadata["routing_correlation"]["prefix"] == "203.0.113.0/24"
      assert row.src_endpoint["ip"] == "192.0.2.10"
      assert row.device["uid"] == "10.0.0.1"
    end

    test "normalizes arancini withdraw payload to route_withdraw event type" do
      payload = load_event_writer_fixture!("arancini_update_route_withdraw.json")
      assert_arancini_contract_keys!(payload)

      message = %{
        data: Jason.encode!(payload),
        metadata: %{
          subject: "arancini.updates.v4_10_0_0_2.64514.1_1",
          received_at: DateTime.utc_now()
        }
      }

      row = CausalSignals.parse_message(message)

      assert row
      assert row.metadata["signal_type"] == "bmp"
      assert row.metadata["event_type"] == "route_withdraw"
      assert row.metadata["routing_correlation"]["prefix"] == "203.0.114.0/24"
      assert row.src_endpoint["ip"] == "192.0.2.11"
      assert row.src_endpoint["asn"] == 64_514
    end

    test "rejects arancini payloads missing required contract fields" do
      payload =
        "arancini_update_route_update.json"
        |> load_event_writer_fixture!()
        |> Map.delete("peer_asn")

      message = %{
        data: Jason.encode!(payload),
        metadata: %{
          subject: "arancini.updates.v4_10_0_0_1.64513.1_1",
          received_at: DateTime.utc_now()
        }
      }

      assert CausalSignals.parse_message(message) == nil
    end

    test "decodes arancini Cap'n Proto payloads on arancini subjects" do
      payload = %{
        "time_received_ns" => "2026-02-16T12:00:01Z",
        "time_bmp_header_ns" => "2026-02-16T12:00:00Z",
        "router_addr" => "10.0.0.1",
        "peer_addr" => "192.0.2.10",
        "peer_asn" => 64_513,
        "prefix_addr" => "203.0.113.0",
        "prefix_len" => 24,
        "announced" => true,
        "synthetic" => false
      }

      {:ok, capnp_payload} =
        ServiceRadarSRQL.Native.encode_arancini_update_capnp(Jason.encode!(payload))

      message = %{
        data: capnp_payload,
        metadata: %{
          subject: "arancini.updates.v4_10_0_0_1.64513.1_1",
          received_at: DateTime.utc_now()
        }
      }

      row = CausalSignals.parse_message(message)

      assert row
      assert row.type_uid == 100_811
      assert row.metadata["signal_type"] == "bmp"
      assert row.metadata["event_type"] == "route_update"
      assert row.metadata["routing_correlation"]["router_ip"] == "10.0.0.1"
      assert row.metadata["routing_correlation"]["peer_ip"] == "192.0.2.10"
      assert row.metadata["routing_correlation"]["prefix"] == "203.0.113.0/24"
      assert row.src_endpoint["ip"] == "192.0.2.10"
      assert row.src_endpoint["asn"] == 64_513
    end
  end

  describe "replay determinism via Broadway causal routing" do
    test "BMP burst replay yields identical normalized causal overlay inputs" do
      burst = bmp_burst_messages()

      first_projection =
        burst
        |> route_broadway_messages()
        |> parse_causal_rows()
        |> causal_overlay_projection()

      # Replay same logical events in different order to emulate JetStream redelivery.
      replay_projection =
        burst
        |> Enum.reverse()
        |> route_broadway_messages()
        |> parse_causal_rows()
        |> causal_overlay_projection()

      assert first_projection == replay_projection
      assert length(first_projection) == 4
    end

    test "grouped context replay yields deterministic precedence and explainability" do
      now = "2026-02-16T13:10:00Z"

      burst =
        Enum.map(
          [
            %{
              "event_id" => "ctx-a",
              "timestamp" => now,
              "severity" => "high",
              "signal_domains" => ["routing", "security"],
              "security_zones" => ["zone-a"],
              "bgp_prefix_groups" => ["as64512-core"]
            },
            %{
              "event_id" => "ctx-b",
              "timestamp" => now,
              "severity" => "medium",
              "signal_domain" => "routing",
              "bgp_prefix_group" => "as64512-edge"
            }
          ],
          fn payload ->
            %{
              data: Jason.encode!(payload),
              metadata: %{subject: "signals.causal.overlay", received_at: DateTime.utc_now()},
              ack_data: %{}
            }
          end
        )

      first =
        burst
        |> route_broadway_messages()
        |> parse_causal_rows()
        |> grouped_projection()

      replay =
        burst
        |> Enum.reverse()
        |> route_broadway_messages()
        |> parse_causal_rows()
        |> grouped_projection()

      assert first == replay

      assert Enum.any?(first, fn {_id, primary_domain, _contexts} ->
               primary_domain == "security"
             end)
    end

    test "arancini subject routes to arancini_causal batcher" do
      event = %{
        data: Jason.encode!(%{"announced" => true}),
        metadata: %{
          subject: "arancini.updates.v4_10_0_0_1.64513.1_1",
          received_at: DateTime.utc_now()
        },
        ack_data: %{}
      }

      message = Pipeline.transform(event, [])
      routed = Pipeline.handle_message(:default, message, %{})
      assert routed.batcher == :arancini_causal
    end

    test "causal prediction subjects route to the declared causal_predictions batcher" do
      event = %{
        data: Jason.encode!(%{"signal_type" => "causal", "event_type" => "anomaly"}),
        metadata: %{
          subject: "signals.causal.predictions.sysmon:memory:host-a",
          received_at: DateTime.utc_now()
        },
        ack_data: %{}
      }

      message = Pipeline.transform(event, [])
      routed = Pipeline.handle_message(:default, message, %{})
      assert routed.batcher == :causal_predictions
    end
  end

  describe "alert evaluation rows" do
    test "selects anomaly causal prediction findings for stateful alert evaluation" do
      payload = %{
        "event_id" => "anomaly-alert-1",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "device_uid" => "sr:anomaly-device",
        "anomaly" => %{
          "series_key" => "sysmon:memory:sr:anomaly-device",
          "metric_class" => "sysmon.memory",
          "state" => "anomalous"
        }
      }

      row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.causal.predictions.sysmon:memory:sr:anomaly-device",
            received_at: DateTime.utc_now()
          }
        })

      assert row.class_uid == 2004
      assert row.metadata["signal_type"] == "causal"
      assert row.metadata["event_type"] == "anomaly"

      assert [alert_row] = CausalSignals.alert_evaluation_rows([row])
      assert alert_row.id == row.metadata["event_identity"]
      assert alert_row.device == %{"uid" => "sr:anomaly-device"}
    end

    test "process_batch bulk-inserts causal prediction findings without per-row Ash lookup" do
      previous_bulk_insert = Application.get_env(:serviceradar_core, :event_writer_bulk_insert)

      previous_alert_queue =
        Application.get_env(:serviceradar_core, :stateful_alert_evaluation_queue)

      Process.put(:causal_signals_test_pid, self())

      Application.put_env(:serviceradar_core, :event_writer_bulk_insert, BulkInsertStub)
      Application.put_env(:serviceradar_core, :stateful_alert_evaluation_queue, AlertQueueStub)

      on_exit(fn ->
        restore_env(:event_writer_bulk_insert, previous_bulk_insert)
        restore_env(:stateful_alert_evaluation_queue, previous_alert_queue)
      end)

      payload = %{
        "event_id" => "anomaly-bulk-insert-1",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "device_uid" => "sr:anomaly-device",
        "anomaly" => %{
          "series_key" => "sysmon:memory:sr:anomaly-device",
          "metric_class" => "sysmon.memory",
          "state" => "anomalous"
        }
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{
          subject: "signals.causal.predictions.sysmon:memory:sr:anomaly-device",
          received_at: DateTime.utc_now()
        },
        ack_data: %{}
      }

      assert {:ok, 1} = CausalSignals.process_batch([message])

      assert_receive {:bulk_insert, "ocsf_events", [row],
                      [on_conflict: :nothing, returning: false]}

      assert row.class_uid == 2004
      assert row.metadata["signal_type"] == "causal"
      assert row.metadata["event_type"] == "anomaly"

      assert_receive {:alert_evaluation_events, [alert_row]}
      assert alert_row.id == row.metadata["event_identity"]
    end

    test "redelivered edge anomaly converges on one inserted event and alert evaluation" do
      previous_bulk_insert = Application.get_env(:serviceradar_core, :event_writer_bulk_insert)

      previous_alert_queue =
        Application.get_env(:serviceradar_core, :stateful_alert_evaluation_queue)

      Process.put(:causal_signals_test_pid, self())
      Process.put(:causal_signals_seen_rows, MapSet.new())

      Application.put_env(:serviceradar_core, :event_writer_bulk_insert, DedupingBulkInsertStub)
      Application.put_env(:serviceradar_core, :stateful_alert_evaluation_queue, AlertQueueStub)

      on_exit(fn ->
        restore_env(:event_writer_bulk_insert, previous_bulk_insert)
        restore_env(:stateful_alert_evaluation_queue, previous_alert_queue)
      end)

      payload = %{
        "event_id" => "anomaly-redelivery-converges",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_800_000_000,
        "severity_id" => 4,
        "device_uid" => "sr:anomaly-device",
        "verdict_source" => "edge-spike",
        "anomaly" => %{
          "series_key" => "sysmon:cpu:sr:anomaly-device",
          "metric_class" => "sysmon.cpu",
          "state" => "anomalous"
        }
      }

      message = %{
        data: Jason.encode!(payload),
        metadata: %{
          subject: "signals.causal.predictions.sysmon:cpu:sr:anomaly-device",
          received_at: ~U[2027-06-13 12:00:00Z]
        },
        ack_data: %{}
      }

      assert {:ok, 1} = CausalSignals.process_batch([message])

      assert_receive {:deduping_bulk_insert, "ocsf_events", [first_row], [first_row],
                      [on_conflict: :nothing, returning: false]}

      assert_receive {:alert_evaluation_events, [first_alert_row]}

      assert {:ok, 1} = CausalSignals.process_batch([message])

      assert_receive {:deduping_bulk_insert, "ocsf_events", [replayed_row], [],
                      [on_conflict: :nothing, returning: false]}

      refute_receive {:alert_evaluation_events, [_duplicate_alert_row]}, 50

      assert replayed_row.id == first_row.id
      assert replayed_row.time == first_row.time

      assert replayed_row.metadata["finding_info"]["uid"] ==
               first_row.metadata["finding_info"]["uid"]

      assert first_alert_row.id == first_row.metadata["event_identity"]
    end

    test "repeated central worker verdicts keep one finding identity across run timestamps" do
      forecast = %{
        forecasted_at: ~U[2026-06-12 12:00:00Z],
        resource_key: "cpu_usage:device-a:host-a",
        resource_type: "cpu",
        resource_id: "device-a",
        resource_label: "host-a / device-a",
        metric_class: "cpu",
        metric_name: "usage_percent",
        horizon_seconds: 86_400,
        horizon_ends_at: ~U[2026-06-13 12:00:00Z],
        window_started_at: ~U[2026-06-01 00:00:00Z],
        window_ended_at: ~U[2026-06-02 23:00:00Z],
        sample_count: 48,
        model: "linear",
        status: "projected",
        current_value: 86.0,
        projected_value: 103.0,
        projected_exhaustion_at: ~U[2026-06-12 22:00:00Z],
        exhaustion_threshold: 100.0,
        confidence: 0.82
      }

      later_forecast =
        forecast
        |> Map.put(:forecasted_at, ~U[2026-06-12 13:00:00Z])
        |> Map.put(:horizon_ends_at, ~U[2026-06-13 13:00:00Z])

      seasonal = %{
        series_key: "partition:default|device:device-a|metric:cpu.usage_percent",
        resource_type: "cpu",
        resource_id: "device-a",
        resource_label: "host-a",
        metric_class: "cpu",
        metric_name: "cpu.usage_percent",
        disposition: "seasonal_breach",
        status: "breach",
        score: 4.2,
        consecutive_anomalous: 3,
        dow: 5,
        hod: 13,
        sample_value: 88.0,
        evaluated_at: ~U[2026-06-12 13:15:00Z],
        bucket_started_at: ~U[2026-06-12 13:00:00Z],
        bucket_ended_at: ~U[2026-06-12 14:00:00Z]
      }

      later_seasonal =
        seasonal
        |> Map.put(:evaluated_at, ~U[2026-06-12 15:15:00Z])
        |> Map.put(:bucket_started_at, ~U[2026-06-12 15:00:00Z])
        |> Map.put(:bucket_ended_at, ~U[2026-06-12 16:00:00Z])

      assert_same_processor_finding_identity(
        VerdictEmitter.payload(forecast, VerdictEmitter.subject(forecast)),
        VerdictEmitter.payload(later_forecast, VerdictEmitter.subject(later_forecast)),
        VerdictEmitter.subject(forecast)
      )

      assert_same_processor_finding_identity(
        SeasonalVerdictEmitter.payload(seasonal, SeasonalVerdictEmitter.subject(seasonal)),
        SeasonalVerdictEmitter.payload(
          later_seasonal,
          SeasonalVerdictEmitter.subject(later_seasonal)
        ),
        SeasonalVerdictEmitter.subject(seasonal)
      )
    end

    test "carries the verdict_source label into service_radar metadata for the edge<->central join" do
      edge = %{
        "event_id" => "anomaly-edge-1",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "device_uid" => "sr:anomaly-device",
        "verdict_source" => "edge-spike",
        "anomaly" => %{
          "series_key" => "sysmon:cpu:sr:anomaly-device",
          "metric_class" => "sysmon.cpu",
          "state" => "anomalous"
        }
      }

      meta = %{
        subject: "signals.causal.predictions.sysmon:cpu:sr:anomaly-device",
        received_at: DateTime.utc_now()
      }

      row = CausalSignals.parse_message(%{data: Jason.encode!(edge), metadata: meta})

      assert row.metadata["service_radar"]["verdict_source"] == "edge-spike"
      assert row.metadata["detection_finding"]["source"] == "edge-spike"

      # A central verdict (no label) defaults to "central".
      central_row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(Map.delete(edge, "verdict_source")),
          metadata: meta
        })

      assert central_row.metadata["service_radar"]["verdict_source"] == "central"
    end

    test "parses anomaly numeric Unix timestamps in seconds through nanoseconds" do
      base = ~U[2026-06-12 12:00:00.123456Z]

      cases = [
        {"seconds", DateTime.to_unix(base, :second),
         DateTime.from_unix!(DateTime.to_unix(base, :second), :second)},
        {"milliseconds", DateTime.to_unix(base, :millisecond),
         DateTime.from_unix!(DateTime.to_unix(base, :millisecond), :millisecond)},
        {"microseconds", DateTime.to_unix(base, :microsecond),
         DateTime.from_unix!(DateTime.to_unix(base, :microsecond), :microsecond)},
        {"nanoseconds", DateTime.to_unix(base, :nanosecond),
         DateTime.from_unix!(DateTime.to_unix(base, :nanosecond), :nanosecond)}
      ]

      Enum.each(cases, fn {label, timestamp, expected} ->
        payload = %{
          "event_id" => "anomaly-numeric-time-#{label}",
          "signal_type" => "causal",
          "event_type" => "anomaly",
          "class_uid" => 2004,
          "time" => timestamp,
          "severity_id" => 4,
          "device_uid" => "sr:anomaly-device",
          "anomaly" => %{
            "series_key" => "sysmon:cpu:sr:anomaly-device",
            "metric_class" => "sysmon.cpu",
            "state" => "anomalous"
          }
        }

        row =
          CausalSignals.parse_message(%{
            data: Jason.encode!(payload),
            metadata: %{
              subject: "signals.causal.predictions.sysmon:cpu:sr:anomaly-device",
              received_at: ~U[2026-06-13 12:00:00Z]
            }
          })

        assert DateTime.to_unix(row.time, :microsecond) ==
                 DateTime.to_unix(expected, :microsecond)
      end)
    end

    test "overwrites stale anomaly finding identity after canonical re-keying" do
      payload = %{
        "event_id" => "anomaly-stale-finding-info",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "device_uid" => "sr:anomaly-device",
        "finding_info" => %{
          "uid" => "stale-producer-uid",
          "group_uid" => "stale-producer-group",
          "title" => "Edge supplied title",
          "dimensions" => %{"series_key" => "provisional-series"}
        },
        "anomaly" => %{
          "series_key" => "sysmon:cpu:sr:anomaly-device:core0",
          "metric_class" => "sysmon.cpu",
          "state" => "anomalous"
        }
      }

      row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.causal.predictions.sysmon:cpu:sr:anomaly-device",
            received_at: DateTime.utc_now()
          }
        })

      finding_info = row.metadata["finding_info"]

      assert finding_info["uid"] != "stale-producer-uid"
      assert finding_info["group_uid"] == finding_info["uid"]
      assert finding_info["uid"] == row.metadata["service_radar"]["finding_uid"]
      assert finding_info["title"] == "Edge supplied title"
      assert finding_info["dimensions"]["device_uid"] == "sr:anomaly-device"
      assert finding_info["dimensions"]["series_key"] == "sysmon:cpu:sr:anomaly-device:core0"
      assert finding_info["dimensions"]["metric_class"] == "sysmon.cpu"
    end

    test "uses source_identity device uid as anomaly fallback identity" do
      payload = %{
        "event_id" => "anomaly-source-identity-device",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "source_identity" => %{
          "device_id" => "device-a",
          "host_id" => "host-a",
          "partition" => "prod-east"
        },
        "anomaly" => %{
          "series_key" => "sysmon.cpu:sysmon:cpu:prod-east:device-a:0",
          "metric_class" => "sysmon.cpu",
          "state" => "anomalous"
        }
      }

      row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.causal.predictions.sysmon_cpu:sysmon:cpu:prod-east:device-a:0",
            received_at: DateTime.utc_now()
          }
        })

      assert row.device == %{"uid" => "device-a"}
      assert row.metadata["service_radar"]["device_uid"] == "device-a"
      assert row.metadata["finding_info"]["dimensions"]["device_uid"] == "device-a"
    end

    test "uses SNMP target device IP instead of poller identity for remote target anomalies" do
      payload = %{
        "event_id" => "snmp-target-anomaly",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "device_uid" => "poller-device",
        "target_device_ip" => "198.51.100.25",
        "source_identity" => %{
          "agent_id" => "poller-agent",
          "host_id" => "poller-host",
          "device_id" => "poller-device",
          "target_device_ip" => "198.51.100.25",
          "partition" => "prod-east",
          "if_index" => 7
        },
        "anomaly" => %{
          "series_key" => "198.51.100.25|snmp.ifInOctets|7",
          "metric_class" => "snmp.interface",
          "target_device_ip" => "198.51.100.25",
          "metadata" => %{"target_device_ip" => "198.51.100.25"},
          "state" => "confirmed_anomaly"
        }
      }

      row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.causal.predictions.snmp_interface:198.51.100.25:7",
            received_at: DateTime.utc_now()
          }
        })

      assert row.device == %{"uid" => "198.51.100.25"}
      assert row.metadata["target_device_ip"] == "198.51.100.25"
      assert row.metadata["source_identity"]["target_device_ip"] == "198.51.100.25"
      assert row.metadata["service_radar"]["device_uid"] == "198.51.100.25"
      assert row.metadata["finding_info"]["dimensions"]["device_uid"] == "198.51.100.25"

      assert row.metadata["finding_info"]["dimensions"]["series_key"] ==
               "198.51.100.25|snmp.ifInOctets|7"
    end

    test "selects capacity causal prediction findings for stateful alert evaluation" do
      forecast = %{
        forecasted_at: ~U[2026-06-12 12:00:00Z],
        resource_key: "cpu_usage:device-a:host-a",
        resource_type: "cpu",
        resource_id: "device-a",
        resource_label: "host-a / device-a",
        metric_class: "cpu",
        metric_name: "usage_percent",
        horizon_seconds: 86_400,
        horizon_ends_at: ~U[2026-06-13 12:00:00Z],
        window_started_at: ~U[2026-06-01 00:00:00Z],
        window_ended_at: ~U[2026-06-02 23:00:00Z],
        sample_count: 48,
        model: "linear",
        status: "projected",
        current_value: 86.0,
        projected_value: 103.0,
        projected_exhaustion_at: ~U[2026-06-12 22:00:00Z],
        exhaustion_threshold: 100.0,
        confidence: 0.82
      }

      subject = VerdictEmitter.subject(forecast)

      row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(VerdictEmitter.payload(forecast, subject)),
          metadata: %{subject: subject, received_at: forecast.forecasted_at}
        })

      assert row.class_uid == 2004
      assert row.metadata["signal_type"] == "causal"
      assert row.metadata["event_type"] == "capacity_forecast"
      assert row.metadata["security_signal"]["source"] == "capacity_forecasting"
      assert row.metadata["service_radar"]["source_type"] == "capacity_forecasting"
      assert row.metadata["service_radar"]["addon_id"] == "capacity-forecasting"
      assert row.metadata["detection_finding"]["type"] == "capacity_forecast"
      assert row.log_provider == "capacity_forecasting"

      assert [alert_row] = CausalSignals.alert_evaluation_rows([row])
      assert alert_row.id == row.metadata["event_identity"]
    end

    test "does not select generic causal overlay events for stateful alert evaluation" do
      row = %{
        id: Ecto.UUID.generate(),
        class_uid: 1008,
        metadata: %{"signal_type" => "bmp", "event_type" => "route_update"},
        unmapped: %{}
      }

      assert [] = CausalSignals.alert_evaluation_rows([row])
    end
  end

  defp bmp_burst_messages do
    now = "2026-02-16T13:00:00Z"

    # Duplicate logical event id in same burst to assert deterministic projection contract.
    Enum.map(
      [
        %{
          "event_id" => "bmp-a",
          "timestamp" => now,
          "severity" => "high",
          "device_id" => "router-a",
          "peer_ip" => "192.0.2.1",
          "message" => "peer down"
        },
        %{
          "event_id" => "bmp-b",
          "timestamp" => now,
          "severity" => "critical",
          "device_id" => "router-b",
          "peer_ip" => "192.0.2.2",
          "message" => "withdraw storm"
        },
        %{
          "event_id" => "bmp-c",
          "timestamp" => now,
          "severity" => "medium",
          "device_id" => "router-a",
          "peer_ip" => "192.0.2.1",
          "message" => "path change"
        },
        %{
          "event_id" => "bmp-d",
          "timestamp" => now,
          "severity" => "low",
          "device_id" => "router-c",
          "peer_ip" => "192.0.2.3",
          "message" => "route flap"
        },
        %{
          "event_id" => "bmp-a",
          "timestamp" => now,
          "severity" => "high",
          "device_id" => "router-a",
          "peer_ip" => "192.0.2.1",
          "message" => "peer down"
        }
      ],
      fn payload ->
        %{
          data: Jason.encode!(payload),
          metadata: %{subject: "bmp.events.peer", received_at: DateTime.utc_now()},
          ack_data: %{}
        }
      end
    )
  end

  defp route_broadway_messages(events) do
    Enum.map(events, fn event ->
      message = Pipeline.transform(event, [])
      routed = Pipeline.handle_message(:default, message, %{})
      assert routed.batcher in [:bmp_causal, :arancini_causal, :siem_causal, :causal_predictions]
      routed
    end)
  end

  defp parse_causal_rows(messages) do
    messages
    |> Enum.map(fn message ->
      CausalSignals.parse_message(%{data: message.data, metadata: message.metadata})
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Deterministic projection used by topology causal overlays:
  # identity + signal attributes sorted independent of ingest/replay order.
  defp causal_overlay_projection(rows) do
    rows
    |> MapSet.new(fn row ->
      {
        row.metadata["event_identity"],
        row.metadata["signal_type"],
        row.severity_id,
        row.device["uid"],
        row.src_endpoint["ip"]
      }
    end)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp grouped_projection(rows) do
    rows
    |> Enum.map(fn row ->
      context_ids =
        row.metadata["grouped_contexts"]
        |> Enum.map(&{"#{&1["type"]}", "#{&1["id"]}"})
        |> Enum.sort()

      {row.metadata["event_identity"], row.metadata["primary_domain"], context_ids}
    end)
    |> Enum.sort()
  end

  defp assert_same_processor_finding_identity(first_payload, second_payload, subject) do
    first_row =
      CausalSignals.parse_message(%{
        data: Jason.encode!(first_payload),
        metadata: %{subject: subject, received_at: ~U[2026-06-12 12:00:00Z]}
      })

    second_row =
      CausalSignals.parse_message(%{
        data: Jason.encode!(second_payload),
        metadata: %{subject: subject, received_at: ~U[2026-06-12 13:00:00Z]}
      })

    assert first_row.id == second_row.id
    assert first_row.metadata["finding_info"]["uid"] == second_row.metadata["finding_info"]["uid"]

    assert first_row.metadata["service_radar"]["finding_uid"] ==
             second_row.metadata["service_radar"]["finding_uid"]
  end

  defp load_event_writer_fixture!(file_name) do
    fixture_path =
      Path.join([
        __DIR__,
        "..",
        "..",
        "..",
        "support",
        "fixtures",
        "event_writer",
        file_name
      ])

    fixture_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp assert_arancini_contract_keys!(payload) when is_map(payload) do
    required_keys = [
      "router_addr",
      "peer_addr",
      "peer_asn",
      "prefix_addr",
      "prefix_len",
      "announced"
    ]

    for key <- required_keys do
      assert Map.has_key?(payload, key), "missing required arancini key: #{key}"
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
