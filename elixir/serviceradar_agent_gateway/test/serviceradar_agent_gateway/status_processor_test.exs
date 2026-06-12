defmodule ServiceRadarAgentGateway.StatusProcessorTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.StatusProcessor

  setup do
    existing = Process.whereis(ServiceRadar.StatusHandler)

    previous_publisher =
      Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_module)

    previous_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid)

    if is_pid(existing) do
      Process.unregister(ServiceRadar.StatusHandler)
    end

    on_exit(fn ->
      if Process.whereis(ServiceRadar.StatusHandler) do
        Process.unregister(ServiceRadar.StatusHandler)
      end

      if is_pid(existing) do
        Process.register(existing, ServiceRadar.StatusHandler)
      end

      restore_env(:sysmon_metrics_publisher_module, previous_publisher)
      restore_env(:sysmon_metrics_publisher_test_pid, previous_test_pid)
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
            GenServer.reply(from, {:ok, %{directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}}})
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

  test "shadow publishes sysmon metrics after successful direct forward" do
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
    assert_receive {:shadow_published, published}
    assert published == forwarded
  end

  test "continues the direct sysmon path when shadow publishing fails" do
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
    assert_receive {:shadow_publish_failed, _status}
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
    test "forwards otlp-relay statuses synchronously via GenServer.call" do
      parent = self()

      handler_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:status_update, status}} ->
              GenServer.reply(from, :ok)
              send(parent, {:called, status})
          end
        end)

      Process.register(handler_pid, ServiceRadar.StatusHandler)

      assert :ok = StatusProcessor.process(relay_status())

      assert_receive {:called, forwarded}
      assert forwarded.source == "otlp-relay"
      assert forwarded.message == relay_status().message
    end

    test "propagates core handler errors for otlp-relay statuses" do
      handler_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:status_update, _status}} ->
              GenServer.reply(from, {:error, {:otlp_relay_publish_failed, :nats_down}})
          end
        end)

      Process.register(handler_pid, ServiceRadar.StatusHandler)

      assert {:error, {:otlp_relay_publish_failed, :nats_down}} =
               StatusProcessor.process(relay_status())
    end

    test "returns an error instead of buffering when core is unavailable" do
      # No StatusHandler is registered. Unlike results/addon sources, an
      # otlp-relay status must never fall into the lossy StatusBuffer (the
      # buffered path would return :ok and falsely ack the relay frame).
      assert {:error, :not_available} = StatusProcessor.process(relay_status())
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

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.SysmonPublisherStub do
  @moduledoc false
  def publish_sysmon(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid), {
      :shadow_published,
      status
    })

    :ok
  end
end

defmodule ServiceRadarAgentGateway.StatusProcessorTest.FailingSysmonPublisherStub do
  @moduledoc false
  def publish_sysmon(status) do
    send(Application.fetch_env!(:serviceradar_agent_gateway, :sysmon_metrics_publisher_test_pid), {
      :shadow_publish_failed,
      status
    })

    {:error, :nats_down}
  end
end
