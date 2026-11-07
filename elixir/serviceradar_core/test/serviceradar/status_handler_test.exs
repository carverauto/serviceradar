defmodule ServiceRadar.StatusHandlerTest do
  use ExUnit.Case, async: false

  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Agent.Addon.V1.TelemetrySource
  alias ServiceRadar.Ingestion.StatusIngestor
  alias ServiceRadar.Observability.CausalPredictionSubject
  alias ServiceRadar.StatusHandler

  describe "addon telemetry source" do
    setup do
      original = Application.get_env(:serviceradar_core, StatusHandler, [])

      Application.put_env(:serviceradar_core, StatusHandler,
        addon_telemetry_publisher: {__MODULE__, :stub_publish, [self()]}
      )

      on_exit(fn ->
        if original == [] do
          Application.delete_env(:serviceradar_core, StatusHandler)
        else
          Application.put_env(:serviceradar_core, StatusHandler, original)
        end
      end)

      :ok
    end

    defp addon_status_with(records) do
      %{
        source: "addon:powerdns",
        service_type: "native-addon",
        service_name: "addon-telemetry",
        agent_id: "ns03",
        gateway_id: "gateway-a",
        partition: "prod-east",
        source_ip: "192.0.2.55",
        message:
          TelemetryBatch.encode(%TelemetryBatch{
            source: %TelemetrySource{source_type: "powerdns", source_instance: "ns03"},
            records: records
          })
      }
    end

    defp attach_unpublished_counter(name) do
      parent = self()

      :telemetry.attach(
        name,
        [:serviceradar, :status_handler, :addon_telemetry, :unpublished],
        fn _event, measurements, metadata, _config ->
          send(parent, {:unpublished, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(name) end)
    end

    test "an unrecognized payload kind is dropped loudly, not silently" do
      # This was a bare `true -> :ok`. An add-on could ship a new payload kind,
      # have every record discarded, and the service would still report HEALTHY
      # -- indistinguishable from an add-on that produced nothing.
      attach_unpublished_counter("unpublished-unknown")

      status =
        addon_status_with([
          %TelemetryRecord{
            event_id: "unknown-1",
            payload_kind: 4242,
            payload: "{}"
          }
        ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = StatusIngestor.ingest(status)
        end)

      assert_receive {:unpublished, %{count: 1}, %{reason: :unknown_payload_kind}}
      assert log =~ "unrecognized payload kind"
    end

    test "SERVICERADAR_METRICS records are counted, not warned about" do
      # The load-bearing negative control. The Rust add-on SDK sends metrics
      # through StreamTelemetry; the gateway's PluginMetricsPublisher consumes
      # them and the status is STILL forwarded here with those records intact.
      # Treating them as unrecognized would log a warning per metric record from
      # every Rust add-on in the fleet.
      attach_unpublished_counter("unpublished-metrics")

      status =
        addon_status_with([
          %TelemetryRecord{
            event_id: "metric-1",
            payload_kind: :TELEMETRY_PAYLOAD_KIND_SERVICERADAR_METRICS,
            payload: "encoded-metric-batch"
          }
        ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = StatusIngestor.ingest(status)
        end)

      assert_receive {:unpublished, %{count: 1}, %{reason: :handled_elsewhere}}
      refute log =~ "unrecognized payload kind"
    end

    test "OTLP kinds are known-but-elsewhere, not unrecognized" do
      # They ride AddonService.RelayOtlp rather than StreamTelemetry, so they
      # should not appear in a batch -- but "known kind on the wrong path" and
      # "kind core has never heard of" are different faults and the telemetry
      # should be able to tell them apart.
      attach_unpublished_counter("unpublished-otlp")

      status =
        addon_status_with([
          %TelemetryRecord{
            event_id: "otlp-1",
            payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
            payload: "encoded-otlp"
          }
        ])

      assert :ok = StatusIngestor.ingest(status)

      assert_receive {:unpublished, %{count: 1}, %{reason: :handled_elsewhere}}
    end

    test "publishes OCSF add-on telemetry records to pdns.ocsf with trusted metadata" do
      ocsf_event =
        Jason.encode!(%{
          "id" => "4cc2b0d9-2f02-437c-83ec-df0d53ebdb47",
          "time" => "2026-06-08T12:00:00Z",
          "class_uid" => 4003,
          "category_uid" => 4,
          "type_uid" => 400_302,
          "activity_id" => 2,
          "severity_id" => 3,
          "metadata" => %{
            "service_radar" => %{
              "addon_id" => "spoofed-addon",
              "agent_id" => "spoofed-agent",
              "gateway_id" => "spoofed-gateway",
              "partition_id" => "spoofed-partition",
              "source_ip" => "203.0.113.1"
            }
          }
        })

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{source_type: "powerdns", source_instance: "ns03"},
          records: [
            %TelemetryRecord{
              event_id: "pdns-event-1",
              observed_time_unix_nano: 1_812_456_000_000_000_000,
              event_time_unix_nano: 1_812_456_000_000_000_000,
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: ocsf_event,
              metadata: %{
                "serviceradar.signal_schema.producer_id" => "powerdns",
                "serviceradar.signal_schema.producer_version" => "0.1.0",
                "serviceradar.signal_schema.schema_id" => "com.carverauto.powerdns.dns_activity",
                "serviceradar.signal_schema.schema_version" => "1.0.0",
                "serviceradar.signal_schema.display_contract_id" =>
                  "com.carverauto.powerdns.dns_activity.display",
                "serviceradar.signal_schema.display_contract_version" => "1.0.0",
                "serviceradar.signal_schema.display_contract" =>
                  "display/dns_activity.display.json",
                "serviceradar.signal_schema.signal_type" => "event",
                "serviceradar.signal_schema.payload_kind" => "ocsf_event"
              }
            },
            %TelemetryRecord{
              event_id: "ignored-otel",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTEL_LOG,
              payload: "{}"
            }
          ]
        })

      status = %{
        source: "addon:powerdns",
        service_type: "native-addon",
        service_name: "addon-telemetry",
        agent_id: "ns03",
        gateway_id: "gateway-a",
        partition: "prod-east",
        source_ip: "192.0.2.55",
        message: batch
      }

      assert :ok = StatusIngestor.ingest(status)

      assert_receive {:published, "pdns.ocsf", payload}
      assert {:ok, decoded} = Jason.decode(payload)
      assert decoded["class_uid"] == 4003
      assert decoded["metadata"]["service_radar"]["addon_id"] == "powerdns"
      assert decoded["metadata"]["service_radar"]["agent_id"] == "ns03"
      assert decoded["metadata"]["service_radar"]["gateway_id"] == "gateway-a"
      assert decoded["metadata"]["service_radar"]["partition_id"] == "prod-east"
      assert decoded["metadata"]["service_radar"]["source_ip"] == "192.0.2.55"
      assert decoded["metadata"]["service_radar"]["source_instance"] == "ns03"

      assert decoded["metadata"]["service_radar"]["signal_schema"] == %{
               "producer_id" => "powerdns",
               "producer_version" => "0.1.0",
               "schema_id" => "com.carverauto.powerdns.dns_activity",
               "schema_version" => "1.0.0",
               "display_contract_id" => "com.carverauto.powerdns.dns_activity.display",
               "display_contract_version" => "1.0.0",
               "display_contract" => "display/dns_activity.display.json",
               "signal_type" => "event",
               "payload_kind" => "ocsf_event"
             }

      refute_receive {:published, "pdns.ocsf", _payload}
    end

    test "routes an edge anomaly verdict onto the causal-prediction spine, not the generic OCSF path" do
      verdict_event =
        Jason.encode!(%{
          "id" => "anomaly:sysmon:cpu:host-a:0:1812456000000000000:anomalous",
          "event_id" => "anomaly:sysmon:cpu:host-a:0:1812456000000000000:anomalous",
          "time" => 1_812_456_000_000,
          "signal_type" => "causal",
          "event_type" => "anomaly",
          "class_uid" => 2004,
          "category_uid" => 2,
          "type_uid" => 200_401,
          "activity_id" => 1,
          "severity_id" => 4,
          "provider" => "anomaly_detection",
          "verdict_source" => "edge-spike",
          "device_uid" => "host-a",
          "anomaly" => %{
            "series_key" => "sysmon:cpu:host-a:0",
            "metric_class" => "cpu",
            "state" => "anomalous",
            "score" => 5.2,
            "reason" => "rolling z-score 5.200 breached 3.000"
          }
        })

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{source_type: "anomaly", source_instance: "host-a"},
          records: [
            %TelemetryRecord{
              event_id: "anomaly-verdict-1",
              observed_time_unix_nano: 1_812_456_000_000_000_000,
              event_time_unix_nano: 1_812_456_000_000_000_000,
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: verdict_event,
              metadata: %{
                "serviceradar.signal_schema.schema_id" =>
                  "com.carverauto.anomaly.detection_finding",
                "serviceradar.signal_schema.signal_type" => "event",
                "serviceradar.signal_schema.payload_kind" => "ocsf_event"
              }
            }
          ]
        })

      status = %{
        source: "addon:anomaly",
        service_type: "native-addon",
        service_name: "addon-telemetry",
        agent_id: "host-a",
        gateway_id: "gateway-a",
        partition: "prod-east",
        source_ip: "192.0.2.55",
        message: batch
      }

      assert :ok = StatusIngestor.ingest(status)

      # Routed onto the causal-prediction spine so the EventWriter AnalyticsSignals
      # processor persists + alert-enqueues it through the anomaly finding path,
      # not the generic add-on OCSF subject.
      assert_receive {:published, subject, payload}
      assert String.starts_with?(subject, "signals.analytics.predictions.")
      refute_receive {:published, "pdns.ocsf", _payload}

      assert {:ok, decoded} = Jason.decode(payload)
      assert decoded["signal_type"] == "causal"
      assert decoded["event_type"] == "anomaly"
      assert decoded["class_uid"] == 2004
      assert decoded["verdict_source"] == "edge-spike"
      assert get_in(decoded, ["anomaly", "series_key"]) == "sysmon:cpu:host-a:0"
    end

    test "re-keys an edge verdict to the canonical series_key from source_identity (§3.4b)" do
      source_identity = %{
        "series_key" => "edge-hint-provisional",
        "metric_class" => "snmp.if_octets",
        "metric_name" => "ifHCInOctets",
        "agent_id" => "host-a",
        "host_id" => "",
        "target_device_ip" => "10.0.0.20",
        "partition" => "spoofed-partition",
        "if_index" => 7,
        "tags" => %{"if_alias" => "core *> uplink"}
      }

      # The canonical key derived from attested identity differs from the producer hint, so a
      # passing assertion proves the re-key actually happened (not a pass-through).
      canonical =
        ServiceRadar.Observability.AnomalyDetection.SeriesKey.from_source_identity(
          source_identity,
          partition_id: "prod-east"
        )

      refute canonical == "edge-hint-provisional"

      verdict_event =
        Jason.encode!(%{
          "id" => "anomaly:edge-hint-provisional:1812456000000000000:anomalous",
          "event_id" => "anomaly:edge-hint-provisional:1812456000000000000:anomalous",
          "time" => 1_812_456_000_000,
          "signal_type" => "causal",
          "event_type" => "anomaly",
          "class_uid" => 2004,
          "category_uid" => 2,
          "type_uid" => 200_401,
          "activity_id" => 1,
          "severity_id" => 4,
          "provider" => "anomaly_detection",
          "verdict_source" => "edge-spike",
          "device_uid" => "host-a",
          "source_identity" => source_identity,
          "anomaly" => %{
            "series_key" => "edge-hint-provisional",
            "metric_class" => "sysmon.cpu",
            "state" => "anomalous",
            "score" => 5.2,
            "reason" => "rolling z-score 5.200 breached 3.000"
          }
        })

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{source_type: "anomaly", source_instance: "host-a"},
          records: [
            %TelemetryRecord{
              event_id: "anomaly-verdict-rekey-1",
              observed_time_unix_nano: 1_812_456_000_000_000_000,
              event_time_unix_nano: 1_812_456_000_000_000_000,
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: verdict_event,
              metadata: %{
                "serviceradar.signal_schema.schema_id" =>
                  "com.carverauto.anomaly.detection_finding",
                "serviceradar.signal_schema.signal_type" => "event",
                "serviceradar.signal_schema.payload_kind" => "ocsf_event"
              }
            }
          ]
        })

      status = %{
        source: "addon:anomaly",
        service_type: "native-addon",
        service_name: "addon-telemetry",
        agent_id: "host-a",
        gateway_id: "gateway-a",
        partition: "prod-east",
        source_ip: "192.0.2.55",
        message: batch
      }

      assert :ok = StatusIngestor.ingest(status)

      assert_receive {:published, subject, payload}
      assert subject == CausalPredictionSubject.build(canonical)
      refute subject =~ ".10.0.0.20"
      refute subject =~ "*"
      refute subject =~ ">"
      refute subject =~ " "

      assert {:ok, decoded} = Jason.decode(payload)
      # Persisted under the canonical key (both the anomaly block and the carried
      # source_identity), not the provisional producer hint.
      assert get_in(decoded, ["anomaly", "series_key"]) == canonical
      assert get_in(decoded, ["source_identity", "series_key"]) == canonical
      assert decoded["source_identity"]["partition"] == "spoofed-partition"
      assert canonical =~ "partition=#{Base.encode16("prod-east", case: :lower)}"
      refute canonical =~ Base.encode16("spoofed-partition", case: :lower)
    end

    test "drops a metric body mislabeled as an OCSF event instead of publishing it to the events plane" do
      # A plugin/addon that tags a metric payload as payload_kind=OCSF_EVENT would
      # otherwise be published verbatim onto the events stream (fj #3788 REC10).
      metric_body =
        Jason.encode!(%{
          "schema" => "serviceradar.metric.v1",
          "metric_name" => "cpu.usage",
          "value" => 0.91,
          "temporality" => "cumulative",
          "points" => [%{"time_unix_nano" => 1, "value" => 0.91}]
        })

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{source_type: "powerdns", source_instance: "ns03"},
          records: [
            %TelemetryRecord{
              event_id: "mislabeled-metric-1",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: metric_body,
              metadata: %{
                "serviceradar.signal_schema.payload_kind" => "ocsf_event"
              }
            }
          ]
        })

      status = %{
        source: "addon:powerdns",
        service_type: "native-addon",
        service_name: "addon-telemetry",
        agent_id: "ns03",
        gateway_id: "gateway-a",
        partition: "prod-east",
        message: batch
      }

      assert :ok = StatusIngestor.ingest(status)

      # Dropped at the source: nothing reaches the OCSF events plane.
      refute_receive {:published, "pdns.ocsf", _payload}
    end

    test "strips malformed signal schema references from otherwise valid OCSF records" do
      ocsf_event =
        Jason.encode!(%{
          "id" => "4cc2b0d9-2f02-437c-83ec-df0d53ebdb48",
          "time" => "2026-06-08T12:00:00Z",
          "class_uid" => 4003,
          "category_uid" => 4,
          "type_uid" => 400_302,
          "activity_id" => 2,
          "severity_id" => 3
        })

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{source_type: "powerdns", source_instance: "ns03"},
          records: [
            %TelemetryRecord{
              event_id: "pdns-event-2",
              observed_time_unix_nano: 1_812_456_000_000_000_000,
              event_time_unix_nano: 1_812_456_000_000_000_000,
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: ocsf_event,
              metadata: %{
                "serviceradar.signal_schema.schema_id" => "../bad",
                "serviceradar.signal_schema.schema_version" => "not-semver",
                "serviceradar.signal_schema.display_contract_id" => "bad.display",
                "serviceradar.signal_schema.display_contract_version" => "1.0.0",
                "serviceradar.signal_schema.signal_type" => "event",
                "serviceradar.signal_schema.payload_kind" => "ocsf_event"
              }
            }
          ]
        })

      status = %{
        source: "addon:powerdns",
        service_type: "native-addon",
        service_name: "addon-telemetry",
        agent_id: "ns03",
        gateway_id: "gateway-a",
        partition: "prod-east",
        source_ip: "192.0.2.55",
        message: batch
      }

      assert :ok = StatusIngestor.ingest(status)

      assert_receive {:published, "pdns.ocsf", payload}
      assert {:ok, decoded} = Jason.decode(payload)
      refute Map.has_key?(decoded["metadata"]["service_radar"], "signal_schema")
    end

    test "publishes non-DNS OCSF add-on events to the generic event stream, not pdns.ocsf" do
      # pdns.ocsf is consumed only by the PowerDNS processor, which keeps DNS Activity
      # and discards every other class, so another add-on's event routed there is lost.
      ocsf_event =
        Jason.encode!(%{
          "id" => "6f1c1f0e-8a0b-4e8e-9c33-0d2b4c1a7e10",
          "time" => "2026-06-08T12:00:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "severity_id" => 3,
          "message" => "telemetry spool above high-water mark"
        })

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{source_type: "otel-addon", source_instance: "edge-host-01"},
          records: [
            %TelemetryRecord{
              event_id: "otel-spool-event-1",
              observed_time_unix_nano: 1_812_456_000_000_000_000,
              event_time_unix_nano: 1_812_456_000_000_000_000,
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: ocsf_event
            }
          ]
        })

      status = %{
        source: "addon:otel-addon",
        service_type: "native-addon",
        service_name: "addon-telemetry",
        agent_id: "edge-agent-01",
        gateway_id: "gateway-a",
        partition: "default",
        source_ip: "192.0.2.60",
        message: batch
      }

      assert :ok = StatusIngestor.ingest(status)

      assert_receive {:published, "events.ocsf.processed", payload}
      refute_receive {:published, "pdns.ocsf", _payload}
      assert {:ok, decoded} = Jason.decode(payload)
      assert decoded["class_uid"] == 1008
      assert decoded["metadata"]["service_radar"]["addon_id"] == "otel-addon"
      assert decoded["metadata"]["service_radar"]["agent_id"] == "edge-agent-01"
    end

    test "publishes OCSF plugin telemetry records to the generic event stream" do
      ocsf_event =
        Jason.encode!(%{
          "id" => "4cc2b0d9-2f02-437c-83ec-df0d53ebdb49",
          "time" => "2026-06-08T12:00:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_802,
          "activity_id" => 2,
          "severity_id" => 3
        })

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{source_type: "axis-camera", source_instance: "front-door"},
          records: [
            %TelemetryRecord{
              event_id: "axis-event-1",
              observed_time_unix_nano: 1_812_456_000_000_000_000,
              event_time_unix_nano: 1_812_456_000_000_000_000,
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: ocsf_event,
              metadata: %{
                "serviceradar.signal_schema.producer_id" => "axis",
                "serviceradar.signal_schema.producer_version" => "0.1.0",
                "serviceradar.signal_schema.schema_id" => "com.carverauto.axis_camera.event_log",
                "serviceradar.signal_schema.schema_version" => "1.0.0",
                "serviceradar.signal_schema.display_contract_id" =>
                  "com.carverauto.axis_camera.event_log.display",
                "serviceradar.signal_schema.display_contract_version" => "1.0.0",
                "serviceradar.signal_schema.display_contract" =>
                  "display/event_log_activity.display.json",
                "serviceradar.signal_schema.signal_type" => "event",
                "serviceradar.signal_schema.payload_kind" => "ocsf_event"
              }
            }
          ]
        })

      status = %{
        source: "plugin:axis-assignment",
        service_type: "plugin",
        service_name: "plugin-telemetry",
        agent_id: "agent-a",
        gateway_id: "gateway-a",
        partition: "prod-east",
        source_ip: "192.0.2.55",
        message: batch
      }

      assert :ok = StatusIngestor.ingest(status)

      assert_receive {:published, "events.ocsf.processed", payload}
      assert {:ok, decoded} = Jason.decode(payload)
      assert decoded["metadata"]["service_radar"]["plugin_id"] == "axis-assignment"
      assert decoded["metadata"]["service_radar"]["agent_id"] == "agent-a"
      assert decoded["metadata"]["service_radar"]["source_type"] == "axis-camera"

      assert decoded["metadata"]["service_radar"]["signal_schema"]["schema_id"] ==
               "com.carverauto.axis_camera.event_log"
    end

    test "publishes OTEL plugin telemetry records to the plugin log stream" do
      log =
        Jason.encode!(%{
          "timestamp" => "2026-06-08T12:00:00Z",
          "severity_text" => "INFO",
          "body" => "camera event received",
          "attributes" => %{"existing" => "kept"}
        })

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{source_type: "axis-camera", source_instance: "front-door"},
          records: [
            %TelemetryRecord{
              event_id: "axis-log-1",
              observed_time_unix_nano: 1_812_456_000_000_000_000,
              event_time_unix_nano: 1_812_456_000_000_000_000,
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTEL_LOG,
              payload: log,
              metadata: %{
                "serviceradar.signal_schema.producer_id" => "axis",
                "serviceradar.signal_schema.producer_version" => "0.1.0",
                "serviceradar.signal_schema.schema_id" => "com.carverauto.axis_camera.log",
                "serviceradar.signal_schema.schema_version" => "1.0.0",
                "serviceradar.signal_schema.display_contract_id" =>
                  "com.carverauto.axis_camera.log.display",
                "serviceradar.signal_schema.display_contract_version" => "1.0.0",
                "serviceradar.signal_schema.signal_type" => "log",
                "serviceradar.signal_schema.payload_kind" => "otel_log"
              }
            }
          ]
        })

      status = %{
        source: "plugin:axis-assignment",
        service_type: "plugin",
        service_name: "plugin-telemetry",
        agent_id: "agent-a",
        gateway_id: "gateway-a",
        partition: "prod-east",
        source_ip: "192.0.2.55",
        message: batch
      }

      assert :ok = StatusIngestor.ingest(status)

      assert_receive {:published, "logs.otel.plugin", payload}
      assert {:ok, decoded} = Jason.decode(payload)
      assert decoded["attributes"]["existing"] == "kept"
      assert decoded["attributes"]["service_radar"]["plugin_id"] == "axis-assignment"
      assert decoded["attributes"]["service_radar"]["signal_schema"]["payload_kind"] == "otel_log"
    end

    test "ignores malformed add-on telemetry messages without crashing" do
      status = %{
        source: "addon:powerdns",
        service_type: "native-addon",
        service_name: "addon-telemetry",
        agent_id: "agent-a",
        partition: "prod-east",
        message: <<255, 255, 255, 255>>
      }

      assert {:error, :addon_telemetry_decode_failed} = StatusIngestor.ingest(status)
    end

    test "package telemetry publish failures stay best-effort unless transport errors are requested" do
      attempts = :counters.new(1, [:atomics])

      Application.put_env(:serviceradar_core, StatusHandler,
        addon_telemetry_publisher: fn _subject, _payload ->
          :counters.add(attempts, 1, 1)
          {:error, :not_connected}
        end
      )

      status =
        addon_status_with([
          %TelemetryRecord{
            payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
            payload: ~s({"class_uid":4003,"message":"one"})
          },
          %TelemetryRecord{
            payload_kind: :TELEMETRY_PAYLOAD_KIND_OTEL_LOG,
            payload: ~s({"body":"two"})
          }
        ])

      assert :ok = StatusIngestor.ingest(status)
      assert :counters.get(attempts, 1) == 2

      :counters.put(attempts, 1, 0)

      assert {:error, :not_connected} =
               StatusIngestor.ingest(status, return_transport_errors: true)

      assert :counters.get(attempts, 1) == 1
    end

    test "an anomaly verdict publish failure stays best-effort unless transport errors are requested" do
      attempts = :counters.new(1, [:atomics])

      Application.put_env(:serviceradar_core, StatusHandler,
        addon_telemetry_publisher: fn _subject, _payload ->
          :counters.add(attempts, 1, 1)
          {:error, :not_connected}
        end
      )

      status =
        addon_status_with([
          %TelemetryRecord{
            payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
            payload: """
            {"class_uid":2004,"signal_type":"causal","event_type":"anomaly","anomaly":{"series_key":"sysmon:cpu:host-a:0"}}
            """
          },
          %TelemetryRecord{
            payload_kind: :TELEMETRY_PAYLOAD_KIND_OTEL_LOG,
            payload: ~s({"body":"after-verdict"})
          }
        ])

      assert :ok = StatusIngestor.ingest(status)
      assert :counters.get(attempts, 1) == 2

      :counters.put(attempts, 1, 0)

      assert {:error, :not_connected} =
               StatusIngestor.ingest(status, return_transport_errors: true)

      assert :counters.get(attempts, 1) == 1

      test_pid = self()

      Application.put_env(:serviceradar_core, StatusHandler,
        addon_telemetry_publisher: fn subject, payload ->
          send(test_pid, {:published, subject, payload})
          :ok
        end
      )

      assert :ok = StatusIngestor.ingest(status, return_transport_errors: true)

      assert_receive {:published, subject, payload}
      assert String.starts_with?(subject, "signals.analytics.predictions.")
      assert {:ok, decoded} = Jason.decode(payload)
      assert decoded["event_type"] == "anomaly"
      assert_receive {:published, "logs.otel.addon", _log}
    end
  end

  def stub_publish(subject, payload, fun) when is_function(fun, 2), do: fun.(subject, payload)

  def stub_publish(subject, payload, pid) when is_pid(pid) do
    send(pid, {:published, subject, payload})
    :ok
  end
end
