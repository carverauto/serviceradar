defmodule ServiceRadarAgentGateway.AgentRetainedDeliveryTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.AgentGatewayServer
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.StatusHandlerTestHelpers

  @retained_plugin_capability "plugin-result-retained:v1"

  defmodule PeerCertAdapter do
    @moduledoc false

    def get_cert({:cert, cert_der}), do: cert_der
    def get_peer(_payload), do: {{192, 0, 2, 10}, 50_051}
  end

  setup_all do
    parent_dir = CertificateTestHelpers.unique_tmp_dir!("agent-retained-delivery-test")
    on_exit(fn -> File.rm_rf(parent_dir) end)

    ca_cert = Path.join(parent_dir, "root.pem")
    ca_key = Path.join(parent_dir, "root-key.pem")
    CertificateTestHelpers.generate_ca_bundle!(ca_cert, ca_key)

    %{parent_dir: parent_dir, ca_cert: ca_cert, ca_key: ca_key}
  end

  setup do
    previous_config =
      try do
        {:ok, Config.get()}
      rescue
        ArgumentError -> :missing
      end

    {:ok, _apps} = Application.ensure_all_started(:horde)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)

    if !Process.whereis(ServiceRadar.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
    end

    if !Process.whereis(ServiceRadar.ProcessRegistry.registry_name()) do
      Enum.each(ServiceRadar.ProcessRegistry.child_specs(), &start_supervised!/1)
    end

    if !Process.whereis(AgentRegistryProxy) do
      start_supervised!(AgentRegistryProxy)
    end

    if !Process.whereis(ServiceRadarAgentGateway.DeliveryTaskSupervisor) do
      start_supervised!({Task.Supervisor, name: ServiceRadarAgentGateway.DeliveryTaskSupervisor})
    end

    CertificateTestHelpers.ensure_revocation_store!()

    Config.setup(
      gateway_id: "gateway-1",
      domain: "test",
      capabilities: []
    )

    on_exit(fn -> restore_config(previous_config) end)

    existing = Process.whereis(ServiceRadar.StatusHandler)

    if is_pid(existing) do
      StatusHandlerTestHelpers.unregister_quietly(ServiceRadar.StatusHandler)
    end

    on_exit(fn -> StatusHandlerTestHelpers.restore(ServiceRadar.StatusHandler, existing) end)
    :ok
  end

  test "unary retained delivery reports committed and uncommitted outcomes" do
    handler = start_status_handler([:ok, {:error, :lane_full}])

    assert %Monitoring.GatewayStatusResponse{received: true, directives: []} =
             AgentGatewayServer.process_status_services([flow_service()], metadata())

    assert %Monitoring.GatewayStatusResponse{received: false, directives: []} =
             AgentGatewayServer.process_status_services([flow_service()], metadata())

    send(handler, :stop)
  end

  test "unary retained delivery rejects a best-effort peer before forwarding" do
    parent = self()
    _handler = start_status_handler([{:notify, parent, :unexpected_forward}])

    assert_raise GRPC.RPCError, ~r/isolated/, fn ->
      AgentGatewayServer.process_status_services(
        [flow_service(), best_effort_service()],
        metadata()
      )
    end

    refute_receive :unexpected_forward
  end

  test "retained stream rejects source changes and multi-chunk flow before forwarding" do
    parent = self()
    _handler = start_status_handler([{:notify, parent, :unexpected_forward}])

    assert_raise GRPC.RPCError, ~r/same retained source/, fn ->
      AgentGatewayServer.process_status_stream([
        {[plugin_service("first")], retained_metadata(0, 2)},
        {[flow_service()], retained_metadata(1, 2)}
      ])
    end

    assert_raise GRPC.RPCError, ~r/exactly one non-empty chunk/, fn ->
      AgentGatewayServer.process_status_stream([
        {[flow_service()], metadata(0, 2)},
        {[flow_service()], metadata(1, 2)}
      ])
    end

    assert_raise GRPC.RPCError, ~r/exactly one service/, fn ->
      AgentGatewayServer.process_status_stream([
        {[flow_service(), flow_service()], metadata()}
      ])
    end

    refute_receive :unexpected_forward
  end

  test "retained plugin stream forwards at most two at once and preserves directive order" do
    parent = self()
    handler = start_controlled_status_handler(parent)

    task =
      Task.async(fn ->
        AgentGatewayServer.process_status_stream([
          {[plugin_service("first")], retained_metadata(0, 3)},
          {[plugin_service("second")], retained_metadata(1, 3)},
          {[plugin_service("third")], retained_metadata(2, 3)}
        ])
      end)

    assert_receive {:forward_started, first_started}
    assert_receive {:forward_started, second_started}
    assert MapSet.new([first_started, second_started]) == MapSet.new(["first", "second"])
    refute_receive {:forward_started, "third"}, 50

    send(handler, {:complete, "first", :ok})
    assert_receive {:forward_started, "third"}

    send(handler, {:complete, "second", :ok})
    send(handler, {:complete, "third", :ok})

    assert %Monitoring.GatewayStatusResponse{received: true, directives: directives} =
             Task.await(task)

    assert [
             %Monitoring.GatewayStatusDirective{service_name: "first"},
             %Monitoring.GatewayStatusDirective{service_name: "second"},
             %Monitoring.GatewayStatusDirective{service_name: "third"}
           ] = directives
  end

  test "one uncommitted retained plugin result makes the whole stream a negative acknowledgement" do
    _handler = start_status_handler([committed_result("first"), {:error, :lane_full}])

    assert %Monitoring.GatewayStatusResponse{received: false, directives: []} =
             AgentGatewayServer.process_status_stream([
               {[plugin_service("first")], retained_metadata(0, 2)},
               {[plugin_service("second")], retained_metadata(1, 2)}
             ])
  end

  test "an undecodable retained payload is rejected before any item is forwarded" do
    parent = self()
    _handler = start_status_handler([{:notify, parent, :unexpected_forward}])

    assert_raise GRPC.RPCError, ~r/invalid plugin-result payload/, fn ->
      AgentGatewayServer.process_status_stream([
        {[plugin_service("first")], retained_metadata(0, 2)},
        {[%{plugin_service("second") | message: "{"}], retained_metadata(1, 2)}
      ])
    end

    refute_receive :unexpected_forward
  end

  test "retained plugin rejects semantic poison before forwarding" do
    parent = self()
    _handler = start_status_handler([{:notify, parent, :unexpected_forward}])

    for payload <- [
          nil,
          [],
          %{},
          %{"status" => "OK"},
          %{"status" => "bogus", "summary" => "done"},
          %{"status" => "FAILED", "summary" => "done"},
          %{"status" => " ok ", "summary" => "done"},
          %{"status" => "OK", "summary" => "   "}
        ] do
      service = %{plugin_service("semantic-poison") | message: Jason.encode!(payload)}

      assert_raise GRPC.RPCError, ~r/invalid plugin-result payload/, fn ->
        AgentGatewayServer.process_status_services([service], retained_metadata(0, 1))
      end
    end

    refute_receive :unexpected_forward
  end

  test "retained plugin ten-chunk bound includes empty containers" do
    parent = self()
    _handler = start_status_handler([{:notify, parent, :unexpected_forward}])

    chunks =
      Enum.map(0..10, fn index ->
        services = if index == 0, do: [plugin_service("first")], else: []
        {services, retained_metadata(index, 11)}
      end)

    assert_raise GRPC.RPCError, ~r/exceeds ten chunks/, fn ->
      AgentGatewayServer.process_status_stream(chunks)
    end

    refute_receive :unexpected_forward
  end

  test "flow source contract rejects payloads above six MiB" do
    oversized = %{flow_service() | message: :binary.copy(<<0>>, 6 * 1024 * 1024 + 1)}

    error =
      assert_raise GRPC.RPCError, fn ->
        AgentGatewayServer.process_status_services([oversized], metadata())
      end

    assert error.status == GRPC.Status.resource_exhausted()
    assert error.message =~ "payload_too_large"
  end

  test "unary RPC scopes retained capability negotiation by authenticated partition", context do
    agent_id = "unary-retained-#{System.unique_integer([:positive])}"

    :ok =
      AgentRegistryProxy.touch_agent(agent_id, %{
        partition_id: "default",
        capabilities: [@retained_plugin_capability]
      })

    :ok = AgentRegistryProxy.touch_agent(agent_id, %{partition_id: "other", capabilities: []})
    _handler = start_status_handler([{:error, :lane_full}, {:error, :lane_full}])

    request = %Monitoring.GatewayStatusRequest{
      agent_id: agent_id,
      services: [plugin_service("retained-unary")],
      timestamp: System.os_time(:second)
    }

    assert %Monitoring.GatewayStatusResponse{received: false, directives: []} =
             AgentGatewayServer.push_status(request, cert_stream(issue_cert_der!(agent_id, context)))

    assert %Monitoring.GatewayStatusResponse{received: true, directives: []} =
             AgentGatewayServer.push_status(
               request,
               cert_stream(issue_cert_der!(agent_id, context, "other"))
             )
  end

  test "heartbeat preserves capabilities while a later hello can clear them" do
    agent_id = "capability-state-#{System.unique_integer([:positive])}"

    :ok =
      AgentRegistryProxy.touch_agent(agent_id, %{
        partition_id: "partition-a",
        capabilities: [@retained_plugin_capability]
      })

    :ok = AgentRegistryProxy.touch_agent(agent_id, %{partition_id: "partition-a", status: :connected})

    assert AgentRegistryProxy.delivery_capabilities("partition-a", agent_id) == [
             @retained_plugin_capability
           ]

    :ok = AgentRegistryProxy.touch_agent(agent_id, %{partition_id: "partition-a", capabilities: []})
    assert AgentRegistryProxy.delivery_capabilities("partition-a", agent_id) == []
  end

  test "stream RPC rejects a chunk after final before forwarding", context do
    agent_id = "trailing-final-#{System.unique_integer([:positive])}"
    parent = self()
    _handler = start_status_handler([{:notify, parent, :unexpected_forward}])

    final = %Monitoring.GatewayStatusChunk{
      agent_id: agent_id,
      services: [flow_service()],
      chunk_index: 0,
      total_chunks: 1,
      is_final: true
    }

    trailing = %{final | services: [], is_final: false}

    assert_raise GRPC.RPCError, ~r/after the final chunk/, fn ->
      AgentGatewayServer.stream_status(
        [final, trailing],
        cert_stream(issue_cert_der!(agent_id, context))
      )
    end

    refute_receive :unexpected_forward
  end

  defp start_status_handler(replies) do
    pid = spawn(fn -> status_handler_loop(replies) end)
    Process.register(pid, ServiceRadar.StatusHandler)
    on_exit(fn -> StatusHandlerTestHelpers.kill_and_await(pid) end)
    pid
  end

  defp status_handler_loop([]) do
    receive do
      :stop -> :ok
    end
  end

  defp status_handler_loop([reply | rest]) do
    receive do
      {:"$gen_call", from, {:status_update, _status}} ->
        case reply do
          {:notify, target, message} ->
            send(target, message)
            GenServer.reply(from, :ok)

          response ->
            GenServer.reply(from, response)
        end

        status_handler_loop(rest)

      :stop ->
        :ok
    end
  end

  defp start_controlled_status_handler(parent) do
    pid = spawn(fn -> controlled_handler_loop(parent, %{}) end)
    Process.register(pid, ServiceRadar.StatusHandler)
    on_exit(fn -> StatusHandlerTestHelpers.kill_and_await(pid) end)
    pid
  end

  defp controlled_handler_loop(parent, pending) do
    receive do
      {:"$gen_call", from, {:status_update, %{service_name: service_name}}} ->
        send(parent, {:forward_started, service_name})
        controlled_handler_loop(parent, Map.put(pending, service_name, from))

      {:complete, service_name, reply} ->
        {from, pending} = Map.pop!(pending, service_name)
        GenServer.reply(from, normalize_controlled_reply(service_name, reply))
        controlled_handler_loop(parent, pending)
    end
  end

  defp normalize_controlled_reply(service_name, :ok), do: committed_result(service_name)
  defp normalize_controlled_reply(_service_name, reply), do: reply

  defp committed_result(service_name) do
    {:ok, %{directives: %{service_name => %{"reconcile_floor" => true}}}}
  end

  defp flow_service do
    %Monitoring.GatewayServiceStatus{
      service_name: "flow-attribution",
      service_type: "passive-netprobe",
      source: "flow-attribution",
      available: true,
      message: <<10, 0>>
    }
  end

  defp plugin_service(name) do
    %Monitoring.GatewayServiceStatus{
      service_name: name,
      service_type: "plugin",
      source: "plugin-result",
      available: true,
      message: Jason.encode!(%{"status" => "OK", "summary" => name})
    }
  end

  defp best_effort_service do
    %Monitoring.GatewayServiceStatus{
      service_name: "agent",
      service_type: "agent",
      source: "status",
      available: true,
      message: "ok"
    }
  end

  defp metadata(chunk_index \\ 0, total_chunks \\ 1) do
    %{
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "cert-partition",
      authenticated_partition: "cert-partition",
      source_ip: "192.0.2.10",
      kv_store_id: nil,
      timestamp: System.os_time(:second),
      agent_timestamp: 0,
      chunk_index: chunk_index,
      total_chunks: total_chunks,
      is_final: chunk_index == total_chunks - 1,
      delivery_capabilities: []
    }
  end

  defp retained_metadata(chunk_index, total_chunks) do
    chunk_index
    |> metadata(total_chunks)
    |> Map.put(:delivery_capabilities, [@retained_plugin_capability])
  end

  defp cert_stream(cert_der) do
    %GRPC.Server.Stream{adapter: PeerCertAdapter, payload: {:cert, cert_der}}
  end

  defp issue_cert_der!(component_id, context, partition_id \\ "default") do
    {:ok, bundle} =
      CertIssuer.issue_agent_bundle(
        component_id,
        partition_id,
        :agent,
        ca_cert_file: context.ca_cert,
        ca_key_file: context.ca_key,
        temp_parent_dir: context.parent_dir,
        audit_writer: nil
      )

    CertificateTestHelpers.certificate_der!(bundle.certificate_pem)
  end

  defp restore_config({:ok, config}) do
    Config.setup(
      gateway_id: config.gateway_id,
      domain: config.domain,
      capabilities: config.capabilities
    )
  end

  defp restore_config(:missing), do: :persistent_term.erase(Config)
end
