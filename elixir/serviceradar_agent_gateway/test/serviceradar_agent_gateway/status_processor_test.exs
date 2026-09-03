defmodule ServiceRadarAgentGateway.StatusProcessorTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.StatusBuffer
  alias ServiceRadarAgentGateway.StatusHandlerTestHelpers
  alias ServiceRadarAgentGateway.StatusProcessor

  @plugin_result_retained_delivery_capability_v1 "plugin-result-retained:v1"

  setup do
    existing = Process.whereis(ServiceRadar.StatusHandler)

    previous_publisher =
      Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_module)

    previous_snmp_publisher =
      Application.get_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_module)

    previous_icmp_publisher =
      Application.get_env(:serviceradar_agent_gateway, :icmp_metrics_publisher_module)

    previous_plugin_publisher =
      Application.get_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_module)

    previous_rperf_publisher =
      Application.get_env(:serviceradar_agent_gateway, :rperf_metrics_publisher_module)

    previous_mtr_publisher =
      Application.get_env(:serviceradar_agent_gateway, :mtr_metrics_publisher_module)

    previous_sweep_publisher =
      Application.get_env(:serviceradar_agent_gateway, :sweep_metrics_publisher_module)

    previous_otlp_publisher =
      Application.get_env(:serviceradar_agent_gateway, :otlp_relay_publisher_module)

    previous_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid)

    previous_snmp_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid)

    previous_icmp_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :icmp_metrics_publisher_test_pid)

    previous_plugin_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid)

    previous_rperf_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :rperf_metrics_publisher_test_pid)

    previous_mtr_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :mtr_metrics_publisher_test_pid)

    previous_sweep_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :sweep_metrics_publisher_test_pid)

    previous_otlp_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid)

    if is_pid(existing) do
      StatusHandlerTestHelpers.unregister_quietly(ServiceRadar.StatusHandler)
    end

    Application.put_env(
      :serviceradar_agent_gateway,
      :otlp_relay_publisher_module,
      __MODULE__.DisabledOtlpRelayPublisherStub
    )

    on_exit(fn ->
      StatusHandlerTestHelpers.restore(ServiceRadar.StatusHandler, existing)

      restore_env(:sysmon_metrics_publisher_module, previous_publisher)
      restore_env(:snmp_metrics_publisher_module, previous_snmp_publisher)
      restore_env(:icmp_metrics_publisher_module, previous_icmp_publisher)
      restore_env(:plugin_metrics_publisher_module, previous_plugin_publisher)
      restore_env(:rperf_metrics_publisher_module, previous_rperf_publisher)
      restore_env(:mtr_metrics_publisher_module, previous_mtr_publisher)
      restore_env(:sweep_metrics_publisher_module, previous_sweep_publisher)
      restore_env(:otlp_relay_publisher_module, previous_otlp_publisher)
      restore_env(:sysmon_metrics_publisher_test_pid, previous_test_pid)
      restore_env(:snmp_metrics_publisher_test_pid, previous_snmp_test_pid)
      restore_env(:icmp_metrics_publisher_test_pid, previous_icmp_test_pid)
      restore_env(:plugin_metrics_publisher_test_pid, previous_plugin_test_pid)
      restore_env(:rperf_metrics_publisher_test_pid, previous_rperf_test_pid)
      restore_env(:mtr_metrics_publisher_test_pid, previous_mtr_test_pid)
      restore_env(:sweep_metrics_publisher_test_pid, previous_sweep_test_pid)
      restore_env(:otlp_relay_publisher_test_pid, previous_otlp_test_pid)
    end)

    :ok
  end

  test "forwards sync result statuses to the local core status handler" do
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = %{
      service_name: "sync",
      service_type: "sync",
      source: "results",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: Jason.encode!([%{"device_id" => "default:10.0.0.1", "ip" => "10.0.0.1"}])
    }

    assert :ok = StatusProcessor.process(status)

    assert_receive {:forwarded, forwarded}
    assert forwarded.service_name == "sync"
    assert forwarded.service_type == "sync"
    assert forwarded.source == "results"
    assert forwarded.message == status.message
  end

  test "returns endpoint inventory acknowledgement directives from local core status handler" do
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:status_update, status}} ->
            GenServer.reply(
              from,
              {:ok, %{directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}}}
            )

            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = %{
      service_name: "endpoint_inventory",
      service_type: "endpoint_inventory",
      source: "results",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: Jason.encode!(%{"scan_id" => "scan-1", "state" => "unchanged"})
    }

    assert {:ok, %{directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}}} =
             StatusProcessor.process(status)

    assert_receive {:forwarded, forwarded}
    assert forwarded.service_name == "endpoint_inventory"
    assert forwarded.service_type == "endpoint_inventory"
  end

  test "returns flow attribution persistence failures without buffering" do
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:status_update, status}} ->
            send(parent, {:forwarded, status})
            GenServer.reply(from, {:error, :deadlock_exhausted})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = %{
      service_name: "flow-attribution",
      service_type: "passive-netprobe",
      source: "flow-attribution",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<10, 0>>
    }

    ensure_status_buffer_started!()
    initial_buffer_size = StatusBuffer.size()

    assert {:error, :deadlock_exhausted} = StatusProcessor.process(status)
    assert_receive {:forwarded, forwarded}
    assert_normalized_status(forwarded, status)
    assert StatusBuffer.size() == initial_buffer_size
  end

  test "returns a flow attribution core timeout without buffering or a distributed retry" do
    previous_timeout =
      Application.get_env(
        :serviceradar_agent_gateway,
        :flow_attribution_core_call_timeout_ms
      )

    Application.put_env(
      :serviceradar_agent_gateway,
      :flow_attribution_core_call_timeout_ms,
      10
    )

    on_exit(fn ->
      restore_env(:flow_attribution_core_call_timeout_ms, previous_timeout)
    end)

    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:status_update, status}} ->
            send(parent, {:forward_attempt, status})

            receive do
              {:"$gen_call", _second_from, {:status_update, second_status}} ->
                send(parent, {:unexpected_second_attempt, second_status})
            after
              100 -> :ok
            end
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = %{
      service_name: "flow-attribution",
      service_type: "passive-netprobe",
      source: "flow-attribution",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<10, 0>>
    }

    ensure_status_buffer_started!()
    initial_buffer_size = StatusBuffer.size()

    assert {:error, :forward_timeout} = StatusProcessor.process(status)
    assert_receive {:forward_attempt, forwarded}
    assert_normalized_status(forwarded, status)
    refute_receive {:unexpected_second_attempt, _status}, 50
    assert StatusBuffer.size() == initial_buffer_size
  end

  test "publishes package telemetry metrics before buffering when core status handler is unavailable" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :plugin_metrics_publisher_module,
      __MODULE__.PluginPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid, parent)

    status = %{
      service_name: "addon-telemetry",
      service_type: "native-addon",
      source: "addon:powerdns",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: "telemetry-batch"
    }

    assert :ok = StatusProcessor.process(status)
    assert_receive {:plugin_published, published}
    assert_normalized_status(published, status)
  end

  test "publishes sysmon metrics without core status forward" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :sysmon_metrics_publisher_module,
      __MODULE__.SysmonPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = sysmon_status()

    assert :ok = StatusProcessor.process(status)

    assert_receive {:published, published}
    assert_normalized_status(published, status)
    refute_receive {:forwarded, _forwarded}
  end

  test "returns an error when sysmon metric publishing fails" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :sysmon_metrics_publisher_module,
      __MODULE__.FailingSysmonPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert {:error, {:metric_publish_failed, :sysmon, :nats_down}} =
             StatusProcessor.process(sysmon_status())

    assert_receive {:publish_failed, _status}
    refute_receive {:forwarded, _forwarded}
  end

  test "returns an error when a metric-only publisher is disabled" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :sysmon_metrics_publisher_module,
      __MODULE__.DisabledSysmonPublisherStub
    )

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert {:error, {:metric_publish_disabled, :sysmon}} =
             StatusProcessor.process(sysmon_status())

    refute_receive {:forwarded, _forwarded}
  end

  test "real metric publishers reject JSON metric payloads without core fallback" do
    parent = self()

    use_real_metric_publishers()
    enable_metric_publishers()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    for {status, source} <- [
          {sysmon_status(), :sysmon},
          {snmp_status(), :snmp},
          {icmp_status(), :icmp},
          {rperf_status(), :rperf},
          {mtr_status(), :mtr},
          {sweep_status(), :sweep}
        ] do
      status = %{status | message: Jason.encode!(%{"schema_version" => "serviceradar.metric.v1", "metrics" => []})}

      assert {:error, {:metric_publish_failed, ^source, :invalid_metric_batch_payload}} =
               StatusProcessor.process(status)

      refute_receive {:forwarded, ^status}, 20
      refute_receive {:unexpected_publish, _subject, _payload, _opts}, 20
    end
  end

  test "publishes SNMP metrics without core status forward" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :snmp_metrics_publisher_module,
      __MODULE__.SnmpPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = snmp_status()

    assert :ok = StatusProcessor.process(status)

    assert_receive {:snmp_published, published}
    assert_normalized_status(published, status)
    refute_receive {:forwarded, _forwarded}
  end

  test "returns an error when SNMP metric publishing fails" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :snmp_metrics_publisher_module,
      __MODULE__.FailingSnmpPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert {:error, {:metric_publish_failed, :snmp, :nats_down}} =
             StatusProcessor.process(snmp_status())

    assert_receive {:snmp_publish_failed, _status}
    refute_receive {:forwarded, _forwarded}
  end

  test "publishes ICMP metrics without core status forward" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :icmp_metrics_publisher_module,
      __MODULE__.IcmpPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :icmp_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = icmp_status()

    assert :ok = StatusProcessor.process(status)

    assert_receive {:icmp_published, published}
    assert_normalized_status(published, status)
    refute_receive {:forwarded, _forwarded}
  end

  test "returns an error when ICMP metric publishing fails" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :icmp_metrics_publisher_module,
      __MODULE__.FailingIcmpPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :icmp_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert {:error, {:metric_publish_failed, :icmp, :nats_down}} =
             StatusProcessor.process(icmp_status())

    assert_receive {:icmp_publish_failed, _status}
    refute_receive {:forwarded, _forwarded}
  end

  test "publishes plugin metrics and still forwards package telemetry" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :plugin_metrics_publisher_module,
      __MODULE__.PluginPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = package_telemetry_status()

    assert :ok = StatusProcessor.process(status)

    assert_receive {:forwarded, forwarded}
    assert_receive {:plugin_published, published}
    assert published == forwarded
  end

  test "returns an error when package telemetry metric publishing fails" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :plugin_metrics_publisher_module,
      __MODULE__.FailingPluginPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert {:error, {:metric_publish_failed, :package_telemetry, :nats_down}} =
             StatusProcessor.process(package_telemetry_status())

    assert_receive {:plugin_publish_failed, _status}
    refute_receive {:forwarded, _forwarded}
  end

  test "does not publish legacy plugin-result JSON as metrics" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :plugin_metrics_publisher_module,
      __MODULE__.PluginPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert :ok = StatusProcessor.process(plugin_result_status())

    assert_receive {:forwarded, _forwarded}
    refute_receive {:plugin_published, _status}
  end

  test "synchronously forwards retry-capable plugin results" do
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:status_update, status}} ->
            send(parent, {:forwarded, status})
            GenServer.reply(from, :ok)
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status =
      plugin_result_status(delivery_capabilities: [@plugin_result_retained_delivery_capability_v1])

    assert :ok = StatusProcessor.process(status)
    assert_receive {:forwarded, forwarded}
    assert forwarded.delivery_capabilities == [@plugin_result_retained_delivery_capability_v1]
  end

  test "legacy plugin results retain buffered acknowledgement semantics when core is unavailable" do
    assert :ok = StatusProcessor.process(plugin_result_status())
  end

  test "returns retry-capable plugin-result forwarding errors without buffering" do
    status =
      plugin_result_status(delivery_capabilities: [@plugin_result_retained_delivery_capability_v1])

    ensure_status_buffer_started!()
    initial_buffer_size = StatusBuffer.size()

    assert {:error, :not_available} = StatusProcessor.process(status)
    assert StatusBuffer.size() == initial_buffer_size
  end

  test "returns uncommitted plugin-result persistence failures without buffering" do
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:status_update, status}} ->
            send(parent, {:forwarded, status})
            GenServer.reply(from, {:error, :database_unavailable})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status =
      plugin_result_status(delivery_capabilities: [@plugin_result_retained_delivery_capability_v1])

    ensure_status_buffer_started!()
    initial_buffer_size = StatusBuffer.size()

    assert {:error, :database_unavailable} = StatusProcessor.process(status)
    assert_receive {:forwarded, forwarded}
    assert forwarded.source == "plugin-result"
    assert StatusBuffer.size() == initial_buffer_size
  end

  test "publishes rperf metrics without core status forward" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :rperf_metrics_publisher_module,
      __MODULE__.RperfPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :rperf_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = rperf_status()

    assert :ok = StatusProcessor.process(status)

    assert_receive {:rperf_published, published}
    assert_normalized_status(published, status)
    refute_receive {:forwarded, _forwarded}
  end

  test "returns an error when rperf metric publishing fails" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :rperf_metrics_publisher_module,
      __MODULE__.FailingRperfPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :rperf_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert {:error, {:metric_publish_failed, :rperf, :nats_down}} =
             StatusProcessor.process(rperf_status())

    assert_receive {:rperf_publish_failed, _status}
    refute_receive {:forwarded, _forwarded}
  end

  test "publishes MTR metrics without core status forward" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :mtr_metrics_publisher_module,
      __MODULE__.MtrPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :mtr_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = mtr_status()

    assert :ok = StatusProcessor.process(status)

    assert_receive {:mtr_published, published}
    assert_normalized_status(published, status)
    refute_receive {:forwarded, _forwarded}
  end

  test "returns an error when MTR metric publishing fails" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :mtr_metrics_publisher_module,
      __MODULE__.FailingMtrPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :mtr_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert {:error, {:metric_publish_failed, :mtr, :nats_down}} =
             StatusProcessor.process(mtr_status())

    assert_receive {:mtr_publish_failed, _status}
    refute_receive {:forwarded, _forwarded}
  end

  test "publishes sweep metrics without core status forward" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :sweep_metrics_publisher_module,
      __MODULE__.SweepPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :sweep_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    status = sweep_status()

    assert :ok = StatusProcessor.process(status)

    assert_receive {:sweep_published, published}
    assert_normalized_status(published, status)
    refute_receive {:forwarded, _forwarded}
  end

  test "returns an error when sweep metric publishing fails" do
    parent = self()

    Application.put_env(
      :serviceradar_agent_gateway,
      :sweep_metrics_publisher_module,
      __MODULE__.FailingSweepPublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :sweep_metrics_publisher_test_pid, parent)

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:status_update, status}} ->
            send(parent, {:forwarded, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert {:error, {:metric_publish_failed, :sweep, :nats_down}} =
             StatusProcessor.process(sweep_status())

    assert_receive {:sweep_publish_failed, _status}
    refute_receive {:forwarded, _forwarded}
  end

  test "returns forwarding error for unbuffered status when core status handler is unavailable" do
    status = %{
      service_name: "agent",
      service_type: "agent",
      source: "status",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: "status"
    }

    assert {:error, :not_available} = StatusProcessor.process(status)
  end

  describe "otlp-relay source" do
    test "publishes otlp-relay directly from the gateway when enabled" do
      parent = self()

      Application.put_env(
        :serviceradar_agent_gateway,
        :otlp_relay_publisher_module,
        __MODULE__.OtlpRelayPublisherStub
      )

      Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid, parent)

      handler_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, {:status_update, status}} ->
              send(parent, {:unexpected_core_call, status})
          end
        end)

      Process.register(handler_pid, ServiceRadar.StatusHandler)

      assert :ok = StatusProcessor.process(relay_status())

      assert_receive {:otlp_relay_published, published}
      assert published.source == "otlp-relay"
      refute_receive {:unexpected_core_call, _status}
    end

    test "propagates gateway otlp-relay publisher errors without falling back to core" do
      parent = self()

      Application.put_env(
        :serviceradar_agent_gateway,
        :otlp_relay_publisher_module,
        __MODULE__.FailingOtlpRelayPublisherStub
      )

      Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid, parent)

      handler_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, {:status_update, status}} ->
              send(parent, {:unexpected_core_call, status})
          end
        end)

      Process.register(handler_pid, ServiceRadar.StatusHandler)

      assert {:error, {:otlp_relay_publish_failed, :nats_down}} =
               StatusProcessor.process(relay_status())

      assert_receive {:otlp_relay_publish_failed, _status}
      refute_receive {:unexpected_core_call, _status}
    end

    test "returns an error when direct gateway publishing is disabled" do
      parent = self()

      handler_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, {:status_update, status}} ->
              send(parent, {:unexpected_core_call, status})
          end
        end)

      Process.register(handler_pid, ServiceRadar.StatusHandler)

      assert {:error, :otlp_relay_publisher_disabled} = StatusProcessor.process(relay_status())

      refute_receive {:unexpected_core_call, _status}
    end

    test "does not buffer otlp-relay statuses when direct publishing is disabled" do
      assert {:error, :otlp_relay_publisher_disabled} = StatusProcessor.process(relay_status())
    end
  end

  defp relay_status do
    %{
      service_name: "otlp-relay",
      service_type: "otlp-relay",
      source: "otlp-relay",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<1, 2, 3>>
    }
  end

  defp sysmon_status do
    %{
      service_name: "sysmon",
      service_type: "sysmon",
      source: "sysmon-metrics",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<10, 22, "serviceradar.metric.v1">>
    }
  end

  defp snmp_status do
    %{
      service_name: "snmp",
      service_type: "snmp",
      source: "snmp-metrics",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<10, 22, "serviceradar.metric.v1">>
    }
  end

  defp icmp_status do
    %{
      service_name: "icmp_checks",
      service_type: "icmp",
      source: "icmp-metrics",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<10, 22, "serviceradar.metric.v1">>
    }
  end

  defp package_telemetry_status do
    %{
      service_name: "proxmox-inventory",
      service_type: "wasm-plugin",
      source: "plugin:proxmox-inventory",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<10, 22, "serviceradar.metric.v1">>
    }
  end

  defp rperf_status do
    %{
      service_name: "rperf",
      service_type: "rperf",
      source: "rperf-metrics",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<10, 22, "serviceradar.metric.v1">>
    }
  end

  defp mtr_status do
    %{
      service_name: "mtr_traces",
      service_type: "mtr",
      source: "mtr-metrics",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<10, 22, "serviceradar.metric.v1">>
    }
  end

  defp sweep_status do
    %{
      service_name: "network_sweep",
      service_type: "sweep",
      source: "sweep-metrics",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      message: <<10, 22, "serviceradar.metric.v1">>
    }
  end

  defp plugin_result_status(overrides \\ []) do
    Map.merge(
      %{
        service_name: "proxmox-inventory",
        service_type: "wasm-plugin",
        source: "plugin-result",
        agent_id: "agent-1",
        gateway_id: "gateway-1",
        partition: "default",
        message:
          Jason.encode!(%{
            "status" => "WARNING",
            "summary" => "resource pressure",
            "metrics" => [%{"name" => "proxmox_guest_cpu_ratio_max", "value" => 0.91}]
          })
      },
      Map.new(overrides)
    )
  end

  defp assert_normalized_status(published, original) do
    assert Map.delete(published, :timestamp) == original
    assert is_integer(published.timestamp)
  end

  defp ensure_status_buffer_started! do
    try do
      Config.get()
    rescue
      ArgumentError ->
        Config.setup(gateway_id: "gateway-test", domain: "test", capabilities: [])
        on_exit(fn -> :persistent_term.erase(Config) end)
    end

    if !Process.whereis(StatusBuffer) do
      start_supervised!(StatusBuffer)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defp use_real_metric_publishers do
    Application.put_env(
      :serviceradar_agent_gateway,
      :sysmon_metrics_publisher_module,
      ServiceRadarAgentGateway.SysmonMetricsPublisher
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :snmp_metrics_publisher_module,
      ServiceRadarAgentGateway.SnmpMetricsPublisher
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :icmp_metrics_publisher_module,
      ServiceRadarAgentGateway.IcmpMetricsPublisher
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :rperf_metrics_publisher_module,
      ServiceRadarAgentGateway.RperfMetricsPublisher
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :mtr_metrics_publisher_module,
      ServiceRadarAgentGateway.MtrMetricsPublisher
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :sweep_metrics_publisher_module,
      ServiceRadarAgentGateway.SweepMetricsPublisher
    )
  end

  defp enable_metric_publishers do
    Enum.each(
      [
        :sysmon_metrics_publisher,
        :snmp_metrics_publisher,
        :icmp_metrics_publisher,
        :rperf_metrics_publisher,
        :mtr_metrics_publisher,
        :sweep_metrics_publisher
      ],
      fn key ->
        Application.put_env(:serviceradar_agent_gateway, key,
          enabled: true,
          connection: __MODULE__.UnexpectedConnectionStub
        )
      end
    )
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.UnexpectedConnectionStub do
  @moduledoc false
  def publish(subject, payload, opts) do
    send(self(), {:unexpected_publish, subject, payload, opts})
    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.SysmonPublisherStub do
  @moduledoc false
  def publish_sysmon(status) do
    send(
      Application.fetch_env!(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid),
      {
        :published,
        status
      }
    )

    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.SnmpPublisherStub do
  @moduledoc false
  def publish_snmp(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid), {
      :snmp_published,
      status
    })

    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.IcmpPublisherStub do
  @moduledoc false
  def publish_icmp(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :icmp_metrics_publisher_test_pid), {
      :icmp_published,
      status
    })

    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.PluginPublisherStub do
  @moduledoc false
  def publish_plugin_metrics(status) do
    send(
      Application.fetch_env!(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid),
      {
        :plugin_published,
        status
      }
    )

    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.RperfPublisherStub do
  @moduledoc false
  def publish_rperf(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :rperf_metrics_publisher_test_pid), {
      :rperf_published,
      status
    })

    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.MtrPublisherStub do
  @moduledoc false
  def publish_mtr(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :mtr_metrics_publisher_test_pid), {
      :mtr_published,
      status
    })

    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.SweepPublisherStub do
  @moduledoc false
  def publish_sweep(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :sweep_metrics_publisher_test_pid), {
      :sweep_published,
      status
    })

    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.FailingPluginPublisherStub do
  @moduledoc false
  def publish_plugin_metrics(status) do
    send(
      Application.fetch_env!(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid),
      {
        :plugin_publish_failed,
        status
      }
    )

    {:error, :nats_down}
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.FailingRperfPublisherStub do
  @moduledoc false
  def publish_rperf(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :rperf_metrics_publisher_test_pid), {
      :rperf_publish_failed,
      status
    })

    {:error, :nats_down}
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.FailingMtrPublisherStub do
  @moduledoc false
  def publish_mtr(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :mtr_metrics_publisher_test_pid), {
      :mtr_publish_failed,
      status
    })

    {:error, :nats_down}
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.FailingSweepPublisherStub do
  @moduledoc false
  def publish_sweep(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :sweep_metrics_publisher_test_pid), {
      :sweep_publish_failed,
      status
    })

    {:error, :nats_down}
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.FailingSnmpPublisherStub do
  @moduledoc false
  def publish_snmp(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid), {
      :snmp_publish_failed,
      status
    })

    {:error, :nats_down}
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.FailingIcmpPublisherStub do
  @moduledoc false
  def publish_icmp(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :icmp_metrics_publisher_test_pid), {
      :icmp_publish_failed,
      status
    })

    {:error, :nats_down}
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.FailingSysmonPublisherStub do
  @moduledoc false
  def publish_sysmon(status) do
    send(
      Application.fetch_env!(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid),
      {
        :publish_failed,
        status
      }
    )

    {:error, :nats_down}
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.DisabledSysmonPublisherStub do
  @moduledoc false
  def publish_sysmon(_status), do: :disabled
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.OtlpRelayPublisherStub do
  @moduledoc false
  def publish_relay(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid), {
      :otlp_relay_published,
      status
    })

    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.DisabledOtlpRelayPublisherStub do
  @moduledoc false
  def publish_relay(_status), do: :disabled
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.FailingOtlpRelayPublisherStub do
  @moduledoc false
  def publish_relay(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid), {
      :otlp_relay_publish_failed,
      status
    })

    {:error, {:otlp_relay_publish_failed, :nats_down}}
  end
end
