defmodule ServiceRadarAgentGateway.StatusProcessorTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.StatusProcessor

  setup do
    existing = Process.whereis(ServiceRadar.StatusHandler)

    previous_publisher =
      Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_module)

    previous_snmp_publisher =
      Application.get_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_module)

    previous_plugin_publisher =
      Application.get_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_module)

    previous_otlp_publisher =
      Application.get_env(:serviceradar_agent_gateway, :otlp_relay_publisher_module)

    previous_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid)

    previous_snmp_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :snmp_metrics_publisher_test_pid)

    previous_plugin_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :plugin_metrics_publisher_test_pid)

    previous_otlp_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid)

    if is_pid(existing) do
      Process.unregister(ServiceRadar.StatusHandler)
    end

    Application.put_env(
      :serviceradar_agent_gateway,
      :otlp_relay_publisher_module,
      __MODULE__.DisabledOtlpRelayPublisherStub
    )

    on_exit(fn ->
      if Process.whereis(ServiceRadar.StatusHandler) do
        Process.unregister(ServiceRadar.StatusHandler)
      end

      if is_pid(existing) do
        Process.register(existing, ServiceRadar.StatusHandler)
      end

      restore_env(:sysmon_metrics_publisher_module, previous_publisher)
      restore_env(:snmp_metrics_publisher_module, previous_snmp_publisher)
      restore_env(:plugin_metrics_publisher_module, previous_plugin_publisher)
      restore_env(:otlp_relay_publisher_module, previous_otlp_publisher)
      restore_env(:sysmon_metrics_publisher_test_pid, previous_test_pid)
      restore_env(:snmp_metrics_publisher_test_pid, previous_snmp_test_pid)
      restore_env(:plugin_metrics_publisher_test_pid, previous_plugin_test_pid)
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

  test "buffers add-on telemetry when core status handler is unavailable" do
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
  end

  test "publishes sysmon metrics after successful status forward" do
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

    assert_receive {:forwarded, forwarded}
    assert_receive {:published, published}
    assert published == forwarded
  end

  test "continues the sysmon status path when metrics publishing fails" do
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

    assert :ok = StatusProcessor.process(sysmon_status())

    assert_receive {:forwarded, _forwarded}
    assert_receive {:publish_failed, _status}
  end

  test "publishes SNMP metrics after successful status forward" do
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

    assert_receive {:forwarded, forwarded}
    assert_receive {:snmp_published, published}
    assert published == forwarded
  end

  test "continues the SNMP status path when metrics publishing fails" do
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

    assert :ok = StatusProcessor.process(snmp_status())

    assert_receive {:forwarded, _forwarded}
    assert_receive {:snmp_publish_failed, _status}
  end

  test "publishes plugin metrics after successful status forward" do
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

    status = plugin_status()

    assert :ok = StatusProcessor.process(status)

    assert_receive {:forwarded, forwarded}
    assert_receive {:plugin_published, published}
    assert published == forwarded
  end

  test "continues the plugin result path when metrics publishing fails" do
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

    assert :ok = StatusProcessor.process(plugin_status())

    assert_receive {:forwarded, _forwarded}
    assert_receive {:plugin_publish_failed, _status}
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
      message:
        Jason.encode!(%{
          "available" => true,
          "response_time" => 0,
          "status" => %{
            "timestamp" => "2026-06-12T00:00:00Z",
            "host_id" => "host-1",
            "host_ip" => "10.0.0.10",
            "agent_id" => "agent-1",
            "cpus" => [%{"core_id" => 0, "usage_percent" => 12.5}],
            "clusters" => [],
            "disks" => [%{"mount_point" => "/", "used_bytes" => 10, "total_bytes" => 100}],
            "memory" => %{"used_bytes" => 50, "total_bytes" => 100},
            "network" => [],
            "processes" => []
          }
        })
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
      message:
        Jason.encode!(%{
          "results" => [
            %{
              "target" => "core-switch",
              "host" => "10.0.0.20",
              "metric" => "ifHCInOctets",
              "oid" => ".1.3.6.1.2.1.31.1.1.1.6.7",
              "value" => 1234.5,
              "timestamp" => "2026-06-12T00:00:00Z",
              "data_type" => "counter",
              "delta" => true,
              "if_index" => 7,
              "interface_uid" => "ifindex:7"
            }
          ]
        })
    }
  end

  defp plugin_status do
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
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
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
