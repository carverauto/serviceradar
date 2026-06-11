defmodule ServiceRadarAgentGateway.OtlpRelayForwardingTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.AgentGatewayServer

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

  test "relay forward failures raise out of chunk processing so the stream call fails" do
    # No StatusHandler is registered, so forwarding fails. For otlp-relay the
    # failure must escape the lenient drop-and-log rescue and fail the whole
    # stream_status call (the agent then retries the frame from its spool).
    assert_raise GRPC.RPCError, ~r/otlp-relay forward failed/, fn ->
      AgentGatewayServer.process_chunk_services([relay_service()], metadata())
    end
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

  test "relay statuses use the cert-derived partition and pass the payload through untruncated" do
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

    service = relay_service(partition: "payload-spoofed-partition")

    assert AgentGatewayServer.process_chunk_services([service], metadata()) == []

    assert_receive {:called, forwarded}
    assert forwarded.source == "otlp-relay"
    # The mTLS-cert-derived partition (metadata) wins over the
    # payload-supplied service field.
    assert forwarded.partition == "cert-partition"
    assert forwarded.agent_id == "agent-1"
    # Relay payloads above the default 4 KiB status cap must never be
    # truncated (truncation would corrupt the OTLP protobuf chunk).
    assert forwarded.message == service.message
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
end
