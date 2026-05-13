defmodule ServiceRadarAgentGateway.StatusProcessorTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.StatusProcessor

  setup do
    existing = Process.whereis(ServiceRadar.StatusHandler)

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
end
