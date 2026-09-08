defmodule ServiceRadarAgentGateway.AgentRetainedDeliveryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.ProcessRegistry
  alias ServiceRadarAgentGateway.AgentGatewayServer
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.Config
  alias ServiceRadarAgentGateway.ControlStreamSession
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

    if !Process.whereis(ProcessRegistry.registry_name()) do
      Enum.each(ProcessRegistry.child_specs(), &start_supervised!/1)
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

  test "stream RPC rejects an excessive declared chunk count before consuming its tail", context do
    agent_id = "chunk-count-#{System.unique_integer([:positive])}"
    parent = self()

    first = status_chunk(agent_id, 0, 5_001, [], [])

    tail =
      Stream.map([:sentinel], fn :sentinel ->
        send(parent, :excessive_chunk_tail_consumed)
        status_chunk(agent_id, 1, 5_001, [], [])
      end)

    assert_raise GRPC.RPCError, ~r/exceeds 5000 chunks/, fn ->
      AgentGatewayServer.stream_status(
        Stream.concat([first], tail),
        cert_stream(issue_cert_der!(agent_id, context))
      )
    end

    refute_receive :excessive_chunk_tail_consumed
  end

  test "stream RPC applies the retained ten-chunk bound when a later chunk reveals the source", context do
    agent_id = "retained-chunk-count-#{System.unique_integer([:positive])}"
    parent = self()

    prefix = [
      status_chunk(agent_id, 0, 11, [], [@retained_plugin_capability]),
      status_chunk(agent_id, 1, 11, [plugin_service("first")], [@retained_plugin_capability])
    ]

    tail =
      Stream.map(2..10, fn index ->
        send(parent, :retained_chunk_tail_consumed)

        status_chunk(
          agent_id,
          index,
          11,
          [],
          [@retained_plugin_capability],
          index == 10
        )
      end)

    assert_raise GRPC.RPCError, ~r/exceeds ten chunks/, fn ->
      AgentGatewayServer.stream_status(
        Stream.concat(prefix, tail),
        cert_stream(issue_cert_der!(agent_id, context))
      )
    end

    refute_receive :retained_chunk_tail_consumed
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

  test "live control-session hello is the capability authority" do
    agent_id = "live-capability-state-#{System.unique_integer([:positive])}"
    partition_id = "partition-a"
    identity = control_identity_context(agent_id, partition_id)

    :ok = AgentRegistryProxy.touch_agent(agent_id, %{partition_id: partition_id, capabilities: []})

    session = start_temporary_control_session!()
    assert :ok = ControlStreamSession.register(session, agent_id, partition_id, [], identity)

    ControlStreamSession.handle_message(
      session,
      control_hello(agent_id, [@retained_plugin_capability]),
      identity
    )

    assert_control_capabilities(session, partition_id, agent_id, [@retained_plugin_capability])

    assert AgentRegistryProxy.delivery_capabilities(partition_id, agent_id) == [
             @retained_plugin_capability
           ]

    :ok =
      AgentRegistryProxy.touch_agent(agent_id, %{
        partition_id: partition_id,
        capabilities: [@retained_plugin_capability]
      })

    ControlStreamSession.handle_message(session, control_hello(agent_id, []), identity)
    assert_control_capabilities(session, partition_id, agent_id, [])
    assert AgentRegistryProxy.delivery_capabilities(partition_id, agent_id) == []
    kill_control_session!(session, partition_id, agent_id)
    assert AgentRegistryProxy.delivery_capabilities(partition_id, agent_id) == []
  end

  test "verified retained capability remains authoritative after the control session ends", context do
    agent_id = "ended-session-capability-#{System.unique_integer([:positive])}"
    partition_id = "default"
    identity = control_identity_context(agent_id, partition_id)

    :ok = AgentRegistryProxy.touch_agent(agent_id, %{partition_id: partition_id, capabilities: []})

    session = start_temporary_control_session!()
    assert :ok = ControlStreamSession.register(session, agent_id, partition_id, [], identity)

    ControlStreamSession.handle_message(
      session,
      control_hello(agent_id, [@retained_plugin_capability]),
      identity
    )

    assert_control_capabilities(session, partition_id, agent_id, [@retained_plugin_capability])
    kill_control_session!(session, partition_id, agent_id)

    _handler = start_status_handler([{:error, :lane_full}])

    request = %Monitoring.GatewayStatusRequest{
      agent_id: agent_id,
      services: [plugin_service("retained-after-control")],
      timestamp: System.os_time(:second)
    }

    assert %Monitoring.GatewayStatusResponse{received: false, directives: []} =
             AgentGatewayServer.push_status(request, cert_stream(issue_cert_der!(agent_id, context)))
  end

  test "live control-session capabilities survive an independent proxy restart" do
    agent_id = "proxy-restart-capability-#{System.unique_integer([:positive])}"
    partition_id = "partition-a"
    identity = control_identity_context(agent_id, partition_id)

    :ok =
      AgentRegistryProxy.touch_agent(agent_id, %{
        partition_id: partition_id,
        capabilities: []
      })

    session = start_temporary_control_session!()

    assert :ok =
             ControlStreamSession.register(
               session,
               agent_id,
               partition_id,
               [@retained_plugin_capability],
               identity
             )

    assert_control_capabilities(session, partition_id, agent_id, [@retained_plugin_capability])
    restart_agent_registry_proxy!()
    kill_control_session!(session, partition_id, agent_id)

    assert AgentRegistryProxy.delivery_capabilities(partition_id, agent_id) == [
             @retained_plugin_capability
           ]
  end

  test "stream RPC preserves forward order with linear chunk accumulation", context do
    agent_id = "stream-order-#{System.unique_integer([:positive])}"
    _handler = start_recording_status_handler(self())

    chunks = [
      status_chunk(agent_id, 0, 2, [best_effort_service("first")], []),
      status_chunk(agent_id, 1, 2, [best_effort_service("second")], [], true)
    ]

    assert %Monitoring.GatewayStatusResponse{received: true, directives: directives} =
             AgentGatewayServer.stream_status(
               chunks,
               cert_stream(issue_cert_der!(agent_id, context))
             )

    assert directives == []
    assert_receive {:forwarded, "first"}
    assert_receive {:forwarded, "second"}
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

  defp start_recording_status_handler(parent) do
    pid = spawn(fn -> recording_status_handler_loop(parent) end)
    Process.register(pid, ServiceRadar.StatusHandler)
    on_exit(fn -> StatusHandlerTestHelpers.kill_and_await(pid) end)
    pid
  end

  defp recording_status_handler_loop(parent) do
    receive do
      {:"$gen_cast", {:status_update, %{service_name: service_name}}} ->
        send(parent, {:forwarded, service_name})
        recording_status_handler_loop(parent)

      :stop ->
        :ok
    end
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

  defp best_effort_service(name \\ "agent") do
    %Monitoring.GatewayServiceStatus{
      service_name: name,
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

  defp status_chunk(agent_id, chunk_index, total_chunks, services, capabilities, is_final \\ false) do
    %Monitoring.GatewayStatusChunk{
      agent_id: agent_id,
      services: services,
      capabilities: capabilities,
      chunk_index: chunk_index,
      total_chunks: total_chunks,
      is_final: is_final
    }
  end

  defp control_hello(agent_id, capabilities) do
    %Monitoring.ControlStreamRequest{
      payload:
        {:hello,
         %Monitoring.ControlStreamHello{
           agent_id: agent_id,
           capabilities: capabilities
         }}
    }
  end

  defp control_identity_context(agent_id, partition_id) do
    %{
      component_id: agent_id,
      partition_id: partition_id,
      component_type: :agent,
      cert_fingerprint_sha256: "synthetic-fingerprint-#{agent_id}-#{partition_id}"
    }
  end

  defp assert_control_capabilities(session, partition_id, agent_id, capabilities, attempts \\ 40)

  defp assert_control_capabilities(_session, _partition_id, _agent_id, _capabilities, 0) do
    flunk("timed out waiting for control-session capability evidence")
  end

  defp assert_control_capabilities(session, partition_id, agent_id, capabilities, attempts) do
    evidence = ProcessRegistry.lookup({:agent_control, partition_id, agent_id, node()})

    if Enum.any?(evidence, fn
         {^session, %{capabilities: ^capabilities}} -> true
         _entry -> false
       end) do
      :ok
    else
      Process.sleep(25)
      assert_control_capabilities(session, partition_id, agent_id, capabilities, attempts - 1)
    end
  end

  defp assert_control_session_absent(partition_id, agent_id, attempts \\ 40)

  defp assert_control_session_absent(_partition_id, _agent_id, 0) do
    flunk("timed out waiting for control-session evidence removal")
  end

  defp assert_control_session_absent(partition_id, agent_id, attempts) do
    case ProcessRegistry.lookup({:agent_control, partition_id, agent_id, node()}) do
      [] ->
        :ok

      _entries ->
        Process.sleep(25)
        assert_control_session_absent(partition_id, agent_id, attempts - 1)
    end
  end

  defp start_temporary_control_session! do
    {ControlStreamSession, stream: nil}
    |> Supervisor.child_spec(restart: :temporary)
    |> start_supervised!()
  end

  defp kill_control_session!(session, partition_id, agent_id) do
    monitor = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :killed}, 1_000
    assert_control_session_absent(partition_id, agent_id)
  end

  defp restart_agent_registry_proxy! do
    previous = Process.whereis(AgentRegistryProxy)
    monitor = Process.monitor(previous)
    Process.exit(previous, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^previous, :killed}, 1_000
    assert_new_agent_registry_proxy(previous)
  end

  defp assert_new_agent_registry_proxy(previous, attempts \\ 40)

  defp assert_new_agent_registry_proxy(_previous, 0) do
    flunk("timed out waiting for AgentRegistryProxy restart")
  end

  defp assert_new_agent_registry_proxy(previous, attempts) do
    case Process.whereis(AgentRegistryProxy) do
      current when is_pid(current) and current != previous ->
        :ok

      _other ->
        Process.sleep(25)
        assert_new_agent_registry_proxy(previous, attempts - 1)
    end
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
