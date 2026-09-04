defmodule ServiceRadarAgentGateway.OtlpRelayForwardingTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.AgentGatewayServer
  alias ServiceRadarAgentGateway.StatusHandlerTestHelpers

  @plugin_result_retained_delivery_capability_v1 "plugin-result-retained:v1"

  setup do
    if !Process.whereis(ServiceRadarAgentGateway.DeliveryTaskSupervisor) do
      start_supervised!({Task.Supervisor, name: ServiceRadarAgentGateway.DeliveryTaskSupervisor})
    end

    existing = Process.whereis(ServiceRadar.StatusHandler)

    previous_publisher =
      Application.get_env(:serviceradar_agent_gateway, :otlp_relay_publisher_module)

    previous_test_pid =
      Application.get_env(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid)

    if is_pid(existing) do
      StatusHandlerTestHelpers.unregister_quietly(ServiceRadar.StatusHandler)
    end

    on_exit(fn ->
      StatusHandlerTestHelpers.restore(ServiceRadar.StatusHandler, existing)

      restore_env(:otlp_relay_publisher_module, previous_publisher)
      restore_env(:otlp_relay_publisher_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "relay publish failures raise out of chunk processing so the stream call fails" do
    # Direct gateway publishing is disabled, so the relay frame cannot be acked. The
    # failure must escape the lenient drop-and-log rescue and fail the whole
    # stream_status call (the agent then retries the frame from its spool).
    assert_raise GRPC.RPCError, ~r/otlp-relay forward failed/, fn ->
      AgentGatewayServer.process_chunk_services([relay_service()], metadata())
    end
  end

  test "flow attribution persistence failures return a negative acknowledgement" do
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:status_update, status}} ->
            send(parent, {:flow_attribution_forwarded, status})
            GenServer.reply(from, {:error, :deadlock_exhausted})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert %Monitoring.GatewayStatusResponse{received: false, directives: []} =
             AgentGatewayServer.process_status_stream([
               {[flow_attribution_service()], metadata()}
             ])

    assert_receive {:flow_attribution_forwarded, status}
    assert status.partition == "cert-partition"
    assert status.agent_id == "agent-1"
  end

  test "retained plugin-result forwarding failures return a negative acknowledgement" do
    assert %Monitoring.GatewayStatusResponse{received: false, directives: []} =
             AgentGatewayServer.process_status_stream([
               {[plugin_result_service()], retained_plugin_result_metadata()}
             ])
  end

  test "legacy plugin-result forwarding keeps buffered acknowledgement semantics" do
    assert AgentGatewayServer.process_chunk_services([plugin_result_service()], metadata()) == []
  end

  test "committed plugin-result handler failures acknowledge the stream" do
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:status_update, status}} ->
            send(parent, {:plugin_result_forwarded, status})

            GenServer.reply(
              from,
              {:error, {:plugin_result_handlers_failed, [{TestHandler, ":forced_failure"}]}}
            )
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    assert %Monitoring.GatewayStatusResponse{received: true, directives: []} =
             AgentGatewayServer.process_status_stream([
               {[plugin_result_service()], retained_plugin_result_metadata()}
             ])

    assert_receive {:plugin_result_forwarded, status}
    assert status.partition == "cert-partition"
    assert status.agent_id == "agent-1"
  end

  test "invalid non-relay statuses are still dropped without failing the stream" do
    bad_service = %Monitoring.GatewayServiceStatus{
      service_name: "bad\nname",
      service_type: "status",
      source: "status",
      message: "ok"
    }

    assert AgentGatewayServer.process_chunk_services([bad_service], metadata()) == []
  end

  test "relay statuses use the cert-derived partition and publish without core fallback" do
    parent = self()

    handler_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:status_update, status}} ->
            send(parent, {:unexpected_core_call, status})
        end
      end)

    Process.register(handler_pid, ServiceRadar.StatusHandler)

    Application.put_env(
      :serviceradar_agent_gateway,
      :otlp_relay_publisher_module,
      __MODULE__.PublisherStub
    )

    Application.put_env(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid, parent)

    service = relay_service(partition: "payload-spoofed-partition")

    assert AgentGatewayServer.process_chunk_services([service], metadata()) == []

    assert_receive {:otlp_relay_published, published}
    assert published.source == "otlp-relay"
    # The mTLS-cert-derived partition (metadata) wins over the
    # payload-supplied service field.
    assert published.partition == "cert-partition"
    assert published.agent_id == "agent-1"
    # Relay payloads above the default 4 KiB status cap must never be
    # truncated (truncation would corrupt the OTLP protobuf chunk).
    assert published.message == service.message
    refute_receive {:unexpected_core_call, _status}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)

  defmodule PublisherStub do
    @moduledoc false
    def publish_relay(status) do
      send(Application.fetch_env!(:serviceradar_agent_gateway, :otlp_relay_publisher_test_pid), {
        :otlp_relay_published,
        status
      })

      :ok
    end
  end

  defp relay_service(overrides \\ []) do
    struct!(
      %Monitoring.GatewayServiceStatus{
        service_name: "otlp-relay",
        service_type: "otlp-relay",
        source: "otlp-relay",
        available: true,
        message: :binary.copy(<<0xAB>>, 8 * 1024)
      },
      overrides
    )
  end

  defp flow_attribution_service do
    %Monitoring.GatewayServiceStatus{
      service_name: "flow-attribution",
      service_type: "passive-netprobe",
      source: "flow-attribution",
      partition: "payload-spoofed-partition",
      available: true,
      message: <<10, 0>>
    }
  end

  defp plugin_result_service do
    %Monitoring.GatewayServiceStatus{
      service_name: "proxmox-inventory",
      service_type: "plugin",
      source: "plugin-result",
      partition: "payload-spoofed-partition",
      available: true,
      message: Jason.encode!(%{"status" => "OK", "summary" => "inventory complete"})
    }
  end

  defp metadata do
    %{
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "cert-partition",
      source_ip: "192.0.2.10",
      kv_store_id: nil,
      timestamp: System.os_time(:second),
      agent_timestamp: 0,
      chunk_index: 0,
      total_chunks: 1,
      is_final: true
    }
  end

  defp retained_plugin_result_metadata do
    Map.put(
      metadata(),
      :delivery_capabilities,
      [@plugin_result_retained_delivery_capability_v1]
    )
  end
end
