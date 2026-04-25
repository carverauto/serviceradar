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
  alias ServiceRadar.Inventory.DeviceIdentifier

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    unique_id = :erlang.unique_integer([:positive])
    agent_id = "test-agent-#{unique_id}"
    actor = SystemActor.system(:test)

    {:ok, agent_id: agent_id, actor: actor, unique_id: unique_id}
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
      {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)
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
      {:ok, device} = Device.get_by_uid(device_uid2, false, actor: actor)
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

      {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)
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

      {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)
      assert "sysmon" in device.discovery_sources
    end

    test "registers agent_id in device_identifiers", %{
      unique_id: unique_id,
      actor: actor
    } do
      agent_id = "agent-id-reg-#{unique_id}"

      attrs = %{
        hostname: "host-id-reg",
        source_ip: "10.99.#{rem(unique_id, 255)}.1",
        partition: "default",
        capabilities: ["sysmon"]
      }

      {:ok, _device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

      # Verify agent_id was registered as a strong identifier
      query =
        Ash.Query.for_read(DeviceIdentifier, :lookup, %{
          identifier_type: :agent_id,
          identifier_value: agent_id,
          partition: "default"
        })

      assert {:ok, [identifier]} = Ash.read(query, actor: actor)
      assert identifier.confidence == :strong
    end

    test "re-enrollment from different IP resolves to same device", %{
      unique_id: unique_id,
      actor: actor
    } do
      agent_id = "agent-reip-#{unique_id}"

      # First enrollment from IP A
      attrs_a = %{
        hostname: "k8s-pod-a",
        source_ip: "10.42.#{rem(unique_id, 255)}.10",
        partition: "default",
        capabilities: ["sysmon"]
      }

      {:ok, device_uid_a} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs_a)

      # Second enrollment from different IP B (simulating pod restart)
      attrs_b = %{
        hostname: "k8s-pod-b",
        source_ip: "10.42.#{rem(unique_id, 255)}.20",
        partition: "default",
        capabilities: ["sysmon"]
      }

      {:ok, device_uid_b} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs_b)

      # Should resolve to the same device despite different IPs
      assert device_uid_a == device_uid_b

      # Verify device is updated with new IP
      {:ok, device} = Device.get_by_uid(device_uid_b, false, actor: actor)
      assert device.ip == "10.42.#{rem(unique_id, 255)}.20"
    end

    test "adopts existing active-IP device when reenrollment IP is already owned", %{
      unique_id: unique_id
    } do
      agent_id = "agent-active-ip-conflict-#{unique_id}"
      conflict_owner_agent_id = "agent-active-ip-owner-#{unique_id}"
      original_ip = "10.88.#{rem(unique_id, 200)}.10"
      conflict_ip = "10.88.#{rem(unique_id, 200)}.20"

      :ok =
        AgentGatewaySync.upsert_agent(conflict_owner_agent_id, %{
          host: conflict_ip,
          capabilities: ["sysmon"]
        })

      {:ok, conflict_device_uid} =
        AgentGatewaySync.ensure_device_for_agent(conflict_owner_agent_id, %{
          hostname: "existing-active-ip-owner-#{unique_id}",
          source_ip: conflict_ip,
          partition: "default",
          capabilities: ["sysmon"]
        })

      :ok =
        AgentGatewaySync.upsert_agent(agent_id, %{host: original_ip, capabilities: ["sysmon"]})

      {:ok, original_device_uid} =
        AgentGatewaySync.ensure_device_for_agent(agent_id, %{
          hostname: "agent-active-ip-original-#{unique_id}",
          source_ip: original_ip,
          partition: "default",
          capabilities: ["sysmon"]
        })

      assert {:ok, adopted_device_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "agent-active-ip-adopted-#{unique_id}",
                 source_ip: conflict_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      assert adopted_device_uid == conflict_device_uid
      refute adopted_device_uid == original_device_uid
    end

    test "marks older duplicate-prefix agent unavailable when reenrollment resolves to same device",
         %{
           unique_id: unique_id,
           actor: actor
         } do
      old_agent_id = "agent-dusk-#{unique_id}"
      replacement_agent_id = "agent-agent-dusk-#{unique_id}"
      source_ip = "192.168.50.#{rem(unique_id, 200) + 10}"

      attrs = %{
        hostname: "dusk-#{unique_id}",
        source_ip: source_ip,
        partition: "default",
        capabilities: ["sysmon"]
      }

      :ok =
        AgentGatewaySync.upsert_agent(old_agent_id, %{host: source_ip, capabilities: ["sysmon"]})

      {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(old_agent_id, attrs)

      :ok =
        AgentGatewaySync.upsert_agent(replacement_agent_id, %{
          host: source_ip,
          capabilities: ["sysmon"]
        })

      assert {:ok, ^device_uid} =
               AgentGatewaySync.ensure_device_for_agent(replacement_agent_id, attrs)

      {:ok, old_agent} = Agent.get_by_uid(old_agent_id, actor: actor)
      {:ok, replacement_agent} = Agent.get_by_uid(replacement_agent_id, actor: actor)

      assert old_agent.status == :unavailable
      assert replacement_agent.status == :connected
      assert replacement_agent.device_uid == device_uid
    end

    test "marks older renamed agent unavailable when reenrollment resolves to same device",
         %{
           unique_id: unique_id,
           actor: actor
         } do
      old_agent_id = "agent-dusk-#{unique_id}"
      replacement_agent_id = "agent-dusk01-#{unique_id}"
      source_ip = "192.168.60.#{rem(unique_id, 200) + 10}"

      attrs = %{
        hostname: "dusk-#{unique_id}",
        source_ip: source_ip,
        partition: "default",
        capabilities: ["sysmon"]
      }

      :ok =
        AgentGatewaySync.upsert_agent(old_agent_id, %{host: source_ip, capabilities: ["sysmon"]})

      {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(old_agent_id, attrs)

      :ok =
        AgentGatewaySync.upsert_agent(replacement_agent_id, %{
          host: source_ip,
          capabilities: ["sysmon"]
        })

      assert {:ok, ^device_uid} =
               AgentGatewaySync.ensure_device_for_agent(replacement_agent_id, attrs)

      {:ok, old_agent} = Agent.get_by_uid(old_agent_id, actor: actor)
      {:ok, replacement_agent} = Agent.get_by_uid(replacement_agent_id, actor: actor)

      assert old_agent.status == :unavailable
      assert replacement_agent.status == :connected
      assert replacement_agent.device_uid == device_uid
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

    test "heartbeat restores unavailable agent back to connected", %{
      unique_id: unique_id,
      actor: actor
    } do
      agent_id = "recover-agent-#{unique_id}"

      :ok = AgentGatewaySync.upsert_agent(agent_id, %{name: "Recover Agent", host: "10.10.10.10"})

      {:ok, agent} = Agent.get_by_uid(agent_id, actor: actor)

      {:ok, _} =
        agent
        |> Ash.Changeset.for_update(:mark_unavailable, %{reason: "test"})
        |> Ash.update(actor: actor)

      :ok =
        AgentGatewaySync.heartbeat_agent(agent_id, %{
          config_source: :remote,
          is_healthy: true
        })

      {:ok, recovered} = Agent.get_by_uid(agent_id, actor: actor)
      assert recovered.status == :connected
      assert recovered.is_healthy == true
      assert recovered.config_source == :remote
    end
  end
end
