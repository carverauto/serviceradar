defmodule ServiceRadar.StatusHandlerTest do
  use ExUnit.Case, async: false

  alias Netprobepb.FlowAttributionEvent
  alias Netprobepb.FlowAttributionEventBatch
  alias ServiceRadar.EventWriter.AttributedFlowJoiner
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

  def stub_publish(subject, payload, fun), do: fun.(subject, payload)
end
