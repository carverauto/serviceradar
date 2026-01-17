defmodule ServiceRadar.Edge.AgentGatewaySyncTest do
  @moduledoc """
  Tests for the AgentGatewaySync module.

  Tests agent enrollment, device creation, and heartbeat operations.
  Tests run against the schema determined by PostgreSQL search_path.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    agent_id = "test-agent-#{unique_id}"
    actor = SystemActor.system(:test)

    {:ok,
     agent_id: agent_id,
     actor: actor,
     unique_id: unique_id}
  end

  describe "ensure_device_for_agent/2" do
    test "creates device for new agent", %{
      agent_id: agent_id,
      actor: actor
    } do
      attrs = %{
        hostname: "test-host-#{agent_id}",
        os: "linux",
        arch: "amd64",
        partition: "default",
        source_ip: "192.168.1.100",
        capabilities: ["sysmon", "icmp"]
      }

      result = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

      assert {:ok, device_uid} = result
      assert is_binary(device_uid)

      # Verify device was created
      {:ok, device} = Device.get_by_uid(device_uid, actor: actor)
      assert device.hostname == "test-host-#{agent_id}"
      assert device.ip == "192.168.1.100"
      assert device.agent_id == agent_id
      assert "agent" in device.discovery_sources
      assert "sysmon" in device.discovery_sources
    end

    test "updates existing device on subsequent enrollment", %{
      agent_id: agent_id,
      actor: actor
    } do
      attrs = %{
        hostname: "test-host-original",
        os: "linux",
        arch: "amd64",
        partition: "default",
        source_ip: "192.168.1.101",
        capabilities: ["icmp"]
      }

      # First enrollment
      {:ok, device_uid1} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

      # Second enrollment with updated info
      updated_attrs = %{
        hostname: "test-host-updated",
        os: "linux",
        arch: "arm64",
        partition: "default",
        source_ip: "192.168.1.102",
        capabilities: ["sysmon", "icmp", "sweep"]
      }

      {:ok, device_uid2} = AgentGatewaySync.ensure_device_for_agent(agent_id, updated_attrs)

      # Should be the same device
      assert device_uid1 == device_uid2

      # Verify device was updated
      {:ok, device} = Device.get_by_uid(device_uid2, actor: actor)
      assert device.hostname == "test-host-updated"
      assert device.ip == "192.168.1.102"
      assert "sysmon" in device.discovery_sources
    end

    test "sets discovery_sources based on capabilities", %{
      unique_id: unique_id,
      actor: actor
    } do
      # Agent without sysmon capability
      agent_id_no_sysmon = "agent-no-sysmon-#{unique_id}"

      attrs_no_sysmon = %{
        hostname: "host-no-sysmon",
        source_ip: "10.0.0.1",
        capabilities: ["icmp", "tcp"]
      }

      {:ok, device_uid} =
        AgentGatewaySync.ensure_device_for_agent(agent_id_no_sysmon, attrs_no_sysmon)

      {:ok, device} = Device.get_by_uid(device_uid, actor: actor)
      assert "agent" in device.discovery_sources
      refute "sysmon" in device.discovery_sources
    end

    test "handles agent with system_monitor capability", %{
      unique_id: unique_id,
      actor: actor
    } do
      agent_id = "agent-system-monitor-#{unique_id}"

      attrs = %{
        hostname: "host-system-monitor",
        source_ip: "10.0.0.2",
        capabilities: ["system_monitor", "icmp"]
      }

      {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

      {:ok, device} = Device.get_by_uid(device_uid, actor: actor)
      assert "sysmon" in device.discovery_sources
    end
  end

  describe "upsert_agent/2" do
    test "creates new agent record", %{
      agent_id: agent_id,
      actor: actor
    } do
      attrs = %{
        name: "Test Agent",
        version: "1.0.0",
        capabilities: ["icmp", "tcp"],
        host: "192.168.1.50",
        port: 50_051
      }

      result = AgentGatewaySync.upsert_agent(agent_id, attrs)

      assert :ok = result

      # Verify agent was created
      {:ok, agent} = Agent.get_by_uid(agent_id, actor: actor)
      assert agent.name == "Test Agent"
      assert agent.version == "1.0.0"
      assert "icmp" in agent.capabilities
      assert "tcp" in agent.capabilities
    end

    test "updates existing agent record", %{
      agent_id: agent_id,
      actor: actor
    } do
      # Create initial agent
      initial_attrs = %{
        name: "Initial Name",
        version: "1.0.0",
        capabilities: ["icmp"]
      }

      :ok = AgentGatewaySync.upsert_agent(agent_id, initial_attrs)

      # Update agent
      updated_attrs = %{
        name: "Updated Name",
        version: "2.0.0",
        capabilities: ["icmp", "tcp", "sysmon"]
      }

      :ok = AgentGatewaySync.upsert_agent(agent_id, updated_attrs)

      # Verify agent was updated
      {:ok, agent} = Agent.get_by_uid(agent_id, actor: actor)
      assert agent.name == "Updated Name"
      assert agent.version == "2.0.0"
      assert "sysmon" in agent.capabilities
    end
  end

  describe "heartbeat_agent/2" do
    test "updates agent heartbeat with config_source", %{
      agent_id: agent_id,
      actor: actor
    } do
      # First create the agent
      create_attrs = %{
        name: "Heartbeat Test Agent",
        version: "1.0.0",
        capabilities: ["sysmon"]
      }

      :ok = AgentGatewaySync.upsert_agent(agent_id, create_attrs)

      # Send heartbeat with config_source
      heartbeat_attrs = %{
        capabilities: ["sysmon", "icmp"],
        is_healthy: true,
        config_source: :remote
      }

      :ok = AgentGatewaySync.heartbeat_agent(agent_id, heartbeat_attrs)

      # Verify agent was updated
      {:ok, agent} = Agent.get_by_uid(agent_id, actor: actor)
      assert agent.is_healthy == true
      assert agent.config_source == :remote
      assert "sysmon" in agent.capabilities
      assert "icmp" in agent.capabilities
    end

    test "heartbeat creates agent if not exists", %{
      unique_id: unique_id,
      actor: actor
    } do
      new_agent_id = "new-heartbeat-agent-#{unique_id}"

      attrs = %{
        capabilities: ["icmp"],
        is_healthy: true
      }

      :ok = AgentGatewaySync.heartbeat_agent(new_agent_id, attrs)

      # Verify agent was created
      {:ok, agent} = Agent.get_by_uid(new_agent_id, actor: actor)
      assert agent.is_healthy == true
    end

    test "heartbeat with local config_source", %{
      unique_id: unique_id,
      actor: actor
    } do
      agent_id = "local-config-agent-#{unique_id}"

      # Create agent first
      :ok = AgentGatewaySync.upsert_agent(agent_id, %{name: "Local Config Agent"})

      # Heartbeat with local config
      :ok =
        AgentGatewaySync.heartbeat_agent(agent_id, %{
          config_source: :local,
          is_healthy: true
        })

      {:ok, agent} = Agent.get_by_uid(agent_id, actor: actor)
      assert agent.config_source == :local
    end
  end

end
