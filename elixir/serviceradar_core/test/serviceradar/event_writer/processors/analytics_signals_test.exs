defmodule ServiceRadar.EventWriter.Processors.AnalyticsSignalsTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.EventWriter.DeviceCorrelation
  alias ServiceRadar.EventWriter.DeviceCorrelationCache
  alias ServiceRadar.EventWriter.Pipeline
  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
  alias ServiceRadar.Observability.AnomalyDetection.SeriesKey
  alias ServiceRadar.Observability.CapacityForecasting.VerdictEmitter
  alias ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher

  defp seed_device_resolution(candidate, uid) do
    DeviceCorrelationCache.put(DeviceCorrelationCache.cache_key(candidate), uid)
  end

  defp seed_snmp_metric_resolution(candidate, uid) do
    key = DeviceCorrelation.snmp_interface_metric_cache_key(candidate)
    assert key
    DeviceCorrelationCache.put(key, uid)
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

  defp attach_unconfirmed_anomaly_telemetry(test_pid \\ self()) do
    handler_id = {__MODULE__, :unconfirmed_anomaly, make_ref()}

    :telemetry.attach(
      handler_id,
      [:serviceradar, :event_writer, :anomaly_detection, :unconfirmed_skipped],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:unconfirmed_anomaly, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defmodule ExistingTimeRepo do
    def query(sql, [ids]) do
      # Mirror the real DB: production binds 16-byte UUID binaries (Postgrex `uuid[]`)
      # and `SELECT id::text`, so canonicalize the bound binaries back to their string
      # identity before echoing/keying — same currency the result-map lookup uses.
      text_ids = Enum.map(ids, &Ecto.UUID.load!/1)
      send(Process.get(:causal_signals_test_pid), {:existing_time_query, sql, text_ids})

      rows =
        Enum.flat_map(text_ids, fn id ->
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
      assert AnalyticsSignals.table_name() == "ocsf_events"
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
        metadata: %{"signal_type" => "prediction", "event_type" => "capacity_forecast"},
        unmapped: %{}
      }

      assert [%{time: ^existing_time}] =
               AnalyticsSignals.align_existing_ocsf_event_times([row], ExistingTimeRepo)

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

      row = AnalyticsSignals.parse_message(message)

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

      row = AnalyticsSignals.parse_message(message)

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
          "signal_type" => "prediction",
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
          AnalyticsSignals.parse_message(%{
            data: Jason.encode!(payload),
            metadata: %{
              subject: "signals.analytics.predictions.sysmon:cpu:sr:anomaly-device:0",
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
        "signal_type" => "prediction",
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
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.analytics.predictions.sysmon:cpu:sr:anomaly-device:0",
            received_at: ~U[2026-06-12 12:00:00Z]
          }
        })

      assert %DateTime{} = row.time

      assert_receive {:timestamp_fallback,
                      [:serviceradar, :event_writer, :causal_signals, :timestamp_fallback],
                      %{count: 1}, %{subject_class: "analytics", reason: :malformed_timestamp}}
    end

    test "uses SNMP target IP as anomaly device identity when polling agent reports verdict" do
      target_ip = "10.0.0.20"
      target_device_uid = "sr:snmp-target-10-0-0-20"

      seed_snmp_metric_resolution(
        %{
          target_device_ip: target_ip,
          ip: target_ip,
          metric_name: "ifHCInOctets",
          if_index: 7
        },
        target_device_uid
      )

      payload = %{
        "event_id" => "snmp-target-anomaly",
        "signal_type" => "prediction",
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
          "metric_name" => "ifHCInOctets",
          "if_index" => 7,
          "state" => "anomaly_open",
          "target_device_ip" => target_ip
        },
        "source_identity" => %{
          "agent_id" => "agent-ns03",
          "host_id" => "ns03",
          "target_device_ip" => target_ip
        }
      }

      row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.analytics.predictions.snmp:#{target_ip}:7",
            received_at: DateTime.utc_now()
          }
        })

      assert row.device["uid"] == target_device_uid
      assert row.metadata["service_radar"]["device_uid"] == target_device_uid
      assert row.metadata["service_radar"]["device_id"] == target_device_uid
      assert row.metadata["service_radar"]["metric_name"] == "ifHCInOctets"
      assert row.metadata["service_radar"]["if_index"] == 7
      assert row.metadata["finding_info"]["dimensions"]["device_uid"] == target_device_uid
      assert row.metadata["finding_info"]["dimensions"]["device_id"] == target_device_uid
      assert row.metadata["finding_info"]["dimensions"]["series_key"] == "snmp:#{target_ip}:7"
      assert row.metadata["finding_info"]["dimensions"]["metric_name"] == "ifHCInOctets"
      assert row.metadata["finding_info"]["dimensions"]["if_index"] == 7
    end

    test "withholds SNMP anomaly verdicts when the polled target is missing" do
      attach_withheld_anomaly_telemetry()

      payload = %{
        "event_id" => "snmp-target-missing",
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_456_000_000,
        "severity_id" => 4,
        "device_uid" => "agent-dusk01",
        "agent_id" => "agent-dusk01",
        "anomaly" => %{
          "series_key" => "v2:class=snmp:identity=agent-dusk01:if_index=6",
          "metric_class" => "snmp",
          "state" => "anomaly_open"
        },
        "source_identity" => %{
          "agent_id" => "agent-dusk01",
          "host_id" => "dusk01"
        }
      }

      assert AnalyticsSignals.parse_message(%{
               data: Jason.encode!(payload),
               metadata: %{
                 subject: "signals.analytics.predictions.snmp.agent-dusk01.6",
                 received_at: DateTime.utc_now()
               }
             }) == nil

      assert_receive {:withheld_anomaly,
                      [:serviceradar, :event_writer, :anomaly_detection, :withheld], %{count: 1},
                      %{
                        reason: :snmp_target_missing,
                        metric_class: "snmp",
                        target_device_ip: nil
                      }}
    end

    test "withholds SNMP anomaly when only the target IP resolves but the metric tuple does not" do
      attach_withheld_anomaly_telemetry()
      target_ip = "10.0.0.25"

      seed_device_resolution(
        %{
          device_uid: target_ip,
          agent_id: nil,
          hostname: nil,
          ip: target_ip,
          partition: nil
        },
        "sr:target-without-interface-metric"
      )

      payload = %{
        "event_id" => "snmp-target-no-metric-tuple",
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_456_000_000,
        "severity_id" => 4,
        "device_uid" => "agent-dusk01",
        "agent_id" => "agent-dusk01",
        "target_device_ip" => target_ip,
        "anomaly" => %{
          "series_key" => "snmp:#{target_ip}:7",
          "metric_class" => "snmp.interface",
          "metric_name" => "ifHCInOctets",
          "if_index" => 7,
          "state" => "anomaly_open",
          "target_device_ip" => target_ip
        }
      }

      assert AnalyticsSignals.parse_message(%{
               data: Jason.encode!(payload),
               metadata: %{
                 subject: "signals.analytics.predictions.snmp:#{target_ip}:7",
                 received_at: DateTime.utc_now()
               }
             }) == nil

      assert_receive {:withheld_anomaly,
                      [:serviceradar, :event_writer, :anomaly_detection, :withheld], %{count: 1},
                      %{
                        reason: :snmp_interface_metric_unresolvable,
                        metric_class: "snmp.interface",
                        metric_name: "ifHCInOctets",
                        if_index: 7,
                        target_device_ip: ^target_ip
                      }}
    end

    test "accepts canonical SNMP target device identity without target IP" do
      seed_snmp_metric_resolution(
        %{
          device_uid: "sr:farm01",
          metric_name: "ifHCInOctets",
          if_index: 6
        },
        "sr:farm01"
      )

      payload = %{
        "event_id" => "snmp-canonical-target",
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_456_000_000,
        "severity_id" => 4,
        "device_uid" => "sr:farm01",
        "agent_id" => "agent-dusk01",
        "anomaly" => %{
          "series_key" => "v2:class=snmp.interface:identity=sr:farm01:if_index=6",
          "metric_class" => "snmp.interface",
          "metric_name" => "ifHCInOctets",
          "state" => "anomaly_open"
        },
        "source_identity" => %{
          "series_key" => "v2:class=snmp.interface:identity=sr:farm01:if_index=6",
          "metric_class" => "snmp.interface",
          "metric_name" => "ifHCInOctets",
          "device_id" => "sr:farm01",
          "agent_id" => "agent-dusk01",
          "tags" => %{"if_index" => "6"}
        }
      }

      row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.analytics.predictions.snmp.sr-farm01.6",
            received_at: DateTime.utc_now()
          }
        })

      assert row.device["uid"] == "sr:farm01"
      assert row.metadata["service_radar"]["device_uid"] == "sr:farm01"
      assert row.metadata["service_radar"]["device_id"] == "sr:farm01"
      assert row.metadata["service_radar"]["metric_name"] == "ifHCInOctets"
      assert row.metadata["service_radar"]["if_index"] == 6
      assert row.metadata["finding_info"]["dimensions"]["device_uid"] == "sr:farm01"
      assert row.metadata["finding_info"]["dimensions"]["device_id"] == "sr:farm01"
      assert row.metadata["finding_info"]["dimensions"]["metric_name"] == "ifHCInOctets"
      assert row.metadata["finding_info"]["dimensions"]["if_index"] == 6
    end

    test "SNMP anomaly metadata exposes the metric tuple even when metric series key differs" do
      target_ip = "10.0.0.30"
      target_device_uid = "sr:farm01"

      seed_snmp_metric_resolution(
        %{
          target_device_ip: target_ip,
          ip: target_ip,
          metric_name: "ifHCOutOctets",
          if_index: 4
        },
        target_device_uid
      )

      metric_tuple = %{
        "device_id" => target_device_uid,
        "metric_name" => "ifHCOutOctets",
        "if_index" => 4,
        "series_key" => "metric:#{target_device_uid}:ifHCOutOctets:4"
      }

      anomaly_series_key = "edge:v2:agent-dusk01:#{target_ip}:ifHCOutOctets:4"

      payload = %{
        "event_id" => "snmp-metric-tuple",
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_456_000_000,
        "severity_id" => 5,
        "device_uid" => "agent-dusk01",
        "agent_id" => "agent-dusk01",
        "target_device_ip" => target_ip,
        "anomaly" => %{
          "series_key" => anomaly_series_key,
          "metric_class" => "snmp.interface",
          "metric_name" => metric_tuple["metric_name"],
          "if_index" => metric_tuple["if_index"],
          "state" => "anomaly_open",
          "target_device_ip" => target_ip
        }
      }

      row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.analytics.predictions.#{anomaly_series_key}",
            received_at: DateTime.utc_now()
          }
        })

      dimensions = row.metadata["finding_info"]["dimensions"]

      assert row.device["uid"] == metric_tuple["device_id"]
      assert dimensions["device_id"] == metric_tuple["device_id"]
      assert dimensions["metric_name"] == metric_tuple["metric_name"]
      assert dimensions["if_index"] == metric_tuple["if_index"]
      refute dimensions["series_key"] == metric_tuple["series_key"]
    end

    test "returns nil on invalid JSON" do
      row =
        AnalyticsSignals.parse_message(%{
          data: "not-json",
          metadata: %{subject: "bmp.events.peer"}
        })

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

      row1 = AnalyticsSignals.parse_message(message)
      row2 = AnalyticsSignals.parse_message(message)

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
        metadata: %{subject: "signals.analytics.inventory.added", received_at: DateTime.utc_now()}
      }

      row = AnalyticsSignals.parse_message(message)
      replayed_row = AnalyticsSignals.parse_message(message)

      assert row
      assert row.id == replayed_row.id
      assert row.type_uid == 100_813
      assert row.metadata["signal_type"] == "inventory"
      assert row.metadata["primary_domain"] == "inventory"
      assert row.metadata["signal_domains"] == ["inventory"]
      assert row.metadata["event_type"] == "added"
      assert row.metadata["source"]["subject"] == "signals.analytics.inventory.added"

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
          subject: "signals.analytics.inventory.vulnerability_match",
          received_at: DateTime.utc_now()
        }
      }

      row = AnalyticsSignals.parse_message(message)

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

    test "accepts actionable assessment opens and lifecycle resolutions" do
      base = %{
        "event_id" => "endpoint-vulnerability-assessment:11111111-1111-4111-8111-111111111111",
        "signal_type" => "inventory",
        "event_type" => "vulnerability_assessment",
        "finding_type" => "vulnerability",
        "timestamp" => "2026-09-02T12:30:00Z",
        "device_uid" => "sr:test-device",
        "cve_id" => "CVE-2099-9001",
        "assessment_status" => "active",
        "assessment" => "confirmed",
        "disposition" => "affected",
        "status" => "open",
        "finding_status" => "open",
        "package" => %{"identity_key" => "pkgid:v1:test", "name" => "starling-fetch"}
      }

      open_row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(base),
          metadata: %{
            subject: "signals.analytics.inventory.vulnerability_assessment",
            received_at: DateTime.utc_now()
          }
        })

      assert open_row.status == "open"
      assert open_row.activity_id == 1
      assert open_row.activity_name == "Create"

      resolved_row =
        AnalyticsSignals.parse_message(%{
          data:
            Jason.encode!(%{
              base
              | "status" => "resolved",
                "finding_status" => "resolved",
                "disposition" => "fixed"
            }),
          metadata: %{
            subject: "signals.analytics.inventory.vulnerability_assessment",
            received_at: DateTime.utc_now()
          }
        })

      assert resolved_row.id == open_row.id
      assert resolved_row.status == "resolved"
      assert resolved_row.activity_id == 3
      assert resolved_row.activity_name == "Close"
      assert resolved_row.type_uid == 200_203
    end

    test "withholds a candidate assessment presented as an open finding" do
      payload = %{
        "event_id" => "endpoint-vulnerability-assessment:22222222-2222-4222-8222-222222222222",
        "signal_type" => "inventory",
        "event_type" => "vulnerability_assessment",
        "finding_type" => "vulnerability",
        "timestamp" => "2026-09-02T12:30:00Z",
        "device_uid" => "sr:test-device",
        "cve_id" => "CVE-2099-9002",
        "assessment_status" => "active",
        "assessment" => "candidate",
        "disposition" => "unknown",
        "status" => "open",
        "finding_status" => "open"
      }

      assert AnalyticsSignals.parse_message(%{
               data: Jason.encode!(payload),
               metadata: %{
                 subject: "signals.analytics.inventory.vulnerability_assessment",
                 received_at: DateTime.utc_now()
               }
             }) == nil
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
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.analytics.inventory.vulnerability_match",
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

      row = AnalyticsSignals.parse_message(message)

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

      row = AnalyticsSignals.parse_message(message)

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

      row = AnalyticsSignals.parse_message(message)

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

      row = AnalyticsSignals.parse_message(message)
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

      row = AnalyticsSignals.parse_message(message)

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

    test "canonicalizes mapped IPv4 BMP projections while retaining raw payload bytes" do
      payload = %{
        "time_received_ns" => "2026-07-15T18:00:01Z",
        "time_bmp_header_ns" => "2026-07-15T18:00:00Z",
        "router_addr" => "::ffff:10.42.57.39",
        "peer_addr" => "::ffff:169.254.0.179",
        "peer_asn" => 64_512,
        "prefix_addr" => "::ffff:10.43.73.194",
        "prefix_len" => 24,
        "announced" => true,
        "attrs" => %{"next_hop" => "::ffff:10.42.57.1"}
      }

      raw_data = Jason.encode!(payload)

      row =
        AnalyticsSignals.parse_message(%{
          data: raw_data,
          metadata: %{
            subject: "arancini.updates.v4_10_42_57_39.64512.1_1",
            received_at: DateTime.utc_now()
          }
        })

      assert row.metadata["source_identity"]["router_ip"] == "10.42.57.39"
      assert row.metadata["source_identity"]["peer_ip"] == "169.254.0.179"
      assert row.metadata["routing_correlation"]["router_id"] == "10.42.57.39"
      assert row.metadata["routing_correlation"]["router_ip"] == "10.42.57.39"
      assert row.metadata["routing_correlation"]["peer_ip"] == "169.254.0.179"
      assert row.metadata["routing_correlation"]["prefix"] == "10.43.73.194/24"
      assert row.src_endpoint["ip"] == "169.254.0.179"
      assert row.device["uid"] == "10.42.57.39"
      assert row.unmapped["router_addr"] == "10.42.57.39"
      assert row.unmapped["attrs"]["next_hop"] == "10.42.57.1"
      assert row.raw_data == raw_data
    end

    test "canonicalizes mapped IPv4 alternate fields on bmp.events subjects" do
      payload = %{
        "timestamp" => "2026-07-15T18:00:00Z",
        "routerId" => "::ffff:10.42.57.39",
        "routerIp" => "::ffff:10.42.57.39",
        "peerIp" => "::ffff:169.254.0.179",
        "peer_asn" => 64_512,
        "prefix" => "::ffff:10.43.73.194/24",
        "announced" => true
      }

      raw_data = Jason.encode!(payload)

      row =
        AnalyticsSignals.parse_message(%{
          data: raw_data,
          metadata: %{subject: "bmp.events.route_update", received_at: DateTime.utc_now()}
        })

      assert row.metadata["signal_type"] == "bmp"
      assert row.metadata["source_identity"]["router_id"] == "10.42.57.39"
      assert row.metadata["source_identity"]["router_ip"] == "10.42.57.39"
      assert row.metadata["source_identity"]["peer_ip"] == "169.254.0.179"
      assert row.metadata["routing_correlation"]["prefix"] == "10.43.73.194/24"
      assert row.raw_data == raw_data
    end

    test "canonicalizes mapped IPv4 for explicit BMP signal types on custom subjects" do
      payload = %{
        "signal_type" => "BMP",
        "timestamp" => "2026-07-15T18:00:00Z",
        "router_addr" => "::ffff:10.42.57.39",
        "peer_addr" => "::ffff:169.254.0.179",
        "peer_asn" => 64_512,
        "prefix_addr" => "::ffff:10.43.73.194",
        "prefix_len" => 24,
        "announced" => true
      }

      row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{subject: "vendor.routing.events", received_at: DateTime.utc_now()}
        })

      assert row.metadata["signal_type"] == "bmp"
      assert row.metadata["routing_correlation"]["router_ip"] == "10.42.57.39"
      assert row.metadata["routing_correlation"]["peer_ip"] == "169.254.0.179"
      assert row.metadata["routing_correlation"]["prefix"] == "10.43.73.194/24"
    end

    test "preserves genuine IPv6 BMP projections" do
      payload = %{
        "time_received_ns" => "2026-07-15T18:00:01Z",
        "time_bmp_header_ns" => "2026-07-15T18:00:00Z",
        "router_addr" => "2001:db8:1::39",
        "peer_addr" => "2001:db8:2::179",
        "peer_asn" => 64_512,
        "prefix_addr" => "2001:db8:3::",
        "prefix_len" => 64,
        "announced" => true,
        "attrs" => %{"next_hop" => "2001:db8:4::1"}
      }

      raw_data = Jason.encode!(payload)

      row =
        AnalyticsSignals.parse_message(%{
          data: raw_data,
          metadata: %{
            subject: "arancini.updates.v6_2001_db8_1_0_0_0_0_39.64512.2_1",
            received_at: DateTime.utc_now()
          }
        })

      assert row.metadata["source_identity"]["router_ip"] == "2001:db8:1::39"
      assert row.metadata["source_identity"]["peer_ip"] == "2001:db8:2::179"
      assert row.metadata["routing_correlation"]["router_id"] == "2001:db8:1::39"
      assert row.metadata["routing_correlation"]["prefix"] == "2001:db8:3::/64"
      assert row.src_endpoint["ip"] == "2001:db8:2::179"
      assert row.device["uid"] == "2001:db8:1::39"
      assert row.unmapped["attrs"]["next_hop"] == "2001:db8:4::1"
      assert row.raw_data == raw_data
    end

    test "preserves mapped-looking BMP values outside the canonical IPv4 contract" do
      invalid_ipv4 = "::ffff:999.999.999.999"
      invalid_cidr = "::ffff:10.42.57.39/64"

      payload = %{
        "time_received_ns" => "2026-07-15T18:00:01Z",
        "time_bmp_header_ns" => "2026-07-15T18:00:00Z",
        "router_addr" => invalid_ipv4,
        "peer_addr" => invalid_cidr,
        "peer_asn" => 64_512,
        "prefix_addr" => "::ffff:10.43.73.194",
        "prefix_len" => 24,
        "announced" => true,
        "attrs" => %{"next_hop" => invalid_cidr}
      }

      raw_data = Jason.encode!(payload)

      row =
        AnalyticsSignals.parse_message(%{
          data: raw_data,
          metadata: %{
            subject: "arancini.updates.v4_10_42_57_39.64512.1_1",
            received_at: DateTime.utc_now()
          }
        })

      assert row.unmapped["router_addr"] == invalid_ipv4
      assert row.unmapped["peer_addr"] == invalid_cidr
      assert row.unmapped["attrs"]["next_hop"] == invalid_cidr
      assert row.raw_data == raw_data
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

      row = AnalyticsSignals.parse_message(message)

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

      assert AnalyticsSignals.parse_message(message) == nil
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

      row = AnalyticsSignals.parse_message(message)

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
              metadata: %{subject: "signals.analytics.overlay", received_at: DateTime.utc_now()},
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

    test "analytics prediction subjects route to the declared analytics_predictions batcher" do
      event = %{
        data: Jason.encode!(%{"signal_type" => "prediction", "event_type" => "anomaly"}),
        metadata: %{
          subject: "signals.analytics.predictions.sysmon:memory:host-a",
          received_at: DateTime.utc_now()
        },
        ack_data: %{}
      }

      message = Pipeline.transform(event, [])
      routed = Pipeline.handle_message(:default, message, %{})
      assert routed.batcher == :analytics_predictions
    end
  end

  describe "alert evaluation rows" do
    test "selects anomaly causal prediction findings for stateful alert evaluation" do
      payload = %{
        "event_id" => "anomaly-alert-1",
        "signal_type" => "prediction",
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
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.analytics.predictions.sysmon:memory:sr:anomaly-device",
            received_at: DateTime.utc_now()
          }
        })

      assert row.class_uid == 2004
      assert row.metadata["signal_type"] == "prediction"
      assert row.metadata["event_type"] == "anomaly"

      assert [alert_row] = AnalyticsSignals.alert_evaluation_rows([row])
      assert alert_row.id == row.metadata["event_identity"]
      assert alert_row.device == %{"uid" => "sr:anomaly-device"}
    end

    test "canonicalizes legacy causal anomaly findings before stateful alert matching" do
      match = %{
        "subject_prefix" => "signals.analytics.predictions",
        "attribute_equals" => %{
          "signal_type" => "prediction",
          "event_type" => ["anomaly", "anomaly_detection"],
          "anomaly.state" => ["anomaly_open", "anomaly_drift_open", "open", "anomalous"]
        },
        "recovery" => %{
          "subject_prefix" => "signals.analytics.predictions",
          "attribute_equals" => %{
            "signal_type" => "prediction",
            "event_type" => ["anomaly", "anomaly_detection"],
            "anomaly.state" => ["anomaly_clear", "anomaly_drift_clear", "clear", "cleared"]
          }
        }
      }

      open_row =
        legacy_anomaly_row("legacy-causal-open", "anomaly_drift_open")

      assert open_row.class_uid == 2004
      assert open_row.metadata["signal_type"] == "prediction"
      assert open_row.metadata["event_type"] == "anomaly"
      assert open_row.unmapped["signal_type"] == "causal"

      assert [open_alert_row] = AnalyticsSignals.alert_evaluation_rows([open_row])
      assert open_alert_row.unmapped["signal_type"] == "prediction"

      assert RuleMatcher.rule_matches_event?(
               open_alert_row,
               %{match: match}
             )

      clear_row =
        legacy_anomaly_row("legacy-causal-drift-clear", "anomaly_drift_clear")

      assert [clear_alert_row] = AnalyticsSignals.alert_evaluation_rows([clear_row])
      assert clear_alert_row.unmapped["signal_type"] == "prediction"

      assert RuleMatcher.rule_recovers_event?(
               clear_alert_row,
               %{match: match}
             )
    end

    test "carries the verdict_source label into service_radar metadata for the edge<->central join" do
      edge = %{
        "event_id" => "anomaly-edge-1",
        "signal_type" => "prediction",
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
        subject: "signals.analytics.predictions.sysmon:cpu:sr:anomaly-device",
        received_at: DateTime.utc_now()
      }

      row = AnalyticsSignals.parse_message(%{data: Jason.encode!(edge), metadata: meta})

      assert row.metadata["service_radar"]["verdict_source"] == "edge-spike"
      assert row.metadata["detection_finding"]["source"] == "edge-spike"

      # A central verdict (no label) defaults to "central".
      central_row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(Map.delete(edge, "verdict_source")),
          metadata: meta
        })

      assert central_row.metadata["service_radar"]["verdict_source"] == "central"
    end

    test "stores edge and central verdicts under the same canonical series key after device re-key" do
      raw_device = "raw-worker-join-key"
      agent_id = "agent-join-key"
      partition = "prod-east"
      canonical_device = "sr:join-key-device"

      seed_device_resolution(
        %{
          device_uid: raw_device,
          agent_id: agent_id,
          hostname: raw_device,
          ip: nil,
          partition: partition
        },
        canonical_device
      )

      source_identity = %{
        "series_key" => "edge-producer-provisional-key",
        "metric_class" => "sysmon.cpu",
        "metric_name" => "cpu.usage_percent",
        "partition" => partition,
        "agent_id" => agent_id,
        "host_id" => raw_device,
        "device_id" => raw_device,
        "tags" => %{"core_id" => "6"}
      }

      canonical_series_key =
        source_identity
        |> Map.put("device_id", canonical_device)
        |> SeriesKey.from_source_identity()

      refute canonical_series_key == source_identity["series_key"]

      edge = %{
        "event_id" => "anomaly-edge-join-key",
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "device_uid" => raw_device,
        "agent_id" => agent_id,
        "hostname" => raw_device,
        "partition" => partition,
        "verdict_source" => "edge-spike",
        "source_identity" => source_identity,
        "anomaly" => %{
          "series_key" => source_identity["series_key"],
          "metric_class" => "sysmon.cpu",
          "metric_name" => "cpu.usage_percent",
          "state" => "anomaly_open"
        }
      }

      central =
        edge
        |> Map.put("event_id", "anomaly-central-join-key")
        |> Map.put("device_uid", canonical_device)
        |> Map.put("verdict_source", "central-seasonal")
        |> Map.delete("source_identity")
        |> put_in(["anomaly", "series_key"], canonical_series_key)

      edge_row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(edge),
          metadata: %{
            subject: "signals.analytics.predictions.#{source_identity["series_key"]}",
            received_at: DateTime.utc_now()
          }
        })

      central_row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(central),
          metadata: %{
            subject: "signals.analytics.predictions.#{canonical_series_key}",
            received_at: DateTime.utc_now()
          }
        })

      assert edge_row.device["uid"] == canonical_device
      assert edge_row.metadata["service_radar"]["device_uid"] == canonical_device

      for row <- [edge_row, central_row] do
        assert row.metadata["service_radar"]["series_key"] == canonical_series_key
        assert row.metadata["security_signal"]["series_key"] == canonical_series_key
        assert row.metadata["detection_finding"]["series_key"] == canonical_series_key
        assert row.metadata["finding_info"]["dimensions"]["series_key"] == canonical_series_key
        assert row.metadata["finding_info"]["dimensions"]["device_uid"] == canonical_device
      end

      assert edge_row.metadata["service_radar"]["finding_uid"] ==
               central_row.metadata["service_radar"]["finding_uid"]
    end

    test "overwrites stale edge finding_info with canonical device and series identity" do
      edge = %{
        "event_id" => "anomaly-edge-stale-finding-info",
        "signal_type" => "prediction",
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
        subject: "signals.analytics.predictions.canonical-series-key",
        received_at: DateTime.utc_now()
      }

      stale_row = AnalyticsSignals.parse_message(%{data: Jason.encode!(edge), metadata: meta})

      canonical_row =
        AnalyticsSignals.parse_message(%{
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

    test "preserves edge anomaly episode window and peak metadata" do
      payload = %{
        "event_id" => "anomaly-edge-episode-context",
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "time" => 1_812_456_040_000,
        "severity_id" => 4,
        "device_uid" => "sr:host-a",
        "verdict_source" => "edge-spike",
        "anomaly" => %{
          "series_key" => "cpu-series-a",
          "metric_class" => "sysmon.cpu",
          "metric_name" => "cpu.usage_percent",
          "state" => "anomaly_open",
          "detector_state" => "anomalous",
          "score" => 6.2,
          "baseline_count" => 30,
          "consecutive_anomalous" => 8,
          "signals" => [
            %{
              "name" => "rolling_zscore",
              "enabled" => true,
              "ready" => true,
              "breached" => true,
              "score" => 6.2,
              "threshold" => 3.0,
              "sample_count" => 300,
              "mean" => 10.4,
              "stddev" => 12.5,
              "reason" => "rolling_zscore breach"
            }
          ],
          "sample_value" => 88.0,
          "observed_at_unix_nano" => 1_812_456_040_000_000_000,
          "episode_started_at_unix_nano" => 1_812_456_010_000_000_000,
          "episode_ended_at_unix_nano" => 1_812_456_040_000_000_000,
          "episode_peak_value" => 97.7,
          "episode_peak_at_unix_nano" => 1_812_456_022_000_000_000
        }
      }

      row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.analytics.predictions.cpu-series-a",
            received_at: DateTime.utc_now()
          }
        })

      dimensions = row.metadata["finding_info"]["dimensions"]

      assert row.metadata["service_radar"]["verdict_source"] == "edge-spike"
      assert row.metadata["detection_finding"]["score"] == 6.2
      assert row.metadata["detection_finding"]["consecutive_anomalous"] == 8
      assert [signal] = row.metadata["detection_finding"]["signals"]
      assert signal["name"] == "rolling_zscore"
      assert signal["threshold"] == 3.0
      assert signal["sample_count"] == 300
      assert dimensions["detector_state"] == "anomalous"
      assert dimensions["score"] == 6.2
      assert dimensions["baseline_count"] == 30
      assert dimensions["consecutive_anomalous"] == 8
      assert [dimension_signal] = dimensions["signals"]
      assert dimension_signal["name"] == "rolling_zscore"
      assert dimension_signal["mean"] == 10.4
      assert dimension_signal["stddev"] == 12.5
      assert dimensions["sample_value"] == 88.0
      assert dimensions["observed_at_unix_nano"] == 1_812_456_040_000_000_000
      assert dimensions["episode_started_at_unix_nano"] == 1_812_456_010_000_000_000
      assert dimensions["episode_ended_at_unix_nano"] == 1_812_456_040_000_000_000
      assert dimensions["episode_peak_value"] == 97.7
      assert dimensions["episode_peak_at_unix_nano"] == 1_812_456_022_000_000_000
    end

    test "uses structured anomaly dimensions for titles when series keys are opaque" do
      target_ip = "192.0.2.20"

      seed_snmp_metric_resolution(
        %{
          target_device_ip: target_ip,
          ip: target_ip,
          metric_name: "ifHCInOctets",
          if_index: 7
        },
        "sr:opaque-snmp-target"
      )

      opaque_series_key =
        "v2|partition=64656661756c74|identity=31302e302e302e3230|metric=69664843496e4f6374657473"

      payload = %{
        "event_id" => "anomaly-edge-opaque-series-key",
        "signal_type" => "prediction",
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
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.analytics.predictions.#{opaque_series_key}",
            received_at: DateTime.utc_now()
          }
        })

      finding_info = row.metadata["finding_info"]
      dimensions = finding_info["dimensions"]

      assert finding_info["title"] ==
               "Anomaly detection: ifHCInOctets 192.0.2.20 uplink0 ifIndex 7"

      refute finding_info["title"] =~ "v2|"
      assert dimensions["series_key"] == opaque_series_key
      assert dimensions["metric_name"] == "ifHCInOctets"
      assert dimensions["target_device_ip"] == target_ip
      assert dimensions["interface_name"] == "uplink0"
      assert dimensions["if_index"] == 7
      assert dimensions["resource_label"] == "192.0.2.20 uplink0 ifIndex 7"
    end

    test "withholds future versioned opaque SNMP series keys when target is unresolved" do
      opaque_series_key =
        "v3:partition=64656661756c74:class=736e6d702e696e74657266616365:identity=31302e302e302e3230"

      payload = %{
        "event_id" => "anomaly-edge-future-opaque-series-key",
        "signal_type" => "prediction",
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

      row =
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(payload),
          metadata: %{
            subject: "signals.analytics.predictions.#{opaque_series_key}",
            received_at: DateTime.utc_now()
          }
        })

      assert row == nil
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
        AnalyticsSignals.parse_message(%{
          data: Jason.encode!(VerdictEmitter.payload(forecast, subject)),
          metadata: %{subject: subject, received_at: forecast.forecasted_at}
        })

      assert row.class_uid == 2004
      assert row.metadata["signal_type"] == "prediction"
      assert row.metadata["event_type"] == "capacity_forecast"
      assert row.metadata["security_signal"]["source"] == "capacity_forecasting"
      assert row.metadata["service_radar"]["source_type"] == "capacity_forecasting"
      assert row.metadata["service_radar"]["addon_id"] == "capacity-forecasting"
      assert row.metadata["detection_finding"]["type"] == "capacity_forecast"
      assert row.log_provider == "capacity_forecasting"

      assert [alert_row] = AnalyticsSignals.alert_evaluation_rows([row])
      assert alert_row.id == row.metadata["event_identity"]
    end

    test "does not select generic causal overlay events for stateful alert evaluation" do
      row = %{
        id: Ecto.UUID.generate(),
        class_uid: 1008,
        metadata: %{"signal_type" => "bmp", "event_type" => "route_update"},
        unmapped: %{}
      }

      assert [] = AnalyticsSignals.alert_evaluation_rows([row])
    end
  end

  describe "anomaly confirmation gate" do
    test "routes legacy causal-typed anomaly payloads through detection finding builder" do
      message =
        anomaly_gate_message(
          %{
            "state" => "anomaly_open",
            "detector_state" => "anomalous",
            "consecutive_anomalous" => 5,
            "confirm_slots" => 5
          },
          %{
            "signal_type" => "causal",
            "class_uid" => 1008
          }
        )

      row = AnalyticsSignals.parse_message(message)

      assert row
      assert row.class_uid == 2004
      assert row.type_uid == 200_401
      assert row.log_provider == "anomaly_detection"
      assert row.metadata["signal_type"] == "prediction"
      assert row.unmapped["signal_type"] == "causal"
      assert row.metadata["detection_finding"]["type"] == "anomaly"
    end

    test "does not let legacy causal pending anomaly breadcrumbs fall through to class 1008" do
      attach_unconfirmed_anomaly_telemetry()

      message =
        anomaly_gate_message(
          %{
            "state" => "pending_anomaly",
            "detector_state" => "pending_anomaly",
            "consecutive_anomalous" => 1,
            "confirm_slots" => 5
          },
          %{
            "signal_type" => "causal",
            "class_uid" => 1008
          }
        )

      assert AnalyticsSignals.parse_message(message) == nil

      assert_receive {:unconfirmed_anomaly,
                      [:serviceradar, :event_writer, :anomaly_detection, :unconfirmed_skipped],
                      %{count: 1}, %{state: "pending_anomaly"}}
    end

    test "withholds unconfirmed pending anomaly breadcrumbs" do
      attach_unconfirmed_anomaly_telemetry()

      message =
        anomaly_gate_message(%{
          "state" => "pending_anomaly",
          "detector_state" => "pending_anomaly",
          "consecutive_anomalous" => 1,
          "confirm_slots" => 5
        })

      assert AnalyticsSignals.parse_message(message) == nil

      assert_receive {:unconfirmed_anomaly,
                      [:serviceradar, :event_writer, :anomaly_detection, :unconfirmed_skipped],
                      %{count: 1},
                      %{
                        detector_state: "pending_anomaly",
                        state: "pending_anomaly",
                        consecutive_anomalous: 1,
                        metric_class: "sysmon.cpu"
                      }}
    end

    test "withholds breaching slots below confirm_slots even with an open lifecycle state" do
      message =
        anomaly_gate_message(%{
          "state" => "anomaly_open",
          "consecutive_anomalous" => 1,
          "confirm_slots" => 5
        })

      assert AnalyticsSignals.parse_message(message) == nil
    end

    test "withholds breach-pending reasons even when producer claims open state" do
      attach_unconfirmed_anomaly_telemetry()

      message =
        anomaly_gate_message(%{
          "state" => "anomaly_open",
          "detector_state" => "anomalous",
          "reason" => "breach pending: 1/5 slots",
          "consecutive_anomalous" => 5,
          "confirm_slots" => 5
        })

      assert AnalyticsSignals.parse_message(message) == nil

      assert_receive {:unconfirmed_anomaly,
                      [:serviceradar, :event_writer, :anomaly_detection, :unconfirmed_skipped],
                      %{count: 1}, %{state: "anomaly_open"}}
    end

    test "surfaces confirmed anomalies and keeps the producer severity" do
      message =
        anomaly_gate_message(%{
          "state" => "anomaly_open",
          "detector_state" => "anomalous",
          "consecutive_anomalous" => 5,
          "confirm_slots" => 5
        })

      row = AnalyticsSignals.parse_message(message)

      assert row
      assert row.class_uid == 2004
      assert row.severity_id == 4
      assert row.severity == "High"
      assert row.metadata["finding_info"]["dimensions"]["detector_state"] == "anomalous"
      assert row.raw_data == nil
      assert row.unmapped["anomaly"]["series_key"] == "sysmon:cpu:sr:anomaly-device"
    end

    test "surfaces a confirmed flap reopen as an anomaly update" do
      message =
        anomaly_gate_message(%{
          "state" => "anomaly_update",
          "detector_state" => "anomalous",
          "consecutive_anomalous" => 5,
          "confirm_slots" => 5
        })

      row = AnalyticsSignals.parse_message(message)

      assert row.class_uid == 2004
      assert row.unmapped["anomaly"]["state"] == "anomaly_update"
    end

    test "surfaces a confirmed drift heartbeat update" do
      message =
        anomaly_gate_message(%{
          "state" => "anomaly_drift_update",
          "detector_state" => "anomalous",
          "consecutive_anomalous" => 5,
          "confirm_slots" => 5,
          "detector_method" => "cusum_drift"
        })

      row = AnalyticsSignals.parse_message(message)

      assert row.class_uid == 2004
      assert row.unmapped["anomaly"]["state"] == "anomaly_drift_update"
    end

    test "surfaces anomaly_clear resolutions so confirmed findings can be closed" do
      message =
        anomaly_gate_message(
          %{
            "state" => "anomaly_clear",
            "detector_state" => "inactive"
          },
          %{"severity_id" => 2, "status" => "inactive"}
        )

      row = AnalyticsSignals.parse_message(message)

      assert row
      assert row.class_uid == 2004
      assert row.severity_id == 2
    end

    test "clamps unconfirmed severity to Low and preserves confirmed severity" do
      pending = %{
        "anomaly" => %{
          "metric_class" => "sysmon.cpu",
          "state" => "pending_anomaly",
          "detector_state" => "pending_anomaly",
          "consecutive_anomalous" => 1,
          "confirm_slots" => 5
        }
      }

      confirmed = %{
        "anomaly" => %{
          "metric_class" => "sysmon.cpu",
          "state" => "anomaly_open",
          "detector_state" => "anomalous",
          "consecutive_anomalous" => 5,
          "confirm_slots" => 5
        }
      }

      assert AnalyticsSignals.anomaly_detection_severity_id(%{"severity_id" => 4}, pending) == 2
      assert AnalyticsSignals.anomaly_detection_severity_id(%{"severity_id" => 5}, pending) == 2
      assert AnalyticsSignals.anomaly_detection_severity_id(%{"severity_id" => 4}, confirmed) == 4
    end

    test "caps edge drift below Critical and breach-pending severity to Low" do
      edge_drift =
        anomaly_payload(%{
          "state" => "anomaly_open",
          "detector_state" => "anomalous",
          "consecutive_anomalous" => 5,
          "confirm_slots" => 5,
          "detector_method" => "cusum_drift"
        })

      breach_pending =
        anomaly_payload(%{
          "state" => "anomaly_open",
          "detector_state" => "anomalous",
          "reason" => "breach pending: 1/5 slots",
          "consecutive_anomalous" => 5,
          "confirm_slots" => 5
        })

      assert AnalyticsSignals.anomaly_detection_severity_id(%{"severity_id" => 5}, edge_drift) ==
               4

      assert AnalyticsSignals.anomaly_detection_severity_id(
               %{"severity_id" => 5},
               breach_pending
             ) == 2

      row =
        AnalyticsSignals.parse_message(
          anomaly_gate_message(
            %{
              "state" => "anomaly_open",
              "detector_state" => "anomalous",
              "consecutive_anomalous" => 5,
              "confirm_slots" => 5,
              "detector_method" => "cusum_drift"
            },
            %{"severity_id" => 5, "verdict_source" => "edge-drift"}
          )
        )

      assert row.severity_id == 4
      assert row.severity == "High"
    end
  end

  defp anomaly_payload(anomaly, overrides \\ %{}) do
    Map.merge(
      %{
        "event_id" => "anomaly-gate-#{System.unique_integer([:positive])}",
        "signal_type" => "prediction",
        "event_type" => "anomaly",
        "class_uid" => 2004,
        "timestamp" => "2026-06-12T12:00:00Z",
        "severity_id" => 4,
        "device_uid" => "sr:anomaly-device",
        "verdict_source" => "edge-spike",
        "anomaly" =>
          Map.merge(
            %{
              "series_key" => "sysmon:cpu:sr:anomaly-device",
              "metric_class" => "sysmon.cpu",
              "score" => 4.82
            },
            anomaly
          )
      },
      overrides
    )
  end

  defp anomaly_gate_message(anomaly, overrides \\ %{}) do
    payload = anomaly_payload(anomaly, overrides)

    %{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.predictions.sysmon:cpu:sr:anomaly-device",
        received_at: DateTime.utc_now()
      }
    }
  end

  defp legacy_anomaly_row(event_id, state) do
    payload = %{
      "event_id" => event_id,
      "signal_type" => "causal",
      "event_type" => "anomaly",
      "class_uid" => 2004,
      "timestamp" => "2026-06-12T12:00:00Z",
      "severity_id" => 4,
      "device_uid" => "sr:legacy-anomaly-device",
      "anomaly" => %{
        "series_key" => "sysmon:cpu:sr:legacy-anomaly-device",
        "metric_class" => "sysmon.cpu",
        "state" => state
      }
    }

    AnalyticsSignals.parse_message(%{
      data: Jason.encode!(payload),
      metadata: %{
        subject: "signals.analytics.predictions.sysmon:cpu:sr:legacy-anomaly-device",
        received_at: DateTime.utc_now()
      }
    })
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

      assert routed.batcher in [
               :bmp_causal,
               :arancini_causal,
               :siem_causal,
               :analytics_predictions
             ]

      routed
    end)
  end

  defp parse_causal_rows(messages) do
    messages
    |> Enum.map(fn message ->
      AnalyticsSignals.parse_message(%{data: message.data, metadata: message.metadata})
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
