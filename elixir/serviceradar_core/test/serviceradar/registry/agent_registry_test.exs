defmodule ServiceRadar.AgentRegistryTest do
  @moduledoc """
  Tests for AgentRegistry functionality including gRPC address resolution.

  Verifies that:
  - Agents can be registered with gRPC connection details
  - gRPC addresses can be looked up by agent ID
  - Registry properly supports gateway discovery of agents
  - Multi-tenant isolation works for registry operations
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Cluster.TenantRegistry

  @moduletag :database

  setup do
    unique_id = :erlang.unique_integer([:positive])
    tenant_a_id = Ash.UUID.generate()
    tenant_b_id = Ash.UUID.generate()

    # Ensure tenant registries exist
    TenantRegistry.ensure_registry(tenant_a_id)
    TenantRegistry.ensure_registry(tenant_b_id)

    # Wait for registry processes to start
    Process.sleep(100)

    {:ok,
      tenant_a_id: tenant_a_id,
      tenant_b_id: tenant_b_id,
      unique_id: unique_id
    }
  end

  describe "register_agent/3" do
    test "registers agent with gRPC details", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-reg-#{unique_id}"

      result = AgentRegistry.register_agent(tenant_id, agent_id, %{
        partition_id: "partition-1",
        grpc_host: "192.168.1.100",
        grpc_port: 50051,
        capabilities: [:icmp, :tcp],
        status: :connected
      })

      assert {:ok, _pid} = result
    end

    test "registers agent and can be looked up", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-lookup-#{unique_id}"

      {:ok, _pid} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_host: "10.0.0.50",
        grpc_port: 50052,
        capabilities: [:http]
      })

      entries = AgentRegistry.lookup(tenant_id, agent_id)
      assert length(entries) == 1

      [{_pid, metadata}] = entries
      assert metadata[:agent_id] == agent_id
      assert metadata[:grpc_host] == "10.0.0.50"
      assert metadata[:grpc_port] == 50052
    end

    test "stores tenant_id in metadata", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-tenant-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_host: "192.168.1.10",
        grpc_port: 50051
      })

      [{_pid, metadata}] = AgentRegistry.lookup(tenant_id, agent_id)
      assert metadata[:tenant_id] == tenant_id
    end

    test "stores capabilities", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-caps-#{unique_id}"
      capabilities = [:icmp, :tcp, :http, :snmp]

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_host: "192.168.1.11",
        grpc_port: 50051,
        capabilities: capabilities
      })

      [{_pid, metadata}] = AgentRegistry.lookup(tenant_id, agent_id)
      assert metadata[:capabilities] == capabilities
    end

    test "legacy register without tenant_id fails", %{unique_id: unique_id} do
      agent_id = "agent-no-tenant-#{unique_id}"

      result = AgentRegistry.register_agent(agent_id, %{
        grpc_host: "192.168.1.12",
        grpc_port: 50051
      })

      assert result == {:error, :tenant_id_required}
    end
  end

  describe "get_grpc_address/2" do
    test "returns host and port for registered agent", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-grpc-#{unique_id}"
      host = "192.168.1.100"
      port = 50051

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_host: host,
        grpc_port: port
      })

      assert {:ok, {^host, ^port}} = AgentRegistry.get_grpc_address(tenant_id, agent_id)
    end

    test "returns not_found for unregistered agent", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-not-exist-#{unique_id}"
      assert {:error, :not_found} = AgentRegistry.get_grpc_address(tenant_id, agent_id)
    end

    test "returns no_grpc_address if host is missing", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-no-host-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_port: 50051
        # No grpc_host
      })

      assert {:error, :no_grpc_address} = AgentRegistry.get_grpc_address(tenant_id, agent_id)
    end

    test "returns no_grpc_address if port is missing", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-no-port-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_host: "192.168.1.101"
        # No grpc_port
      })

      assert {:error, :no_grpc_address} = AgentRegistry.get_grpc_address(tenant_id, agent_id)
    end
  end

  describe "find_agents_with_grpc/1" do
    test "returns only agents with complete gRPC addresses", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      # Agent with gRPC
      {:ok, _} = AgentRegistry.register_agent(tenant_id, "agent-grpc-a-#{unique_id}", %{
        grpc_host: "192.168.1.100",
        grpc_port: 50051
      })

      # Agent without gRPC
      {:ok, _} = AgentRegistry.register_agent(tenant_id, "agent-no-grpc-#{unique_id}", %{
        partition_id: "partition-1"
      })

      # Agent with only host
      {:ok, _} = AgentRegistry.register_agent(tenant_id, "agent-partial-#{unique_id}", %{
        grpc_host: "192.168.1.102"
      })

      agents = AgentRegistry.find_agents_with_grpc(tenant_id)

      # Should only include the agent with complete gRPC details
      assert length(agents) >= 1
      assert Enum.any?(agents, &(&1[:agent_id] == "agent-grpc-a-#{unique_id}"))
      refute Enum.any?(agents, &(&1[:agent_id] == "agent-no-grpc-#{unique_id}"))
      refute Enum.any?(agents, &(&1[:agent_id] == "agent-partial-#{unique_id}"))
    end
  end

  describe "find_agents_with_capability/2" do
    test "returns agents with specified capability", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      {:ok, _} = AgentRegistry.register_agent(tenant_id, "agent-icmp-#{unique_id}", %{
        grpc_host: "192.168.1.100",
        grpc_port: 50051,
        capabilities: [:icmp, :tcp]
      })

      {:ok, _} = AgentRegistry.register_agent(tenant_id, "agent-http-#{unique_id}", %{
        grpc_host: "192.168.1.101",
        grpc_port: 50051,
        capabilities: [:http, :tcp]
      })

      {:ok, _} = AgentRegistry.register_agent(tenant_id, "agent-snmp-#{unique_id}", %{
        grpc_host: "192.168.1.102",
        grpc_port: 50051,
        capabilities: [:snmp]
      })

      icmp_agents = AgentRegistry.find_agents_with_capability(tenant_id, :icmp)
      tcp_agents = AgentRegistry.find_agents_with_capability(tenant_id, :tcp)
      snmp_agents = AgentRegistry.find_agents_with_capability(tenant_id, :snmp)

      assert length(icmp_agents) >= 1
      assert length(tcp_agents) >= 2
      assert length(snmp_agents) >= 1
    end
  end

  describe "find_agents_for_partition/2" do
    test "returns agents in specified partition", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_p1 = "agent-p1-#{unique_id}"
      agent_p2 = "agent-p2-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_p1, %{
        partition_id: "partition-1",
        grpc_host: "192.168.1.100",
        grpc_port: 50051
      })

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_p2, %{
        partition_id: "partition-2",
        grpc_host: "192.168.1.101",
        grpc_port: 50051
      })

      # Allow registry to sync
      Process.sleep(50)

      # Verify both are findable in the tenant
      all_agents = AgentRegistry.find_agents_for_tenant(tenant_id)
      assert Enum.any?(all_agents, &(&1[:agent_id] == agent_p1))
      assert Enum.any?(all_agents, &(&1[:agent_id] == agent_p2))

      # Now test partition filtering
      p1_agents = AgentRegistry.find_agents_for_partition(tenant_id, "partition-1")
      assert Enum.any?(p1_agents, &(&1[:agent_id] == agent_p1))
    end
  end

  describe "multi-tenant isolation" do
    test "agents in tenant A are not visible in tenant B", %{
      tenant_a_id: tenant_a_id,
      tenant_b_id: tenant_b_id,
      unique_id: unique_id
    } do
      agent_a = "agent-iso-a-#{unique_id}"
      agent_b = "agent-iso-b-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(tenant_a_id, agent_a, %{
        grpc_host: "192.168.1.100",
        grpc_port: 50051
      })

      {:ok, _} = AgentRegistry.register_agent(tenant_b_id, agent_b, %{
        grpc_host: "192.168.2.100",
        grpc_port: 50051
      })

      # Tenant A queries
      agents_a = AgentRegistry.find_agents_for_tenant(tenant_a_id)
      assert Enum.any?(agents_a, &(&1[:agent_id] == agent_a))
      refute Enum.any?(agents_a, &(&1[:agent_id] == agent_b))

      # Tenant B queries
      agents_b = AgentRegistry.find_agents_for_tenant(tenant_b_id)
      assert Enum.any?(agents_b, &(&1[:agent_id] == agent_b))
      refute Enum.any?(agents_b, &(&1[:agent_id] == agent_a))
    end

    test "gRPC address lookup respects tenant isolation", %{
      tenant_a_id: tenant_a_id,
      tenant_b_id: tenant_b_id,
      unique_id: unique_id
    } do
      agent_a = "agent-grpc-iso-a-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(tenant_a_id, agent_a, %{
        grpc_host: "192.168.1.100",
        grpc_port: 50051
      })

      # Lookup with correct tenant works
      assert {:ok, {"192.168.1.100", 50051}} = AgentRegistry.get_grpc_address(tenant_a_id, agent_a)

      # Lookup with wrong tenant fails
      assert {:error, :not_found} = AgentRegistry.get_grpc_address(tenant_b_id, agent_a)
    end
  end

  describe "unregister_agent/2" do
    test "removes agent from registry", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-unreg-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_host: "192.168.1.100",
        grpc_port: 50051
      })

      # Verify registered
      assert length(AgentRegistry.lookup(tenant_id, agent_id)) == 1

      # Unregister
      :ok = AgentRegistry.unregister_agent(tenant_id, agent_id)

      # Verify removed
      assert AgentRegistry.lookup(tenant_id, agent_id) == []
    end
  end

  describe "heartbeat/2" do
    test "updates last_heartbeat timestamp", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-hb-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_host: "192.168.1.100",
        grpc_port: 50051
      })

      [{_pid, original}] = AgentRegistry.lookup(tenant_id, agent_id)
      original_hb = original[:last_heartbeat]

      # Wait a bit
      Process.sleep(100)

      # Send heartbeat
      :ok = AgentRegistry.heartbeat(tenant_id, agent_id)

      [{_pid, updated}] = AgentRegistry.lookup(tenant_id, agent_id)
      new_hb = updated[:last_heartbeat]

      # Heartbeat should be updated
      assert DateTime.compare(new_hb, original_hb) in [:eq, :gt]
    end

    test "returns error for non-existent agent", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-hb-noexist-#{unique_id}"
      assert :error = AgentRegistry.heartbeat(tenant_id, agent_id)
    end
  end

  describe "count/1" do
    test "registered agents are countable", %{tenant_a_id: tenant_id, unique_id: unique_id} do
      agent_id = "agent-count-#{unique_id}"

      {:ok, _} = AgentRegistry.register_agent(tenant_id, agent_id, %{
        grpc_host: "192.168.1.100",
        grpc_port: 50051
      })

      # Allow registry to sync
      Process.sleep(50)

      # Verify agent can be found via lookup
      entries = AgentRegistry.lookup(tenant_id, agent_id)
      assert length(entries) == 1

      # And via find_agents_for_tenant
      agents = AgentRegistry.find_agents_for_tenant(tenant_id)
      assert Enum.any?(agents, &(&1[:agent_id] == agent_id))
    end
  end
end
