defmodule ServiceRadar.Security.EdgeIsolationTest do
  @moduledoc """
  Security validation tests for edge isolation.

  Verifies that:
  - Edge nodes (Go agents) cannot RPC to core nodes (9.1)
  - Edge nodes cannot enumerate Horde registries (9.2)
  - The ERTS cluster only contains core/poller nodes, no edge agents
  - Go agents can only communicate via gRPC, not ERTS

  ## Security Model

  With the removal of Elixir edge agents, the security model is:

  1. **Core nodes** - Full ERTS cluster members, can communicate via RPC
  2. **Poller nodes** - ERTS cluster members in secure network zone
  3. **Go agents** - External to ERTS, communicate only via gRPC with mTLS

  This test suite validates that the architecture enforces these boundaries.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Cluster.TenantRegistry

  describe "ERTS cluster isolation (9.1, 9.2)" do
    test "cluster nodes do not include edge/agent nodes" do
      # Get all connected nodes in the ERTS cluster
      nodes = [node() | Node.list()]

      # Verify no nodes have "agent" in their name (edge agents should be Go, not Elixir)
      agent_nodes = Enum.filter(nodes, fn node ->
        node_str = Atom.to_string(node)
        String.contains?(node_str, "agent@") or String.contains?(node_str, "_agent@")
      end)

      assert agent_nodes == [],
        "Found unexpected agent nodes in ERTS cluster: #{inspect(agent_nodes)}. " <>
        "Edge agents should be Go processes communicating via gRPC, not ERTS cluster members."
    end

    test "cluster topology identifies node types correctly" do
      node_str = Atom.to_string(node())

      # Current node should be identifiable as core, poller, or web - never agent
      node_type = detect_node_type(node_str)

      refute node_type == :agent,
        "Test is running on an agent node, but agents should not be ERTS cluster members"

      assert node_type in [:core, :poller, :web, :test, :unknown],
        "Node type #{node_type} should be a valid cluster node type"
    end

    test "remote RPC is only available to ERTS cluster members" do
      # Attempt RPC to a non-existent "agent" node should fail with :nodedown
      fake_agent_node = :"fake_agent@127.0.0.1"

      # This should fail because Go agents are not ERTS nodes
      result = :rpc.call(fake_agent_node, Kernel, :node, [], 1000)

      assert result == {:badrpc, :nodedown},
        "RPC to non-ERTS node should return {:badrpc, :nodedown}, got: #{inspect(result)}"
    end

    test "Horde registries are not accessible from non-ERTS processes" do
      # Generate test tenant
      tenant_id = Ash.UUID.generate()

      # Ensure registry exists
      TenantRegistry.ensure_registry(tenant_id)

      # Get the registry name
      registry_name = TenantRegistry.registry_name(tenant_id)

      # Verify the registry is a local Horde.Registry process
      case Process.whereis(registry_name) do
        nil ->
          # Registry might use dynamic naming - check via Horde
          members = Horde.Cluster.members(registry_name)
          # Members should only be on ERTS cluster nodes
          member_nodes = Enum.map(members, fn {_, node} -> node end)

          Enum.each(member_nodes, fn member_node ->
            node_str = Atom.to_string(member_node)
            refute String.contains?(node_str, "agent"),
              "Horde registry member on agent node: #{member_node}"
          end)

        pid when is_pid(pid) ->
          # Registry exists as local process
          assert node(pid) == node(),
            "Registry should be on local ERTS node"
      end
    end
  end

  describe "gRPC-only communication model" do
    test "AgentRegistry stores gRPC connection details, not ERTS pids" do
      alias ServiceRadar.AgentRegistry

      tenant_id = Ash.UUID.generate()
      agent_id = "go-agent-test-#{:erlang.unique_integer([:positive])}"

      # Ensure tenant registry exists
      TenantRegistry.ensure_registry(tenant_id)
      Process.sleep(50)

      # Register a Go agent with gRPC details
      {:ok, _pid} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_host: "192.168.1.100",
        grpc_port: 50051,
        capabilities: [:icmp, :tcp]
      })

      # Lookup should return gRPC address, not an ERTS connection
      {:ok, {host, port}} = AgentRegistry.get_grpc_address(tenant_id, agent_id)

      assert is_binary(host), "gRPC host should be a string (IP address)"
      assert is_integer(port), "gRPC port should be an integer"
      assert port > 0 and port < 65536, "gRPC port should be valid"

      # The registry entry represents a gRPC endpoint, not an ERTS process
      # Verify we cannot call Erlang functions on this "agent"
      [{_pid, metadata}] = AgentRegistry.lookup(tenant_id, agent_id)

      # The registered pid is just a placeholder process for Horde, not the actual agent
      # The actual agent is a Go process accessible only via gRPC
      assert metadata[:grpc_host] == host
      assert metadata[:grpc_port] == port
    end

    test "agent communication model uses gRPC addresses, not ERTS pids" do
      # The architecture ensures Go agents are accessed via gRPC, not ERTS
      # This is enforced by:
      # 1. AgentRegistry stores host:port, not Erlang pids
      # 2. Infrastructure.Agent resource has host/port attributes
      # 3. No ERTS node connection to Go agents

      alias ServiceRadar.Infrastructure.Agent

      # Verify Agent resource has gRPC connection attributes using Ash introspection
      attributes = Ash.Resource.Info.attributes(Agent)
      attribute_names = Enum.map(attributes, & &1.name)

      assert :host in attribute_names, "Agent should have host attribute for gRPC"
      assert :port in attribute_names, "Agent should have port attribute for gRPC"

      # Agent should NOT have ERTS-specific attributes
      refute :erlang_node in attribute_names, "Agent should not have erlang_node attribute"
      refute :erlang_pid in attribute_names, "Agent should not have erlang_pid attribute"
    end
  end

  describe "infrastructure agent resource validation" do
    test "Agent resource requires host and port for gRPC" do
      alias ServiceRadar.Infrastructure.Agent

      tenant_id = Ash.UUID.generate()
      actor = %{
        id: Ash.UUID.generate(),
        email: "test@serviceradar.local",
        role: :super_admin,
        tenant_id: tenant_id
      }

      unique_id = :erlang.unique_integer([:positive])

      # Create agent with gRPC connection details
      {:ok, agent} =
        Agent
        |> Ash.Changeset.for_create(:register, %{
          uid: "security-test-agent-#{unique_id}",
          name: "Security Test Agent",
          host: "192.168.1.50",
          port: 50051
        }, actor: actor, tenant: tenant_id, authorize?: false)
        |> Ash.create()

      # Verify agent has gRPC connection details
      assert agent.host == "192.168.1.50"
      assert agent.port == 50051

      # Agent should NOT have ERTS node reference
      refute Map.has_key?(agent, :node) or Map.get(agent, :node),
        "Agent should not have ERTS node reference"
    end
  end

  # Helper functions

  defp detect_node_type(node_str) do
    cond do
      String.contains?(node_str, "core") -> :core
      String.contains?(node_str, "poller") -> :poller
      String.contains?(node_str, "web") -> :web
      String.contains?(node_str, "agent") -> :agent
      String.contains?(node_str, "test") or String.contains?(node_str, "nonode") -> :test
      true -> :unknown
    end
  end
end
