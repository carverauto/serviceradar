defmodule ServiceRadar.StatusHandlerTest do
  use ExUnit.Case, async: false

  alias Netprobepb.FlowAttributionEvent
  alias Netprobepb.FlowAttributionEventBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Agent.Addon.V1.TelemetrySource
  alias ServiceRadar.StatusHandler

  setup do
    existing = Process.whereis(ServiceRadar.ResultsRouter)

    if is_pid(existing) do
      Process.unregister(ServiceRadar.ResultsRouter)
    end

    on_exit(fn ->
      if is_pid(existing) do
        Process.register(existing, ServiceRadar.ResultsRouter)
      else
        if Process.whereis(ServiceRadar.ResultsRouter) do
          Process.unregister(ServiceRadar.ResultsRouter)
        end
      end
    end)

    :ok
  end

  test "routes sync results through ResultsRouter when available" do
    parent = self()

    router_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:results_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(router_pid, ServiceRadar.ResultsRouter)

    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([%{"device_id" => "dev-1"}])
    }

    assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})
    assert_receive {:forwarded, ^status}
  end

  test "returns results router acknowledgement on synchronous status update" do
    parent = self()

    router_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:results_update, status}} ->
            send(parent, {:forwarded, status})

            GenServer.reply(
              from,
              {:ok, %{directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}}}
            )
        end
      end)

    Process.register(router_pid, ServiceRadar.ResultsRouter)

    status = %{
      source: "results",
      service_type: "endpoint_inventory",
      service_name: "endpoint_inventory",
      message: Jason.encode!(%{"scan_id" => "scan-1"})
    }

    assert {:reply, {:ok, %{directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}}},
            %{}} =
             StatusHandler.handle_call({:status_update, status}, self(), %{})

    assert_receive {:forwarded, ^status}
  end

  test "rejects all metric-only sources before ResultsRouter when they reach core" do
    parent = self()

    router_pid =
      spawn(fn ->
        metric_router_loop(parent)
      end)

    Process.register(router_pid, ServiceRadar.ResultsRouter)

    for source <- [
          "sysmon-metrics",
          "snmp-metrics",
          "icmp-metrics",
          "rperf-metrics",
          "mtr-metrics",
          "sweep-metrics"
        ] do
      status = %{
        source: source,
        service_type: "metrics",
        service_name: source,
        message: <<10, 0>>
      }

      assert {:reply, {:error, {:gateway_metric_status_not_core_routable, ^source}}, %{}} =
               StatusHandler.handle_call({:status_update, status}, self(), %{})

      refute_receive {:forwarded, ^status}, 20
    end
  end

  test "rejects metric-only sources when ResultsRouter is unavailable" do
    for source <- [
          "sysmon-metrics",
          "snmp-metrics",
          "icmp-metrics",
          "rperf-metrics",
          "mtr-metrics",
          "sweep-metrics"
        ] do
      status = %{
        source: source,
        service_type: "metrics",
        service_name: source,
        message: <<10, 0>>
      }

      assert {:reply, {:error, {:gateway_metric_status_not_core_routable, ^source}}, %{}} =
               StatusHandler.handle_call({:status_update, status}, self(), %{})
    end
  end

  describe "flow-attribution source" do
    setup do
      original = Application.get_env(:serviceradar_core, StatusHandler, [])

      Application.put_env(:serviceradar_core, StatusHandler,
        flow_attribution_persister: {__MODULE__, :persist_flow_attribution, [self()]}
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

    test "decodes FlowAttributionEventBatch and persists events directly" do
      batch =
        FlowAttributionEventBatch.encode(%FlowAttributionEventBatch{
          events: [
            %FlowAttributionEvent{
              local_ip: "10.0.0.1",
              local_port: 5000,
              remote_ip: "10.0.0.2",
              remote_port: 80,
              transport_protocol: "TCP",
              pid: 1,
              comm: "curl"
            }
          ],
          dropped_since_last: 0
        })

      status = %{
        source: "flow-attribution",
        service_type: "passive-netprobe",
        service_name: "flow-attribution",
        agent_id: "agent-a",
        partition: "prod-east",
        message: batch
      }

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

      assert_receive {:flow_attribution_persisted, events, "prod-east", "agent-a"}
      assert [%FlowAttributionEvent{comm: "curl"}] = events
    end

    test "ignores malformed flow-attribution messages without crashing" do
      status = %{
        source: "flow-attribution",
        service_type: "passive-netprobe",
        service_name: "flow-attribution",
        agent_id: "agent-a",
        partition: "prod-east",
        message: <<255, 255, 255, 255>>
      }

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})
    end
  end

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

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

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

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

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

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

      assert_receive {:published, "pdns.ocsf", payload}
      assert {:ok, decoded} = Jason.decode(payload)
      refute Map.has_key?(decoded["metadata"]["service_radar"], "signal_schema")
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

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

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

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

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

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})
    end
  end

  def persist_flow_attribution(events, partition_id, agent_id, pid) do
    send(pid, {:flow_attribution_persisted, events, partition_id, agent_id})
    :ok
  end

  def stub_publish(subject, payload, fun) when is_function(fun, 2), do: fun.(subject, payload)

  def stub_publish(subject, payload, pid) when is_pid(pid) do
    send(pid, {:published, subject, payload})
    :ok
  end

  defp metric_router_loop(parent) do
    receive do
      {:"$gen_call", from, {:results_update, %{source: source} = status}} ->
        send(parent, {:forwarded, status})
        GenServer.reply(from, {:error, {:gateway_metric_status_not_core_routable, source}})
        metric_router_loop(parent)
    end
  end
end
