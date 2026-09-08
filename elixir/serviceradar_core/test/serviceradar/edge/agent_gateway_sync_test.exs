defmodule ServiceRadar.Edge.AgentGatewaySyncTest do
  @moduledoc """
  Tests for the AgentGatewaySync module.

  Tests agent enrollment, device creation, and heartbeat operations.
  Tests run against the schema determined by PostgreSQL search_path.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Infrastructure.Gateway
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.SweepJobs.SweepGroup

  require Ash.Query

  @moduletag :integration
  @release_public_key "ot8W1BsqSvXV7KEjLL+RkQz106lzcIJNCY91OXSqBpk="
  @release_private_key "kRqU4UnTUPjychwJGH4ZdsuijaxuGUNFPezyY+iSnBY="

  setup_all do
    previous_public_key =
      Application.fetch_env(:serviceradar_core, :agent_release_public_key)

    ServiceRadar.TestSupport.start_core!()
    Application.put_env(:serviceradar_core, :agent_release_public_key, @release_public_key)

    on_exit(fn ->
      restore_env_snapshot(:agent_release_public_key, previous_public_key)
    end)

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

    test "registers host interface MACs as identifiers at enrollment", %{
      agent_id: agent_id,
      actor: actor,
      unique_id: unique_id
    } do
      mac_suffix =
        unique_id
        |> rem(0x1000000)
        |> Integer.to_string(16)
        |> String.pad_leading(6, "0")
        |> String.upcase()

      mac = "001A2B" <> mac_suffix

      attrs = %{
        hostname: "host-evidence-#{agent_id}",
        os: "linux",
        arch: "amd64",
        partition: "default",
        source_ip: "10.91.#{rem(unique_id, 200)}.#{rem(unique_id, 250) + 1}",
        capabilities: ["sysmon"],
        host_macs: [
          mac
          |> String.codepoints()
          |> Enum.chunk_every(2)
          |> Enum.map_join(":", &Enum.join/1)
        ]
      }

      assert {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

      {:ok, identifiers} =
        DeviceIdentifier
        |> Ash.Query.filter(device_id == ^device_uid)
        |> Ash.read(actor: actor)

      by_type = Enum.group_by(identifiers, & &1.identifier_type, & &1.identifier_value)

      assert by_type[:agent_id] == [agent_id]
      assert by_type[:mac] == [mac]
      refute Enum.any?(identifiers, &String.contains?(&1.identifier_value, ","))
    end

    test "enrollment without MACs registers only the agent_id identifier", %{
      agent_id: agent_id,
      actor: actor,
      unique_id: unique_id
    } do
      attrs = %{
        hostname: "no-mac-host-#{agent_id}",
        os: "linux",
        arch: "amd64",
        partition: "default",
        source_ip: "10.92.#{rem(unique_id, 200)}.#{rem(unique_id, 250) + 1}",
        capabilities: ["sysmon"]
      }

      assert {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

      {:ok, identifiers} =
        DeviceIdentifier
        |> Ash.Query.filter(device_id == ^device_uid)
        |> Ash.read(actor: actor)

      assert Enum.map(identifiers, &{&1.identifier_type, &1.identifier_value}) ==
               [{:agent_id, agent_id}]
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

    test "does not downgrade a discovered hypervisor host to server during agent sync", %{
      agent_id: agent_id,
      actor: actor,
      unique_id: unique_id
    } do
      ip = "10.77.#{rem(unique_id, 200)}.10"

      create_attrs = %{
        uid: "pve-agent-sync-#{unique_id}",
        hostname: "pve-agent-sync-#{unique_id}",
        name: "pve-agent-sync-#{unique_id}",
        ip: ip,
        type: "Hypervisor",
        type_id: 99,
        metadata: %{"device_role" => "hypervisor"},
        discovery_sources: ["proxmox-api"],
        is_available: true
      }

      assert {:ok, _device} =
               Device
               |> Ash.Changeset.for_create(:create, create_attrs)
               |> Ash.create(actor: actor)

      assert {:ok, device_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "pve-agent-sync-#{unique_id}",
                 source_ip: ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)
      assert device.type == "Hypervisor"
      assert device.type_id == 99
      assert "agent" in device.discovery_sources
      assert "proxmox-api" in device.discovery_sources
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

    test "adds passive-netprobe source for host network visibility capability", %{
      unique_id: unique_id,
      actor: actor
    } do
      agent_id = "agent-host-visibility-#{unique_id}"

      attrs = %{
        hostname: "host-visibility",
        source_ip: "10.0.0.3",
        capabilities: [
          "host-network-visibility",
          "host-network-visibility.fingerprint.enabled",
          "host-network-visibility.dpi.unavailable"
        ]
      }

      {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

      {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)
      assert "agent" in device.discovery_sources
      assert "passive-netprobe" in device.discovery_sources
    end

    test "does not add passive-netprobe source when fingerprinting is unavailable", %{
      unique_id: unique_id,
      actor: actor
    } do
      agent_id = "agent-host-visibility-unavailable-#{unique_id}"

      attrs = %{
        hostname: "host-visibility-unavailable",
        source_ip: "10.0.0.4",
        capabilities: [
          "host-network-visibility",
          "host-network-visibility.fingerprint.unavailable",
          "host-network-visibility.dpi.unavailable"
        ]
      }

      {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

      {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)
      assert "agent" in device.discovery_sources
      refute "passive-netprobe" in device.discovery_sources
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

    test "adopts existing active-IP device when it has no agent owner", %{
      unique_id: unique_id,
      actor: actor
    } do
      agent_id = "agent-active-ip-discovered-#{unique_id}"
      conflict_ip = "10.88.#{rem(unique_id, 200)}.20"
      discovered_uid = "sr:" <> Ecto.UUID.generate()

      assert {:ok, _device} =
               Device
               |> Ash.Changeset.for_create(:create, %{
                 uid: discovered_uid,
                 hostname: "discovered-active-ip-#{unique_id}",
                 ip: conflict_ip,
                 discovery_sources: ["mapper"],
                 is_available: true
               })
               |> Ash.create(actor: actor)

      assert {:ok, adopted_device_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "agent-active-ip-adopted-#{unique_id}",
                 source_ip: conflict_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      assert adopted_device_uid == discovered_uid

      {:ok, device} = Device.get_by_uid(discovered_uid, false, actor: actor)
      assert device.agent_id == agent_id
      assert "mapper" in device.discovery_sources
      assert "agent" in device.discovery_sources
    end

    test "does not merge a current agent device into a stale agent_id identifier owner",
         %{
           unique_id: unique_id,
           actor: actor
         } do
      stale_owner_agent_id = "agent-stale-owner-#{unique_id}"
      current_agent_id = "agent-current-owner-#{unique_id}"
      stale_ip = "10.89.#{rem(unique_id, 200)}.10"
      current_ip = "10.89.#{rem(unique_id, 200)}.20"

      :ok =
        AgentGatewaySync.upsert_agent(current_agent_id, %{
          host: current_ip,
          capabilities: ["sysmon"]
        })

      {:ok, stale_owner_uid} =
        AgentGatewaySync.ensure_device_for_agent(stale_owner_agent_id, %{
          hostname: "stale-owner-#{unique_id}",
          source_ip: stale_ip,
          partition: "default",
          capabilities: ["sysmon"]
        })

      assert :ok =
               DeviceIdentifier
               |> Ash.Changeset.for_create(:upsert, %{
                 device_id: stale_owner_uid,
                 identifier_type: :agent_id,
                 identifier_value: current_agent_id,
                 partition: "default",
                 confidence: :strong,
                 source: "test-stale-identifier"
               })
               |> Ash.create(actor: actor)
               |> then(fn {:ok, _identifier} -> :ok end)

      assert {:ok, current_uid} =
               AgentGatewaySync.ensure_device_for_agent(current_agent_id, %{
                 hostname: "current-owner-#{unique_id}",
                 source_ip: current_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      refute current_uid == stale_owner_uid

      {:ok, current_device} = Device.get_by_uid(current_uid, false, actor: actor)
      {:ok, stale_owner_device} = Device.get_by_uid(stale_owner_uid, false, actor: actor)
      {:ok, current_agent} = Agent.get_by_uid(current_agent_id, actor: actor)

      assert current_device.agent_id == current_agent_id
      assert current_device.ip == current_ip
      assert current_agent.device_uid == current_uid
      refute stale_owner_device.deleted_at

      query =
        Ash.Query.for_read(DeviceIdentifier, :lookup, %{
          identifier_type: :agent_id,
          identifier_value: current_agent_id,
          partition: "default"
        })

      assert {:ok, [identifier]} = Ash.read(query, actor: actor)
      assert identifier.device_id == current_uid
    end

    test "releases conflicting active IP from a different agent-owned device instead of adopting it",
         %{
           unique_id: unique_id,
           actor: actor
         } do
      stale_owner_agent_id = "agent-ip-owner-#{unique_id}"
      current_agent_id = "agent-ip-claimant-#{unique_id}"
      conflict_ip = "10.90.#{rem(unique_id, 200)}.30"

      :ok =
        AgentGatewaySync.upsert_agent(current_agent_id, %{
          host: conflict_ip,
          capabilities: ["sysmon"]
        })

      {:ok, stale_owner_uid} =
        AgentGatewaySync.ensure_device_for_agent(stale_owner_agent_id, %{
          hostname: "ip-owner-#{unique_id}",
          source_ip: conflict_ip,
          partition: "default",
          capabilities: ["sysmon"]
        })

      assert {:ok, current_uid} =
               AgentGatewaySync.ensure_device_for_agent(current_agent_id, %{
                 hostname: "ip-claimant-#{unique_id}",
                 source_ip: conflict_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      refute current_uid == stale_owner_uid

      {:ok, stale_owner_device} = Device.get_by_uid(stale_owner_uid, false, actor: actor)
      {:ok, current_device} = Device.get_by_uid(current_uid, false, actor: actor)
      {:ok, current_agent} = Agent.get_by_uid(current_agent_id, actor: actor)

      assert is_nil(stale_owner_device.ip)
      assert stale_owner_device.agent_id == stale_owner_agent_id
      assert stale_owner_device.metadata["released_conflicting_active_ip"] == conflict_ip
      assert current_device.ip == conflict_ip
      assert current_device.agent_id == current_agent_id
      assert current_agent.device_uid == current_uid
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

    test "retires unlinked same-host stale agent and transfers active assignments",
         %{
           unique_id: unique_id,
           actor: actor
         } do
      old_agent_id = "agent-stale-#{unique_id}"
      replacement_agent_id = "agent-current-#{unique_id}"
      source_ip = "192.168.70.#{rem(unique_id, 200) + 10}"
      partition = "default"

      assignment_actor = %{
        id: Ash.UUID.generate(),
        email: "assignment-#{unique_id}@example.test",
        role: :operator
      }

      assert {:ok, _old_agent} =
               Agent
               |> Ash.Changeset.for_create(:register, %{uid: old_agent_id},
                 actor: assignment_actor
               )
               |> Ash.create()

      :ok =
        AgentGatewaySync.upsert_agent(old_agent_id, %{
          host: source_ip,
          capabilities: ["mapper", "sweep"],
          metadata: %{"partition_id" => partition}
        })

      assert {:ok, %Agent{uid: ^old_agent_id}} =
               Agent
               |> Ash.Query.for_read(:by_uid, %{uid: old_agent_id})
               |> Ash.read_one(actor: assignment_actor)

      {:ok, mapper_job} =
        MapperJob
        |> Ash.Changeset.for_create(:create, %{
          name: "stale-agent-mapper-#{unique_id}",
          partition: partition,
          agent_id: old_agent_id,
          discovery_mode: :snmp_api,
          discovery_type: :full,
          options: %{}
        })
        |> Ash.create(actor: assignment_actor)

      early_other_agent_id = "agent-a-other-#{unique_id}"
      late_other_agent_id = "agent-z-other-#{unique_id}"

      :ok =
        AgentGatewaySync.upsert_agent(early_other_agent_id, %{
          host: "192.168.71.#{rem(unique_id, 200) + 10}",
          capabilities: ["sweep"],
          metadata: %{"partition_id" => partition}
        })

      :ok =
        AgentGatewaySync.upsert_agent(late_other_agent_id, %{
          host: "192.168.72.#{rem(unique_id, 200) + 10}",
          capabilities: ["sweep"],
          metadata: %{"partition_id" => partition}
        })

      {:ok, first_member_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "stale-agent-first-#{unique_id}",
            partition: partition,
            agent_ids: [old_agent_id, late_other_agent_id],
            target_query: "in:devices",
            static_targets: [source_ip],
            ports: [],
            sweep_modes: ["icmp"]
          },
          actor: assignment_actor
        )
        |> Ash.create(actor: assignment_actor)

      {:ok, non_first_member_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "stale-agent-non-first-#{unique_id}",
            partition: partition,
            agent_ids: [early_other_agent_id, old_agent_id],
            target_query: "in:devices",
            static_targets: [source_ip],
            ports: [],
            sweep_modes: ["icmp"]
          },
          actor: assignment_actor
        )
        |> Ash.create(actor: assignment_actor)

      :ok =
        AgentGatewaySync.upsert_agent(replacement_agent_id, %{
          host: source_ip,
          capabilities: ["mapper", "sweep"],
          metadata: %{"partition_id" => partition}
        })

      {:ok, replacement_present_group} =
        SweepGroup
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "stale-agent-replacement-present-#{unique_id}",
            partition: partition,
            agent_ids: [old_agent_id, replacement_agent_id, late_other_agent_id],
            target_query: "in:devices",
            static_targets: [source_ip],
            ports: [],
            sweep_modes: ["icmp"]
          },
          actor: assignment_actor
        )
        |> Ash.create(actor: assignment_actor)

      assert {:ok, _device_uid} =
               AgentGatewaySync.ensure_device_for_agent(replacement_agent_id, %{
                 hostname: "current-#{unique_id}",
                 source_ip: source_ip,
                 partition: partition,
                 capabilities: ["mapper", "sweep"]
               })

      {:ok, old_agent} = Agent.get_by_uid(old_agent_id, actor: actor)
      {:ok, updated_mapper_job} = Ash.get(MapperJob, mapper_job.id, actor: actor)
      {:ok, updated_first_member_group} = Ash.get(SweepGroup, first_member_group.id, actor: actor)

      {:ok, updated_non_first_member_group} =
        Ash.get(SweepGroup, non_first_member_group.id, actor: actor)

      {:ok, updated_replacement_present_group} =
        Ash.get(SweepGroup, replacement_present_group.id, actor: actor)

      assert old_agent.status == :unavailable
      assert updated_mapper_job.agent_id == replacement_agent_id
      assert updated_first_member_group.agent_ids == [replacement_agent_id, late_other_agent_id]

      assert updated_non_first_member_group.agent_ids == [
               early_other_agent_id,
               replacement_agent_id
             ]

      assert updated_replacement_present_group.agent_ids == [
               replacement_agent_id,
               late_other_agent_id
             ]

      assert updated_first_member_group.agent_id == replacement_agent_id
      assert updated_non_first_member_group.agent_id == early_other_agent_id
      assert updated_replacement_present_group.agent_id == replacement_agent_id
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

    test "creates missing gateway before linking agent", %{
      agent_id: agent_id,
      unique_id: unique_id,
      actor: actor
    } do
      gateway_id = "gateway-sync-test-#{unique_id}"

      assert {:error, _} = Gateway.get_by_id(gateway_id, actor: actor)

      assert :ok =
               AgentGatewaySync.upsert_agent(agent_id, %{
                 name: "Gateway Linked Agent",
                 gateway_id: gateway_id,
                 metadata: %{domain: "test", partition_id: "test-partition"}
               })

      assert {:ok, gateway} = Gateway.get_by_id(gateway_id, actor: actor)
      assert gateway.status == :healthy
      assert gateway.registration_source == "agent-gateway-auto"

      assert {:ok, agent} = Agent.get_by_uid(agent_id, actor: actor)
      assert agent.gateway_id == gateway_id
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

    test "version-bearing upsert reconciles active release target", %{
      agent_id: agent_id,
      actor: actor,
      unique_id: unique_id
    } do
      version = "9.#{unique_id}.0"

      :ok =
        AgentGatewaySync.upsert_agent(agent_id, %{
          name: "Release Reconcile Agent",
          version: "1.0.0",
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "amd64"}
        })

      {:ok, release} = publish_test_release(version, actor)

      {:ok, rollout} =
        AgentReleaseRollout.create_rollout(
          %{
            release_id: release.id,
            desired_version: version,
            cohort_agent_ids: [agent_id],
            batch_size: 1,
            status: :active,
            created_by: "gateway-sync-test"
          },
          actor: actor
        )

      {:ok, target} =
        AgentReleaseTarget.create_target(
          %{
            rollout_id: rollout.id,
            release_id: release.id,
            agent_id: agent_id,
            cohort_index: 0,
            desired_version: version,
            current_version: "1.0.0",
            status: :restarting,
            progress_percent: 95
          },
          actor: actor
        )

      :ok =
        AgentGatewaySync.upsert_agent(agent_id, %{
          name: "Release Reconcile Agent",
          version: version,
          capabilities: ["agent"],
          metadata: %{"os" => "linux", "arch" => "amd64"}
        })

      target = AgentReleaseTarget.get_by_id!(target.id, actor: actor)
      assert target.status == :healthy
      assert target.progress_percent == 100
      assert target.current_version == version

      rollout = AgentReleaseRollout.get_by_id!(rollout.id, actor: actor)
      assert rollout.status == :completed

      agent = Agent.get_by_uid!(agent_id, actor: actor)
      assert agent.release_rollout_state == :healthy
      assert agent.last_update_error == nil
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

  defp publish_test_release(version, actor) do
    manifest = %{
      "version" => version,
      "artifacts" => [
        %{
          "os" => "linux",
          "arch" => "amd64",
          "url" => "https://example.com/releases/agent-#{version}-linux-amd64.tar.gz",
          "sha256" => String.duplicate("a", 64)
        }
      ]
    }

    AgentRelease.publish(
      %{
        version: version,
        manifest: manifest,
        signature: sign_manifest(manifest)
      },
      actor: actor
    )
  end

  defp sign_manifest(manifest) do
    {:ok, payload} = ServiceRadar.Edge.ReleaseManifestValidator.canonical_json(manifest)
    private_key = Base.decode64!(@release_private_key)

    :eddsa
    |> :crypto.sign(:none, payload, [private_key, :ed25519])
    |> Base.encode64()
  end

  defp restore_env_snapshot(key, {:ok, value}),
    do: Application.put_env(:serviceradar_core, key, value)

  defp restore_env_snapshot(key, :error), do: Application.delete_env(:serviceradar_core, key)
end
