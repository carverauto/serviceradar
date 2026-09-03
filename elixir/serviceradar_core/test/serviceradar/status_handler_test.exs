defmodule ServiceRadar.StatusHandlerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Admission.FlowLane
  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Agent.Addon.V1.TelemetrySource
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  alias Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch
  alias ServiceRadar.Observability.CausalPredictionSubject
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

  test "retained plugin admission compatibility gate defaults to the legacy path" do
    original = Application.get_env(:serviceradar_core, StatusHandler)
    Application.put_env(:serviceradar_core, StatusHandler, [])
    on_exit(fn -> restore_env(StatusHandler, original) end)

    status = %{
      source: "plugin-result",
      service_type: "plugin",
      delivery_capabilities: ["plugin-result-retained:v1"],
      message: Jason.encode!(%{"status" => "OK"})
    }

    assert {:reply, :ok, %{}} =
             StatusHandler.handle_call({:status_update, status}, self(), %{})
  end

  test "endpoint inventory admission bypasses a busy ResultsRouter" do
    parent = self()

    router_pid =
      spawn(fn ->
        receive do
          _message -> Process.sleep(:infinity)
        end
      end)

    Process.register(router_pid, ServiceRadar.ResultsRouter)
    queue_pid = start_endpoint_inventory_queue(parent)
    configure_endpoint_inventory_queue(queue_pid)

    status = %{
      source: "results",
      service_type: "endpoint_inventory",
      service_name: "endpoint_inventory",
      agent_id: "agent-1",
      message: Jason.encode!(%{"scan_id" => "scan-1"})
    }

    reply_ref = make_ref()

    assert {:noreply, %{}} =
             StatusHandler.handle_call({:status_update, status}, {self(), reply_ref}, %{})

    assert_receive {:endpoint_inventory_admitted,
                    %{"agent_id" => "agent-1", "scan_id" => "scan-1"}}

    assert_receive {^reply_ref,
                    {:ok, %{directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}}}},
                   500

    assert Process.alive?(router_pid)
    Process.exit(router_pid, :kill)
  end

  test "returns an error when endpoint inventory queue admission times out" do
    queue_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:enqueue, _payload, _opts, _mode, _timeout}} ->
            Process.sleep(:infinity)
        end
      end)

    configure_endpoint_inventory_queue(queue_pid, 10)

    status = %{
      source: "results",
      service_type: "endpoint_inventory",
      service_name: "endpoint_inventory",
      message: Jason.encode!(%{"scan_id" => "scan-timeout"})
    }

    assert {:reply, {:error, :endpoint_inventory_ingest_queue_timeout}, %{}} =
             StatusHandler.handle_call({:status_update, status}, self(), %{})

    assert Process.alive?(queue_pid)
    Process.exit(queue_pid, :kill)
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
      task_supervisor = start_supervised!({Task.Supervisor, []})

      lane =
        start_supervised!(
          {FlowLane,
           name: unique_name(:flow_lane),
           task_supervisor: task_supervisor,
           config: [
             max_items: 16,
             max_bytes: 64 * 1_024 * 1_024,
             max_items_per_agent: 4,
             queue_wait_ms: 100,
             worker_timeout_ms: 1_000,
             gateway_call_timeout_ms: 4_100
           ]}
        )

      Application.put_env(:serviceradar_core, StatusHandler,
        flow_attribution_persister: {__MODULE__, :persist_flow_attribution, [self()]},
        flow_lane: lane
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

    test "returns a synchronous failure when flow attribution persistence fails" do
      original = Application.get_env(:serviceradar_core, StatusHandler, [])

      Application.put_env(
        :serviceradar_core,
        StatusHandler,
        Keyword.put(
          original,
          :flow_attribution_persister,
          {__MODULE__, :persist_flow_attribution_result, [self(), {:error, :deadlock_exhausted}]}
        )
      )

      on_exit(fn -> Application.put_env(:serviceradar_core, StatusHandler, original) end)

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
          ]
        })

      status = %{
        source: "flow-attribution",
        service_type: "passive-netprobe",
        service_name: "flow-attribution",
        agent_id: "agent-a",
        partition: "prod-east",
        message: batch
      }

      assert {:error, :deadlock_exhausted} = admit_status(status)

      assert_receive {:flow_attribution_persisted, _events, "prod-east", "agent-a"}
    end

    test "emits dropped-event telemetry only after a failed prefix retry persists" do
      {:ok, attempt_counter} = Agent.start_link(fn -> 0 end)

      Application.put_env(
        :serviceradar_core,
        StatusHandler,
        Keyword.put(
          Application.get_env(:serviceradar_core, StatusHandler, []),
          :flow_attribution_persister,
          {__MODULE__, :persist_flow_attribution_fail_once, [self(), attempt_counter]}
        )
      )

      handler_id = {__MODULE__, self(), make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:serviceradar, :event_writer, :attributed_flow, :batch_received],
          &__MODULE__.forward_flow_attribution_telemetry/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

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
          dropped_since_last: 9
        })

      status = %{
        source: "flow-attribution",
        service_type: "passive-netprobe",
        service_name: "flow-attribution",
        agent_id: "agent-a",
        partition: "prod-east",
        message: batch
      }

      assert {:error, :deadlock_exhausted} = admit_status(status)

      assert_receive {:flow_attribution_persist_attempt, 1, _events, "prod-east", "agent-a"}
      refute_receive {:flow_attribution_batch_received, _, _, _}, 20

      assert :ok = admit_status(status)

      assert_receive {:flow_attribution_persist_attempt, 2, _events, "prod-east", "agent-a"}

      assert_receive {:flow_attribution_batch_received, _event,
                      %{count: 1, event_count: 1, dropped_since_last: 9},
                      %{partition_id: "prod-east", agent_id: "agent-a"}}

      refute_receive {:flow_attribution_batch_received, _, _, _}, 20
    end

    test "does not emit committed flow telemetry when lane acceptance misses its deadline" do
      release_ref = make_ref()
      handler_id = {__MODULE__, self(), make_ref()}

      task_supervisor =
        start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

      lane =
        start_supervised!(
          {FlowLane,
           name: unique_name(:deadline_flow_lane),
           task_supervisor: task_supervisor,
           config: [
             max_items: 16,
             max_bytes: 64 * 1_024 * 1_024,
             max_items_per_agent: 4,
             queue_wait_ms: 100,
             worker_timeout_ms: 150,
             gateway_call_timeout_ms: 3_250
           ]}
        )

      Application.put_env(
        :serviceradar_core,
        StatusHandler,
        :serviceradar_core
        |> Application.get_env(StatusHandler, [])
        |> Keyword.put(:flow_lane, lane)
        |> Keyword.put(
          :flow_attribution_persister,
          {__MODULE__, :persist_flow_attribution_after_release, [self(), release_ref]}
        )
      )

      :ok =
        :telemetry.attach(
          handler_id,
          [:serviceradar, :event_writer, :attributed_flow, :batch_received],
          &__MODULE__.forward_flow_attribution_telemetry/4,
          self()
        )

      on_exit(fn ->
        if Process.alive?(lane), do: :sys.resume(lane)
        :telemetry.detach(handler_id)
      end)

      batch =
        FlowAttributionEventBatch.encode(%FlowAttributionEventBatch{
          events: [
            %FlowAttributionEvent{
              local_ip: "192.0.2.1",
              local_port: 50_000,
              remote_ip: "198.51.100.2",
              remote_port: 443,
              transport_protocol: "TCP",
              pid: 42,
              comm: "synthetic-client"
            }
          ],
          dropped_since_last: 3
        })

      status = %{
        source: "flow-attribution",
        service_type: "passive-netprobe",
        service_name: "flow-attribution",
        agent_id: "agent-synthetic",
        partition: "synthetic-partition",
        message: batch
      }

      reply_ref = make_ref()

      assert {:noreply, %{}} =
               StatusHandler.handle_call({:status_update, status}, {self(), reply_ref}, %{})

      assert_receive {:flow_attribution_waiting, ^release_ref, worker}
      :ok = :sys.suspend(lane)
      Process.sleep(180)
      send(worker, {:commit_flow_attribution, release_ref})
      assert_receive {:flow_attribution_committed, ^release_ref}
      :ok = :sys.resume(lane)

      assert_receive {^reply_ref, {:error, :execution_timeout}}, 500
      refute_receive {:flow_attribution_batch_received, _, _, _}, 30
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

  defp admit_status(status) do
    reply_ref = make_ref()

    assert {:noreply, %{}} =
             StatusHandler.handle_call({:status_update, status}, {self(), reply_ref}, %{})

    assert_receive {^reply_ref, result}, 1_500
    result
  end

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}_#{System.unique_integer([:positive])}")

  defp start_endpoint_inventory_queue(parent) do
    spawn(fn -> endpoint_inventory_queue_loop(parent) end)
  end

  defp endpoint_inventory_queue_loop(parent) do
    receive do
      {:"$gen_call", from, {:enqueue, payload, _opts, {:reply_to, reply_to}, _timeout}} ->
        send(parent, {:endpoint_inventory_admitted, payload})
        GenServer.reply(from, :ok)

        GenServer.reply(
          reply_to,
          {:ok, %{directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}}}
        )

        endpoint_inventory_queue_loop(parent)
    end
  end

  defp configure_endpoint_inventory_queue(queue_pid, admission_timeout_ms \\ nil) do
    previous_async = Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_async)

    previous_queue =
      Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_server)

    previous_timeout =
      Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_admission_timeout_ms)

    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_async, true)
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_server, queue_pid)

    if is_integer(admission_timeout_ms) do
      Application.put_env(
        :serviceradar_core,
        :endpoint_inventory_ingestor_admission_timeout_ms,
        admission_timeout_ms
      )
    end

    on_exit(fn ->
      restore_env(:endpoint_inventory_ingestor_async, previous_async)
      restore_env(:endpoint_inventory_ingestor_queue_server, previous_queue)
      restore_env(:endpoint_inventory_ingestor_admission_timeout_ms, previous_timeout)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)

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
          assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})
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
          assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})
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

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

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

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

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

      assert {:noreply, %{}} = StatusHandler.handle_cast({:status_update, status}, %{})

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

  def persist_flow_attribution_result(events, partition_id, agent_id, pid, result) do
    send(pid, {:flow_attribution_persisted, events, partition_id, agent_id})
    result
  end

  def persist_flow_attribution_fail_once(events, partition_id, agent_id, pid, attempt_counter) do
    attempt = Agent.get_and_update(attempt_counter, fn count -> {count + 1, count + 1} end)
    send(pid, {:flow_attribution_persist_attempt, attempt, events, partition_id, agent_id})

    if attempt == 1, do: {:error, :deadlock_exhausted}, else: :ok
  end

  def persist_flow_attribution_after_release(_events, _partition_id, _agent_id, pid, release_ref) do
    send(pid, {:flow_attribution_waiting, release_ref, self()})

    receive do
      {:commit_flow_attribution, ^release_ref} ->
        send(pid, {:flow_attribution_committed, release_ref})
        :ok
    end
  end

  def forward_flow_attribution_telemetry(event, measurements, metadata, pid) do
    send(pid, {:flow_attribution_batch_received, event, measurements, metadata})
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
