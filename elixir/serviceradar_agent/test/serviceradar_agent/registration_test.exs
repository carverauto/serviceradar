defmodule ServiceRadarAgent.RegistrationTest do
  @moduledoc """
  Tests for agent registration with the distributed Horde registry.

  Verifies that:
  - Agent can register with the AgentRegistry
  - Registration metadata is correct
  - Status updates are reflected in the registry
  - Heartbeat mechanism works
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.Agent.RegistrationWorker
  alias ServiceRadar.AgentRegistry

  @partition_id "test-partition"
  @agent_id "test-agent-001"
  @poller_id "test-poller"
  @capabilities [:snmp, :wmi]

  describe "AgentRegistry" do
    test "can register an agent directly with the registry" do
      key = {@partition_id, "direct-agent"}
      metadata = %{
        partition_id: @partition_id,
        agent_id: "direct-agent",
        poller_id: @poller_id,
        capabilities: @capabilities,
        node: Node.self(),
        status: :available,
        registered_at: DateTime.utc_now(),
        last_heartbeat: DateTime.utc_now()
      }

      assert {:ok, _pid} = AgentRegistry.register(key, metadata)

      # Verify lookup works (returns raw list)
      result = Horde.Registry.lookup(AgentRegistry, key)
      assert [{_pid, registered_metadata}] = result
      assert registered_metadata.partition_id == @partition_id
      assert registered_metadata.agent_id == "direct-agent"
      assert registered_metadata.status == :available
    end

    test "register_agent/2 convenience function creates metadata" do
      agent_id = "convenience-agent-#{:rand.uniform(10000)}"
      agent_info = %{
        capabilities: [:icmp, :tcp],
        spiffe_id: "spiffe://test/agent/1"
      }

      assert {:ok, _pid} = AgentRegistry.register_agent(agent_id, agent_info)

      # Lookup should return metadata
      metadata = AgentRegistry.lookup(agent_id)
      assert metadata.agent_id == agent_id
      assert metadata.poller_node == Node.self()
      assert :icmp in metadata.capabilities
      assert metadata.spiffe_identity == "spiffe://test/agent/1"
      assert metadata.status == :connected
    end

    test "heartbeat/1 updates last_heartbeat" do
      agent_id = "heartbeat-agent-#{:rand.uniform(10000)}"
      AgentRegistry.register_agent(agent_id, %{capabilities: []})

      # Get initial heartbeat
      initial = AgentRegistry.lookup(agent_id)
      initial_hb = initial.last_heartbeat

      # Wait a tiny bit and heartbeat
      Process.sleep(10)
      :ok = AgentRegistry.heartbeat(agent_id)

      # Verify heartbeat updated
      updated = AgentRegistry.lookup(agent_id)
      assert DateTime.compare(updated.last_heartbeat, initial_hb) == :gt
    end

    test "all_agents returns all registered agents" do
      agent_id = "all-agents-#{:rand.uniform(10000)}"
      AgentRegistry.register_agent(agent_id, %{capabilities: [:test]})

      agents = AgentRegistry.all_agents()
      agent_ids = Enum.map(agents, & &1.agent_id)
      assert agent_id in agent_ids
    end

    test "find_agents_with_capability filters by capability" do
      agent_id = "cap-agent-#{:rand.uniform(10000)}"
      AgentRegistry.register_agent(agent_id, %{capabilities: [:special_cap]})

      # Find by capability
      agents = AgentRegistry.find_agents_with_capability(:special_cap)
      agent_ids = Enum.map(agents, & &1.agent_id)
      assert agent_id in agent_ids

      # Should not find with different capability
      agents_other = AgentRegistry.find_agents_with_capability(:nonexistent_cap)
      ids_other = Enum.map(agents_other, & &1.agent_id)
      refute agent_id in ids_other
    end

    test "unregister_agent removes agent from registry" do
      agent_id = "unregister-agent-#{:rand.uniform(10000)}"
      AgentRegistry.register_agent(agent_id, %{capabilities: []})

      # Verify registered
      assert AgentRegistry.lookup(agent_id) != nil

      # Unregister
      :ok = AgentRegistry.unregister_agent(agent_id)

      # Verify removed
      assert AgentRegistry.lookup(agent_id) == nil
    end

    test "count returns number of registered agents" do
      initial_count = AgentRegistry.count()

      agent_id = "count-agent-#{:rand.uniform(10000)}"
      AgentRegistry.register_agent(agent_id, %{capabilities: []})

      assert AgentRegistry.count() == initial_count + 1
    end
  end

  describe "RegistrationWorker" do
    # Note: The RegistrationWorker is started by ServiceRadarAgent.Application
    # so we test the already-running instance rather than starting new ones

    test "is running after application starts" do
      # The RegistrationWorker should be running
      pid = Process.whereis(RegistrationWorker)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "is registered in the AgentRegistry" do
      # The default agent from Application startup
      # Note: agent_id is generated dynamically, so we check via all_agents
      agents = AgentRegistry.all_agents()

      # Should have at least one agent registered (the one from Application startup)
      assert length(agents) >= 1

      # Find the agent from this node
      this_node_agents = Enum.filter(agents, &(&1.node == Node.self()))
      assert length(this_node_agents) >= 1

      agent = hd(this_node_agents)
      assert agent.partition_id == "default"
      assert agent.status == :available
    end

    test "get_status returns current status" do
      status = RegistrationWorker.get_status()
      assert status in [:available, :busy, :unavailable, :draining]
    end

    test "get_info returns agent information" do
      info = RegistrationWorker.get_info()
      assert info.partition_id == "default"
      assert info.node == Node.self()
      assert info.status != nil
    end
  end

  describe "stale detection" do
    test "stale?/1 returns true for old heartbeats" do
      old_metadata = %{
        last_heartbeat: DateTime.add(DateTime.utc_now(), -180, :second)
      }

      assert RegistrationWorker.stale?(old_metadata) == true
    end

    test "stale?/1 returns false for recent heartbeats" do
      recent_metadata = %{
        last_heartbeat: DateTime.utc_now()
      }

      assert RegistrationWorker.stale?(recent_metadata) == false
    end

    test "stale?/1 returns true when no heartbeat" do
      no_heartbeat = %{}
      assert RegistrationWorker.stale?(no_heartbeat) == true
    end
  end
end
