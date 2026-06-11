defmodule ServiceRadar.StatusHandlerTest do
  use ExUnit.Case, async: false

  alias Netprobepb.FlowAttributionEvent
  alias Netprobepb.FlowAttributionEventBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryBatch
  alias Serviceradar.Agent.Addon.V1.TelemetryCounters
  alias Serviceradar.Agent.Addon.V1.TelemetryRecord
  alias Serviceradar.Agent.Addon.V1.TelemetrySource
  alias ServiceRadar.EventWriter.AttributedFlowJoiner
  alias ServiceRadar.EventWriter.SignalTelemetry
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

  describe "flow-attribution source" do
    setup do
      if pid = Process.whereis(AttributedFlowJoiner) do
        GenServer.stop(pid, :normal, 1_000)
      end

      parent = self()

      publisher_fun = fn subject, payload ->
        send(parent, {:published, subject, payload})
        :ok
      end

      {:ok, _pid} =
        AttributedFlowJoiner.start_link(
          ttl_ms: 60_000,
          self_partition_id: "prod-east",
          publisher: {__MODULE__, :stub_publish, [publisher_fun]}
        )

      on_exit(fn ->
        pid = Process.whereis(AttributedFlowJoiner)

        if is_pid(pid) and Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok
    end

    test "decodes FlowAttributionEventBatch and forwards each event to the joiner" do
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

      # The event is cached pending host-slice arrival; verify ETS entry exists.
      assert AttributedFlowJoiner.stats().size >= 1
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

  describe "otlp-relay source" do
    setup do
      original = Application.get_env(:serviceradar_core, StatusHandler, [])

      Application.put_env(:serviceradar_core, StatusHandler,
        otlp_relay_publisher: {__MODULE__, :relay_publish, [self()]}
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

    test "routes records to per-kind subjects with verbatim payloads and gateway-derived headers" do
      traces_payload = <<0xDE, 0xAD, 0x01, 255, 0, 17>>
      logs_payload = <<0xBE, 0xEF, 0x02>>
      metrics_payload = <<0xCA, 0xFE, 0x03>>
      derived_payload = <<0xF0, 0x0D, 0x04>>

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{source_type: "otel-collector", source_instance: "edge-1"},
          records: [
            %TelemetryRecord{
              event_id: "r-1",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
              payload: traces_payload
            },
            %TelemetryRecord{
              event_id: "r-2",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
              payload: logs_payload
            },
            %TelemetryRecord{
              event_id: "r-3",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_METRICS,
              payload: metrics_payload
            },
            %TelemetryRecord{
              event_id: "r-4",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_DERIVED_METRIC,
              payload: derived_payload
            }
          ]
        })

      assert {:reply, :ok, %{}} =
               StatusHandler.handle_call({:status_update, relay_status(batch)}, self(), %{})

      expected_headers = [
        {"Sr-Agent-Id", "agent-1"},
        {"Sr-Partition", "prod-east"},
        {"Sr-Ingest-Identity", "agent:agent-1"}
      ]

      assert_receive {:relay_published, "otel.traces.raw", ^traces_payload, traces_opts}
      assert Keyword.get(traces_opts, :headers) == expected_headers

      assert_receive {:relay_published, "logs.otel", ^logs_payload, logs_opts}
      assert Keyword.get(logs_opts, :headers) == expected_headers

      assert_receive {:relay_published, "otel.metrics.raw", ^metrics_payload, metrics_opts}
      assert Keyword.get(metrics_opts, :headers) == expected_headers

      assert_receive {:relay_published, "otel.metrics.derived", ^derived_payload, derived_opts}
      assert Keyword.get(derived_opts, :headers) == expected_headers

      refute_receive {:relay_published, _subject, _payload, _opts}
    end

    test "stamps headers from the gateway-authenticated view, ignoring payload-claimed identity" do
      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          source: %TelemetrySource{
            source_type: "otel-collector",
            source_instance: "edge-1",
            metadata: %{
              "partition" => "spoofed-partition",
              "agent_id" => "spoofed-agent"
            }
          },
          records: [
            %TelemetryRecord{
              event_id: "r-1",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
              payload: <<1, 2, 3>>,
              metadata: %{
                "Sr-Agent-Id" => "spoofed-agent",
                "Sr-Partition" => "spoofed-partition",
                "Sr-Ingest-Identity" => "token:spoofed"
              }
            }
          ]
        })

      assert {:reply, :ok, %{}} =
               StatusHandler.handle_call({:status_update, relay_status(batch)}, self(), %{})

      assert_receive {:relay_published, "otel.traces.raw", <<1, 2, 3>>, opts}

      # The cert-derived (gateway-authenticated) identity in the status map
      # wins over anything carried inside the payload.
      assert Keyword.get(opts, :headers) == [
               {"Sr-Agent-Id", "agent-1"},
               {"Sr-Partition", "prod-east"},
               {"Sr-Ingest-Identity", "agent:agent-1"}
             ]
    end

    test "propagates publish failures as errors so the gateway NACKs the agent" do
      Application.put_env(:serviceradar_core, StatusHandler,
        otlp_relay_publisher: {__MODULE__, :relay_publish_fail, [self()]}
      )

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          records: [
            %TelemetryRecord{
              event_id: "r-1",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
              payload: <<9>>
            }
          ]
        })

      assert {:reply, {:error, {:otlp_relay_publish_failed, :nats_down}}, %{}} =
               StatusHandler.handle_call({:status_update, relay_status(batch)}, self(), %{})

      assert_receive {:relay_publish_attempt, "otel.traces.raw", <<9>>, _opts}
    end

    test "returns a decode error for malformed relay batches" do
      assert {:reply, {:error, :otlp_relay_decode_failed}, %{}} =
               StatusHandler.handle_call(
                 {:status_update, relay_status(<<255, 255, 255, 255>>)},
                 self(),
                 %{}
               )
    end

    test "skips records with unroutable payload kinds without failing the frame" do
      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          records: [
            %TelemetryRecord{
              event_id: "skip",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OCSF_EVENT,
              payload: "{}"
            },
            %TelemetryRecord{
              event_id: "keep",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_LOGS,
              payload: <<7>>
            }
          ]
        })

      assert {:reply, :ok, %{}} =
               StatusHandler.handle_call({:status_update, relay_status(batch)}, self(), %{})

      assert_receive {:relay_published, "logs.otel", <<7>>, _opts}
      refute_receive {:relay_published, _subject, "{}", _opts}
    end

    test "emits spool counters and per-signal relayed counts" do
      handler_id = {__MODULE__, :otlp_relay_telemetry}

      :telemetry.attach_many(
        handler_id,
        [[:serviceradar, :otlp_relay, :spool], SignalTelemetry.event()],
        &__MODULE__.forward_telemetry/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      batch =
        TelemetryBatch.encode(%TelemetryBatch{
          counters: %TelemetryCounters{received: 10, emitted: 8, dropped: 2, queue_depth: 5},
          records: [
            %TelemetryRecord{
              event_id: "r-1",
              payload_kind: :TELEMETRY_PAYLOAD_KIND_OTLP_TRACES,
              payload: <<1>>
            }
          ]
        })

      assert {:reply, :ok, %{}} =
               StatusHandler.handle_call({:status_update, relay_status(batch)}, self(), %{})

      assert_receive {:telemetry_event, [:serviceradar, :otlp_relay, :spool], measurements, meta}
      assert measurements.dropped == 2
      assert measurements.queue_depth == 5
      assert meta.agent_id == "agent-1"
      assert meta.partition_id == "prod-east"

      assert_receive {:telemetry_event, [:serviceradar, :event_writer, :signal], %{count: 1},
                      %{signal: :traces, outcome: :relayed}}
    end
  end

  defp relay_status(message) do
    %{
      source: "otlp-relay",
      service_type: "otlp-relay",
      service_name: "otlp-relay",
      agent_id: "agent-1",
      gateway_id: "gateway-a",
      partition: "prod-east",
      message: message
    }
  end

  def relay_publish(subject, payload, opts, pid) do
    send(pid, {:relay_published, subject, payload, opts})
    :ok
  end

  def relay_publish_fail(subject, payload, opts, pid) do
    send(pid, {:relay_publish_attempt, subject, payload, opts})
    {:error, :nats_down}
  end

  def forward_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end

  def stub_publish(subject, payload, fun) when is_function(fun, 2), do: fun.(subject, payload)

  def stub_publish(subject, payload, pid) when is_pid(pid) do
    send(pid, {:published, subject, payload})
    :ok
  end
end
