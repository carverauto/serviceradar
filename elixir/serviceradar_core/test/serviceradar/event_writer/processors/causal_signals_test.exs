defmodule ServiceRadar.EventWriter.Processors.CausalSignalsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.DeviceCorrelationCache
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.CausalSignals
  alias ServiceRadar.Observability.CapacityForecasting.VerdictEmitter

  # Prime the (app-started, shared ETS) correlation cache so an SNMP target ip
  # resolves to a canonical device uid — letting tests exercise the resolved
  # path (the unresolved path withholds). Use a unique ip per test to avoid
  # cross-contamination under `async: true`.
  defp seed_target_resolution(ip, uid) do
    candidate = %{device_uid: ip, agent_id: nil, hostname: nil, ip: ip, partition: nil}
    DeviceCorrelationCache.put(DeviceCorrelationCache.cache_key(candidate), uid)
  end

  defp attach_withheld_anomaly_telemetry(test_pid \\ self()) do
    handler_id = {__MODULE__, :withheld_anomaly, make_ref()}

    :telemetry.attach(
      handler_id,
      [:serviceradar, :event_writer, :anomaly_detection, :withheld],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:withheld_anomaly, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defmodule ExistingTimeRepo do
    def query(sql, [ids]) do
      send(Process.get(:causal_signals_test_pid), {:existing_time_query, sql, ids})

      rows =
        Enum.flat_map(ids, fn id ->
          case Process.get({:existing_ocsf_time, id}) do
            %DateTime{} = time -> [[id, time]]
            _ -> []
          end
        end)

      {:ok, %{rows: rows}}
    end
  end

  describe "table_name/0" do
    test "returns ocsf_events" do
      assert CausalSignals.table_name() == "ocsf_events"
    end
  end

  describe "align_existing_ocsf_event_times/2" do
    test "reuses the first persisted time for a deterministic causal finding id" do
      event_id = Ecto.UUID.generate()
      existing_time = ~U[2026-06-12 12:00:00Z]
      next_time = ~U[2026-06-12 12:05:00Z]

      Process.put(:causal_signals_test_pid, self())
      Process.put({:existing_ocsf_time, event_id}, existing_time)

      row = %{
        id: event_id,
        time: next_time,
        class_uid: 2004,
        metadata: %{"signal_type" => "causal", "event_type" => "capacity_forecast"},
        unmapped: %{}
      }

      assert [%{time: ^existing_time}] =
               CausalSignals.align_existing_ocsf_event_times([row], ExistingTimeRepo)

      assert_received {:existing_time_query, sql, [^event_id]}
      assert sql =~ "min(time)"
      assert sql =~ "platform.ocsf_events"
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

    test "preserves causal finding producer timestamps in common Unix units" do
      event_time = ~U[2026-06-12 12:00:00Z]

      for {unit, value} <- [
            second: DateTime.to_unix(event_time, :second),
            millisecond: DateTime.to_unix(event_time, :millisecond),
            microsecond: DateTime.to_unix(event_time, :microsecond),
            nanosecond: DateTime.to_unix(event_time, :nanosecond)
          ] do
        payload = %{
          "event_id" => "anomaly-time-#{unit}",
          "signal_type" => "causal",
          "event_type" => "anomaly",
          "class_uid" => 2004,
          "time" => value,
          "severity_id" => 4,
          "device_uid" => "sr:anomaly-device",
          "anomaly" => %{
            "series_key" => "sysmon:cpu:sr:anomaly-device:0",
            "metric_class" => "sysmon.cpu",
            "state" => "anomaly_open"
          }
        }

        row =
          CausalSignals.parse_message(%{
            data: Jason.encode!(payload),
            metadata: %{
              subject: "signals.causal.predictions.sysmon:cpu:sr:anomaly-device:0",
              received_at: DateTime.add(event_time, 1_000, :second)
            }
          })

        assert DateTime.compare(row.time, event_time) == :eq
      end
    end

    test "emits bounded diagnostics when malformed producer time falls back to ingest time" do
      test_pid = self()
      handler_id = {__MODULE__, :timestamp_fallback, make_ref()}

      :telemetry.attach(
        handler_id,
        [:serviceradar, :event_writer, :causal_signals, :timestamp_fallback],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:timestamp_fallback, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      payload = %{
        "event_id" => "anomaly-bad-time",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => "not-a-timestamp",
        "severity_id" => 4,
        "device_uid" => "sr:anomaly-device",
        "anomaly" => %{
          "series_key" => "sysmon:cpu:sr:anomaly-device:0",
          "metric_class" => "sysmon.cpu",
          "state" => "anomaly_open"
        }
      }

      row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.causal.predictions.sysmon:cpu:sr:anomaly-device:0",
            received_at: ~U[2026-06-12 12:00:00Z]
          }
        })

      assert %DateTime{} = row.time

      assert_receive {:timestamp_fallback,
                      [:serviceradar, :event_writer, :causal_signals, :timestamp_fallback],
                      %{count: 1}, %{subject_class: "causal", reason: :malformed_timestamp}}
    end

    test "withholds an SNMP anomaly when the polled target is not resolvable to inventory" do
      attach_withheld_anomaly_telemetry()
      target_ip = "10.0.0.20"

      payload = %{
        "event_id" => "snmp-target-unresolved",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_456_000_000,
        "severity_id" => 4,
        "device_uid" => "agent-ns03",
        "agent_id" => "agent-ns03",
        "target_device_ip" => target_ip,
        "anomaly" => %{
          "series_key" => "snmp:#{target_ip}:7",
          "metric_class" => "snmp",
          "state" => "anomaly_open",
          "target_device_ip" => target_ip
        },
        "source_identity" => %{
          "agent_id" => "agent-ns03",
          "host_id" => "ns03",
          "target_device_ip" => target_ip
        }
      }

      # DeviceCorrelation.resolve fail-opens to nil here (no backing inventory),
      # so the polled target is unresolvable. The finding is withheld rather than
      # falling back to the bare target ip (and never to the polling agent).
      assert CausalSignals.parse_message(%{
               data: Jason.encode!(payload),
               metadata: %{
                 subject: "signals.causal.predictions.snmp:#{target_ip}:7",
                 received_at: DateTime.utc_now()
               }
             }) == nil

      assert_receive {:withheld_anomaly,
                      [:serviceradar, :event_writer, :anomaly_detection, :withheld], %{count: 1},
                      %{reason: :snmp_target_unresolvable, metric_class: "snmp"}}
    end

    test "withholds an SNMP anomaly that carries no target ip (never attributes to the polling agent)" do
      attach_withheld_anomaly_telemetry()

      # Reproduces the demo defect: the edge addon emits an SNMP interface anomaly
      # keyed only on the polling agent (no target_device_ip), so the polled
      # device is unidentifiable. It must be withheld, never shown on the agent's
      # own device-details page.
      payload = %{
        "event_id" => "snmp-no-target",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_456_000_000,
        "severity_id" => 5,
        "device_uid" => "agent-dusk01",
        "agent_id" => "agent-dusk01",
        "anomaly" => %{
          "series_key" => "v2:class=snmp:family=ifOutUcastPkts:identity=agent-dusk01:if_index=6",
          "metric_class" => "snmp",
          "state" => "anomalous"
        },
        "source_identity" => %{
          "device_uid" => "agent-dusk01"
        }
      }

      assert CausalSignals.parse_message(%{
               data: Jason.encode!(payload),
               metadata: %{
                 subject: "signals.causal.predictions.snmp.ifOutUcastPkts",
                 received_at: DateTime.utc_now()
               }
             }) == nil

      assert_receive {:withheld_anomaly,
                      [:serviceradar, :event_writer, :anomaly_detection, :withheld], %{count: 1},
                      %{reason: :snmp_target_missing, metric_class: "snmp"}}
    end

    test "keeps host-metric (non-SNMP) anomaly attribution on the agent device" do
      # Host metrics (cpu/memory/disk) legitimately belong to the agent's own
      # device, so the SNMP withhold guard must not touch them.
      payload = %{
        "event_id" => "host-cpu-anomaly",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_456_000_000,
        "severity_id" => 4,
        "device_uid" => "ns01",
        "agent_id" => "agent-ns01",
        "anomaly" => %{
          "series_key" => "sysmon:cpu:ns01:0",
          "metric_class" => "sysmon.cpu",
          "state" => "anomaly_open"
        }
      }

      row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.causal.predictions.sysmon:cpu:ns01:0",
            received_at: DateTime.utc_now()
          }
        })

      assert row
      assert row.device["uid"] == "ns01"
      assert row.metadata["service_radar"]["device_uid"] == "ns01"
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

    test "overwrites stale edge finding_info with canonical device and series identity" do
      edge = %{
        "event_id" => "anomaly-edge-stale-finding-info",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_456_000_000,
        "severity_id" => 4,
        "device_uid" => "sr:canonical-device",
        "verdict_source" => "edge-spike",
        "finding_info" => %{
          "uid" => "stale-producer-uid",
          "group_uid" => "stale-producer-group",
          "title" => "Producer supplied title",
          "dimensions" => %{
            "device_uid" => "raw-agent-device",
            "series_key" => "edge-hint-provisional",
            "metric_class" => "sysmon.cpu"
          }
        },
        "anomaly" => %{
          "series_key" => "canonical-series-key",
          "metric_class" => "sysmon.cpu",
          "state" => "anomaly_open"
        }
      }

      meta = %{
        subject: "signals.causal.predictions.canonical-series-key",
        received_at: DateTime.utc_now()
      }

      stale_row = CausalSignals.parse_message(%{data: Jason.encode!(edge), metadata: meta})

      canonical_row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(Map.delete(edge, "finding_info")),
          metadata: meta
        })

      finding_info = stale_row.metadata["finding_info"]

      assert finding_info["uid"] == canonical_row.metadata["finding_info"]["uid"]
      assert finding_info["group_uid"] == finding_info["uid"]
      refute finding_info["uid"] == "stale-producer-uid"
      refute finding_info["group_uid"] == "stale-producer-group"
      refute finding_info["title"] == "Producer supplied title"
      assert finding_info["title"] == "Anomaly detection: sysmon.cpu canonical-series-key"

      assert finding_info["dimensions"]["device_uid"] == "sr:canonical-device"
      assert finding_info["dimensions"]["series_key"] == "canonical-series-key"
      assert finding_info["dimensions"]["metric_class"] == "sysmon.cpu"

      assert stale_row.metadata["service_radar"]["finding_uid"] == finding_info["uid"]
      assert stale_row.metadata["service_radar"]["series_key"] == "canonical-series-key"
      assert stale_row.metadata["security_signal"]["finding_uid"] == finding_info["uid"]
    end

    test "uses structured anomaly dimensions for titles when series keys are opaque" do
      target_ip = "192.0.2.20"
      seed_target_resolution(target_ip, "sr:edge-target")

      opaque_series_key =
        "v2:partition=64656661756c74:class=736e6d702e696e74657266616365:identity=31302e302e302e3230"

      payload = %{
        "event_id" => "anomaly-edge-opaque-series-key",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "device_uid" => target_ip,
        "target_device_ip" => target_ip,
        "verdict_source" => "edge-spike",
        "anomaly" => %{
          "series_key" => opaque_series_key,
          "metric_class" => "snmp.interface",
          "metric_name" => "ifHCInOctets",
          "target_device_ip" => target_ip,
          "interface_name" => "uplink0",
          "if_index" => 7,
          "state" => "anomaly_open"
        }
      }

      row =
        CausalSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.causal.predictions.#{opaque_series_key}",
            received_at: DateTime.utc_now()
          }
        })

      finding_info = row.metadata["finding_info"]
      dimensions = finding_info["dimensions"]

      # Resolved SNMP target → the finding is attributed to the polled device,
      # not the polling agent.
      assert row.device["uid"] == "sr:edge-target"
      assert dimensions["device_uid"] == "sr:edge-target"

      assert finding_info["title"] ==
               "Anomaly detection: ifHCInOctets 192.0.2.20 uplink0 ifIndex 7"

      refute finding_info["title"] =~ "v2:"
      assert dimensions["series_key"] == opaque_series_key
      assert dimensions["metric_name"] == "ifHCInOctets"
      assert dimensions["target_device_ip"] == target_ip
      assert dimensions["interface_name"] == "uplink0"
      assert dimensions["if_index"] == 7
      assert dimensions["resource_label"] == "192.0.2.20 uplink0 ifIndex 7"
    end

    test "withholds a future-versioned opaque-series-key SNMP anomaly with no target ip" do
      # An snmp.interface finding with an opaque (future-versioned) series key and
      # no resolvable target is withheld, so the opaque key never surfaces in a
      # title or on the polling agent's device page.
      opaque_series_key =
        "v3:partition=64656661756c74:class=736e6d702e696e74657266616365:identity=31302e302e302e3230"

      payload = %{
        "event_id" => "anomaly-edge-future-opaque-series-key",
        "signal_type" => "causal",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "device_uid" => "10.0.0.20",
        "verdict_source" => "edge-spike",
        "anomaly" => %{
          "series_key" => opaque_series_key,
          "metric_class" => "snmp.interface",
          "state" => "anomaly_open"
        }
      }

      assert CausalSignals.parse_message(%{
               data: Jason.encode!(payload),
               metadata: %{
                 subject: "signals.causal.predictions.#{opaque_series_key}",
                 received_at: DateTime.utc_now()
               }
             }) == nil
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
end
