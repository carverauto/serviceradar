defmodule ServiceRadarAgentGateway.AgentGatewayServerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.ProcessRegistry
  alias ServiceRadarAgentGateway.AgentGatewayServer
  alias ServiceRadarAgentGateway.AgentRegistryProxy
  alias ServiceRadarAgentGateway.CertificateTestHelpers
  alias ServiceRadarAgentGateway.CertIssuer
  alias ServiceRadarAgentGateway.Config

  setup do
    previous_config =
      try do
        Config.get()
      rescue
        # credo:disable-for-next-line ExSlop.Check.Warning.BlanketRescue
        ArgumentError -> nil
      end

    on_exit(fn ->
      if previous_config do
        Config.setup(
          gateway_id: previous_config.gateway_id,
          domain: previous_config.domain,
          capabilities: previous_config.capabilities
        )
      end
    end)

    :ok
  end

  test "uses configured logical gateway id for external attribution" do
    Config.setup(gateway_id: "gateway-platform", domain: "demo")

    assert AgentGatewayServer.gateway_id() == "gateway-platform"
    refute AgentGatewayServer.gateway_id() == Atom.to_string(node())
  end

  describe "device_attrs_from_request/3 — gateway bridge for identity evidence" do
    # These tests guard the bridge that carries host_macs from the protobuf
    # request to AgentGatewaySync.ensure_device_for_agent/2. If host_macs is
    # accidentally removed from device_attrs_from_request the evidence silently
    # stops reaching core identity reconciliation, so each request type that
    # calls ensure_device_for_agent is covered here.

    test "unary enrollment hello (AgentHelloRequest) forwards host_macs to device attrs" do
      request = %Monitoring.AgentHelloRequest{
        agent_id: "agent-test-01",
        hostname: "node-a",
        os: "linux",
        arch: "amd64",
        host_ip: "192.0.2.10",
        host_macs: ["00:00:5e:00:53:01"]
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-1", request, "192.0.2.10")

      assert attrs.host_macs == ["00:00:5e:00:53:01"]
      assert attrs.source_ip == "192.0.2.10"
      assert attrs.partition == "partition-1"
    end

    test "control-stream hello (ControlStreamHello) forwards host_macs to device attrs" do
      hello = %Monitoring.ControlStreamHello{
        agent_id: "agent-test-02",
        hostname: "node-b",
        os: "linux",
        arch: "amd64",
        host_ip: "192.0.2.11",
        host_macs: ["00:00:5e:00:53:02", "00:00:5e:00:53:03"]
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-2", hello, "192.0.2.11")

      assert attrs.host_macs == ["00:00:5e:00:53:02", "00:00:5e:00:53:03"]
      assert attrs.source_ip == "192.0.2.11"
      assert attrs.partition == "partition-2"
    end

    test "unary enrollment hello without host_macs is backward compatible" do
      request = %Monitoring.AgentHelloRequest{
        agent_id: "agent-test-03",
        hostname: "node-c",
        host_ip: "192.0.2.12"
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-1", request, "192.0.2.12")

      assert attrs.host_macs == []
    end

    test "control-stream hello without host_macs is backward compatible" do
      hello = %Monitoring.ControlStreamHello{
        agent_id: "agent-test-04",
        hostname: "node-d",
        host_ip: "192.0.2.13"
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-2", hello, "192.0.2.13")

      assert attrs.host_macs == []
    end

    test "prefers reported host_ip over TCP peer address for source_ip" do
      request = %Monitoring.AgentHelloRequest{
        agent_id: "agent-test-05",
        host_ip: "192.0.2.20",
        host_macs: ["00:00:5e:00:53:04"]
      }

      attrs = AgentGatewayServer.device_attrs_from_request("partition-1", request, "198.51.100.5")

      assert attrs.source_ip == "192.0.2.20"
    end
  end

  describe "authenticated host identity forwarding" do
    setup do
      if !Node.alive?() do
        {_, 0} = System.cmd("epmd", ["-daemon"])
        {:ok, _} = :net_kernel.start([:gateway_host_identity_test, :shortnames])
        on_exit(fn -> :net_kernel.stop() end)
      end

      basename = "host_identity_core_#{System.unique_integer([:positive])}"

      previous_basename =
        Application.get_env(:serviceradar_agent_gateway, :cluster_core_node_basename)

      Application.put_env(:serviceradar_agent_gateway, :cluster_core_node_basename, basename)

      on_exit(fn ->
        if previous_basename do
          Application.put_env(
            :serviceradar_agent_gateway,
            :cluster_core_node_basename,
            previous_basename
          )
        else
          Application.delete_env(:serviceradar_agent_gateway, :cluster_core_node_basename)
        end
      end)

      peer =
        start_supervised!(%{
          id: :host_identity_core_peer,
          start:
            {:peer, :start_link,
             [
               %{
                 name: String.to_atom(basename),
                 connection: :standard_io,
                 args: [~c"+S", ~c"2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
               }
             ]},
          restart: :temporary
        })

      core_node = :peer.call(peer, :erlang, :node, [])
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:elixir])

      :peer.call(peer, Code, :compile_string, [
        """
        defmodule ServiceRadar.Edge.AgentGatewaySync do
          def upsert_agent(agent_id, attrs) do
            notify(:upsert_agent, [agent_id, attrs])
            :ok
          end

          def ensure_device_for_agent(agent_id, attrs) do
            notify(:ensure_device_for_agent, [agent_id, attrs])
            {:ok, "synthetic-device"}
          end

          def reconcile_agent_release(agent_id) do
            notify(:reconcile_agent_release, [agent_id])
            :ok
          end

          defp notify(function, args) do
            send(:persistent_term.get(:host_identity_test_owner), {:core_rpc, function, args})
          end
        end
        """
      ])

      :ok = :peer.call(peer, :persistent_term, :put, [:host_identity_test_owner, self()])
      assert Node.connect(core_node)

      {:ok, _} = Application.ensure_all_started(:horde)
      {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

      if !Process.whereis(ServiceRadar.PubSub) do
        start_supervised!({Phoenix.PubSub, name: ServiceRadar.PubSub})
      end

      if !Process.whereis(ProcessRegistry.registry_name()) do
        Enum.each(ProcessRegistry.child_specs(), &start_supervised!/1)
      end

      if !Process.whereis(AgentRegistryProxy), do: start_supervised!(AgentRegistryProxy)
      CertificateTestHelpers.ensure_revocation_store!()
      Config.setup(gateway_id: "gateway-host-identity", domain: "test", capabilities: [])

      parent_dir = CertificateTestHelpers.unique_tmp_dir!("gateway-host-identity")
      on_exit(fn -> File.rm_rf(parent_dir) end)
      ca_cert = Path.join(parent_dir, "root.pem")
      ca_key = Path.join(parent_dir, "root-key.pem")
      CertificateTestHelpers.generate_ca_bundle!(ca_cert, ca_key)

      agent_id = "agent-host-identity"

      {:ok, bundle} =
        CertIssuer.issue_agent_bundle(agent_id, "default", :agent,
          ca_cert_file: ca_cert,
          ca_key_file: ca_key,
          temp_parent_dir: parent_dir,
          audit_writer: nil
        )

      stream =
        bundle.certificate_pem
        |> CertificateTestHelpers.certificate_der!()
        |> CertificateTestHelpers.cert_stream()

      %{agent_id: agent_id, stream: stream}
    end

    for transport <- [:unary, :control] do
      @transport transport
      test "#{transport} hello forwards announced host MACs through core RPC", context do
        request = host_hello(@transport, context.agent_id)
        assert_enrolled(@transport, request, context.stream)

        assert_receive {:core_rpc, :upsert_agent, [agent_id, _attrs]}, 1_000
        assert agent_id == context.agent_id

        assert_receive {:core_rpc, :ensure_device_for_agent, [^agent_id, attrs]}, 1_000
        assert attrs.source_ip == "192.0.2.37"
        assert attrs.host_macs == ["02:00:00:00:01:03"]
        assert attrs.partition == "default"
        refute_receive {:core_rpc, :ensure_device_for_agent, _}
      end

      @transport transport
      test "#{transport} hello rejects a certificate identity mismatch before core RPC",
           context do
        request = host_hello(@transport, "agent-other-identity")

        error =
          assert_raise GRPC.RPCError, ~r/component_id mismatch/, fn ->
            assert_enrolled(@transport, request, context.stream)
          end

        assert error.status == GRPC.Status.permission_denied()
        refute_receive {:core_rpc, _, _}
      end
    end
  end

  defp host_hello(transport, agent_id) do
    fields = [
      agent_id: agent_id,
      host_ip: "192.0.2.37",
      host_macs: ["02:00:00:00:01:03"],
      hostname: "host01.example.com",
      os: "linux",
      arch: "amd64"
    ]

    case transport do
      :unary -> struct!(Monitoring.AgentHelloRequest, fields)
      :control -> struct!(Monitoring.ControlStreamHello, fields)
    end
  end

  defp assert_enrolled(:unary, request, stream) do
    assert %Monitoring.AgentHelloResponse{accepted: true} =
             AgentGatewayServer.hello(request, stream)
  end

  defp assert_enrolled(:control, request, stream) do
    assert :ok =
             AgentGatewayServer.control_stream(
               [%Monitoring.ControlStreamRequest{payload: {:hello, request}}],
               stream
             )
  end
end
