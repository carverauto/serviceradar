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
  alias ServiceRadar.Integrations.ArmisNorthboundPopulation
  alias ServiceRadar.Inventory.Availability
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DistinctDeviceAssertion
  alias ServiceRadar.Inventory.IdentityDecision
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.TestSupport.AvailabilityFixtures

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

    # Two live agents behind one NAT address: the newer check-in does not move the address.
    test "a new agent does not take an address held by a different live agent",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      stale_owner_agent_id = "agent-ip-owner-#{uniq}"
      current_agent_id = "agent-ip-claimant-#{uniq}"
      conflict_ip = unique_test_ip(uniq, 0)

      :ok =
        AgentGatewaySync.upsert_agent(current_agent_id, %{
          host: conflict_ip,
          capabilities: ["sysmon"]
        })

      :ok =
        AgentGatewaySync.upsert_agent(stale_owner_agent_id, %{
          host: conflict_ip,
          capabilities: ["sysmon"]
        })

      {:ok, stale_owner_uid} =
        AgentGatewaySync.ensure_device_for_agent(stale_owner_agent_id, %{
          hostname: "ip-owner-#{uniq}",
          source_ip: conflict_ip,
          partition: "default",
          capabilities: ["sysmon"]
        })

      set_observed!(stale_owner_uid, DateTime.shift(DateTime.utc_now(), hour: -1), actor)

      assert {:ok, current_uid} =
               AgentGatewaySync.ensure_device_for_agent(current_agent_id, %{
                 hostname: "ip-claimant-#{uniq}",
                 source_ip: conflict_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      refute current_uid == stale_owner_uid

      {:ok, stale_owner_device} = Device.get_by_uid(stale_owner_uid, false, actor: actor)
      {:ok, current_device} = Device.get_by_uid(current_uid, false, actor: actor)
      {:ok, current_agent} = Agent.get_by_uid(current_agent_id, actor: actor)

      assert stale_owner_device.ip == conflict_ip
      assert stale_owner_device.agent_id == stale_owner_agent_id
      refute get_in(stale_owner_device.metadata || %{}, ["released_conflicting_active_ip"])
      assert is_nil(current_device.ip)
      assert current_device.agent_id == current_agent_id
      assert current_agent.device_uid == current_uid

      assert_ip_conflict_recorded(
        current_uid,
        stale_owner_uid,
        conflict_ip,
        "preserve_source_identity_drop_conflicting_ip",
        actor,
        "held_by_live_agent"
      )
    end

    # A different agent that is gone is no evidence the address is still its host's.
    test "a new agent takes a stale address from a retired agent's device", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      gone_agent_id = "agent-gone-#{uniq}"
      agent_id = "agent-new-host-#{uniq}"
      reused_ip = unique_test_ip(uniq, 0)

      :ok =
        AgentGatewaySync.upsert_agent(gone_agent_id, %{host: reused_ip, capabilities: ["sysmon"]})

      {:ok, gone_uid} =
        AgentGatewaySync.ensure_device_for_agent(gone_agent_id, %{
          hostname: "gone-host-#{uniq}",
          source_ip: reused_ip,
          partition: "default",
          capabilities: ["sysmon"]
        })

      {:ok, gone_agent} = Agent.get_by_uid(gone_agent_id, actor: actor)

      {:ok, _retired} =
        gone_agent
        |> Ash.Changeset.for_update(:mark_unavailable, %{})
        |> Ash.update(actor: actor)

      set_observed!(gone_uid, DateTime.shift(DateTime.utc_now(), hour: -1), actor)

      :ok = AgentGatewaySync.upsert_agent(agent_id, %{host: reused_ip, capabilities: ["sysmon"]})

      assert {:ok, agent_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "new-host-#{uniq}",
                 source_ip: reused_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      refute agent_uid == gone_uid

      {:ok, gone_device} = Device.get_by_uid(gone_uid, false, actor: actor)
      {:ok, agent_device} = Device.get_by_uid(agent_uid, false, actor: actor)

      assert agent_device.ip == reused_ip
      assert is_nil(gone_device.ip)
      assert gone_device.agent_id == gone_agent_id
      assert is_nil(gone_device.deleted_at)

      assert_ip_conflict_recorded(
        agent_uid,
        gone_uid,
        reused_ip,
        "preserve_source_identity_release_stale_ip",
        actor,
        "holder_stale"
      )
    end

    test "a new agent without a partition looks up the holder in the default partition only",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      agent_id = "agent-no-partition-#{uniq}"
      shared_ip = unique_test_ip(uniq, 0)
      earlier = DateTime.shift(DateTime.utc_now(), hour: -1)

      # Created first, so an unscoped lookup finds it first.
      other_uid = create_seen_device!("site-b", shared_ip, earlier, actor)
      holder_uid = create_seen_device!("default", shared_ip, earlier, actor)

      assert {:ok, agent_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "no-partition-#{uniq}",
                 source_ip: shared_ip,
                 partition: nil,
                 capabilities: ["sysmon"]
               })

      {:ok, other_device} = Device.get_by_uid(other_uid, false, actor: actor)
      {:ok, holder_device} = Device.get_by_uid(holder_uid, false, actor: actor)
      {:ok, agent_device} = Device.get_by_uid(agent_uid, false, actor: actor)

      refute agent_uid in [holder_uid, other_uid]
      assert agent_device.partition == "default"
      assert agent_device.ip == shared_ip
      assert is_nil(holder_device.ip)
      assert other_device.ip == shared_ip
      refute get_in(other_device.metadata || %{}, ["released_conflicting_active_ip"])
    end

    # Another agent's device keeps its address even when this check-in is newer.
    # Otherwise two agents behind one NAT address swap it on every reconnect.
    test "an existing agent check-in does not take an address held by another agent",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      moving_agent_id = "agent-moving-#{uniq}"
      holder_agent_id = "agent-holder-#{uniq}"
      original_ip = unique_test_ip(uniq, 0)
      held_ip = unique_test_ip(uniq, 1)

      {moving_uid, holder_uid} =
        enroll_moving_and_holder(moving_agent_id, original_ip, holder_agent_id, held_ip)

      set_observed!(holder_uid, DateTime.shift(DateTime.utc_now(), hour: -1), actor)

      assert {:ok, ^moving_uid} =
               AgentGatewaySync.ensure_device_for_agent(moving_agent_id, %{
                 hostname: "moving-host-#{uniq}",
                 source_ip: held_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      {:ok, moving_device} = Device.get_by_uid(moving_uid, false, actor: actor)
      {:ok, holder_device} = Device.get_by_uid(holder_uid, false, actor: actor)

      assert moving_device.ip == original_ip
      assert moving_device.agent_id == moving_agent_id
      assert holder_device.ip == held_ip
      assert is_nil(holder_device.deleted_at)
      assert holder_device.agent_id == holder_agent_id

      assert_ip_conflict_recorded(
        moving_uid,
        holder_uid,
        held_ip,
        "preserve_source_identity_drop_conflicting_ip",
        actor,
        "held_by_live_agent"
      )
    end

    test "an existing agent check-in takes an address from an agent not seen within the live window",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      moving_agent_id = "agent-moving-#{uniq}"
      holder_agent_id = "agent-holder-#{uniq}"
      original_ip = unique_test_ip(uniq, 0)
      held_ip = unique_test_ip(uniq, 1)

      {moving_uid, holder_uid} =
        enroll_moving_and_holder(moving_agent_id, original_ip, holder_agent_id, held_ip)

      set_observed!(holder_uid, DateTime.shift(DateTime.utc_now(), hour: -2), actor)

      set_agent_last_seen!(
        holder_agent_id,
        DateTime.shift(DateTime.utc_now(), hour: -2),
        actor
      )

      assert {:ok, ^moving_uid} =
               AgentGatewaySync.ensure_device_for_agent(moving_agent_id, %{
                 hostname: "moving-host-#{uniq}",
                 source_ip: held_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      {:ok, moving_device} = Device.get_by_uid(moving_uid, false, actor: actor)
      {:ok, holder_device} = Device.get_by_uid(holder_uid, false, actor: actor)

      assert moving_device.ip == held_ip
      assert is_nil(holder_device.ip)
      assert holder_device.agent_id == holder_agent_id
      assert is_nil(holder_device.deleted_at)

      assert_ip_conflict_recorded(
        moving_uid,
        holder_uid,
        held_ip,
        "preserve_source_identity_release_stale_ip",
        actor,
        "holder_stale"
      )
    end

    test "an existing agent check-in keeps its own address when the holder was seen no earlier",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      moving_agent_id = "agent-moving-#{uniq}"
      holder_agent_id = "agent-holder-#{uniq}"
      original_ip = unique_test_ip(uniq, 0)
      held_ip = unique_test_ip(uniq, 1)

      {moving_uid, holder_uid} =
        enroll_moving_and_holder(moving_agent_id, original_ip, holder_agent_id, held_ip)

      set_observed!(holder_uid, DateTime.shift(DateTime.utc_now(), hour: 1), actor)

      assert {:ok, ^moving_uid} =
               AgentGatewaySync.ensure_device_for_agent(moving_agent_id, %{
                 hostname: "moving-host-renamed-#{uniq}",
                 source_ip: held_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      {:ok, moving_device} = Device.get_by_uid(moving_uid, false, actor: actor)
      {:ok, holder_device} = Device.get_by_uid(holder_uid, false, actor: actor)

      assert moving_device.ip == original_ip
      assert moving_device.hostname == "moving-host-renamed-#{uniq}"
      assert holder_device.ip == held_ip
      assert holder_device.agent_id == holder_agent_id
      refute get_in(holder_device.metadata || %{}, ["released_conflicting_active_ip"])

      assert_ip_conflict_recorded(
        moving_uid,
        holder_uid,
        held_ip,
        "preserve_source_identity_drop_conflicting_ip",
        actor
      )
    end

    # A sweep answering at the holder's address keeps refreshing its last_seen_time, here to
    # after this check-in. Its last identity-bearing observation, its agent's last check-in, is
    # two hours old, and that is what the check-in is compared with.
    test "an existing agent check-in takes an address whose holder only a sweep has seen since",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      moving_agent_id = "agent-moving-#{uniq}"
      holder_agent_id = "agent-holder-#{uniq}"
      original_ip = unique_test_ip(uniq, 0)
      held_ip = unique_test_ip(uniq, 1)
      two_hours_ago = DateTime.shift(DateTime.utc_now(), hour: -2)

      {moving_uid, holder_uid} =
        enroll_moving_and_holder(moving_agent_id, original_ip, holder_agent_id, held_ip)

      set_observed!(holder_uid, two_hours_ago, actor)
      set_last_seen!(holder_uid, DateTime.shift(DateTime.utc_now(), hour: 1), actor)
      set_agent_last_seen!(holder_agent_id, two_hours_ago, actor)

      assert {:ok, ^moving_uid} =
               AgentGatewaySync.ensure_device_for_agent(moving_agent_id, %{
                 hostname: "moving-host-#{uniq}",
                 source_ip: held_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      {:ok, moving_device} = Device.get_by_uid(moving_uid, false, actor: actor)
      {:ok, holder_device} = Device.get_by_uid(holder_uid, false, actor: actor)

      assert moving_device.ip == held_ip
      assert is_nil(holder_device.ip)
      assert is_nil(holder_device.deleted_at)

      assert_ip_conflict_recorded(
        moving_uid,
        holder_uid,
        held_ip,
        "preserve_source_identity_release_stale_ip",
        actor,
        "holder_stale"
      )
    end

    # A sweep seed is nothing but its address, so the check-in that takes the address
    # soft-deletes it as seed_released (add-source-id-succession D8).
    test "an existing agent check-in takes a sweep seed's address and the seed is retired",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      agent_id = "agent-moving-#{uniq}"
      original_ip = unique_test_ip(uniq, 0)
      seeded_ip = unique_test_ip(uniq, 1)
      attrs = %{hostname: "moving-host-#{uniq}", partition: "default", capabilities: ["sysmon"]}

      :ok =
        AgentGatewaySync.upsert_agent(agent_id, %{host: original_ip, capabilities: ["sysmon"]})

      {:ok, device_uid} =
        AgentGatewaySync.ensure_device_for_agent(
          agent_id,
          Map.put(attrs, :source_ip, original_ip)
        )

      seed_uid = "sr:" <> Ecto.UUID.generate()

      {:ok, _seed} =
        Device
        |> Ash.Changeset.for_create(:create, %{
          uid: seed_uid,
          ip: seeded_ip,
          partition: "default",
          discovery_sources: ["sweep"],
          metadata: %{"identity_state" => "provisional", "identity_source" => "sweep_ip_seed"}
        })
        |> Ash.create(actor: actor)

      assert {:ok, ^device_uid} =
               AgentGatewaySync.ensure_device_for_agent(
                 agent_id,
                 Map.put(attrs, :source_ip, seeded_ip)
               )

      {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)
      assert device.ip == seeded_ip

      assert {:error, _} = Device.get_by_uid(seed_uid, false, actor: actor)
      {:ok, seed} = Device.get_by_uid(seed_uid, true, actor: actor)
      assert seed.deleted_reason == "seed_released"
      assert is_nil(seed.ip)

      assert_ip_conflict_recorded(
        device_uid,
        seed_uid,
        seeded_ip,
        "preserve_source_identity_release_stale_ip",
        actor,
        "holder_stale"
      )
    end

    # A check-in is an identity-bearing observation (DeviceWrites.observed_after?/2).
    test "a check-in records when the agent observed its device", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      agent_id = "agent-observed-#{uniq}"
      ip = unique_test_ip(uniq, 0)

      attrs = %{
        hostname: "observed-host-#{uniq}",
        source_ip: ip,
        partition: "default",
        capabilities: ["sysmon"]
      }

      before = DateTime.shift(DateTime.utc_now(), second: -1)
      :ok = AgentGatewaySync.upsert_agent(agent_id, %{host: ip, capabilities: ["sysmon"]})

      assert {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
      {:ok, created} = Device.get_by_uid(device_uid, false, actor: actor)
      assert %DateTime{} = created.identity_observed_at
      assert DateTime.after?(created.identity_observed_at, before)

      earlier = DateTime.shift(DateTime.utc_now(), hour: -1)
      set_observed!(device_uid, earlier, actor)

      assert {:ok, ^device_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
      {:ok, checked_in} = Device.get_by_uid(device_uid, false, actor: actor)
      assert DateTime.after?(checked_in.identity_observed_at, earlier)
    end

    test "a new agent does not release an address held in another partition", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      holder_agent_id = "agent-other-partition-#{uniq}"
      agent_id = "agent-this-partition-#{uniq}"
      shared_ip = unique_test_ip(uniq, 0)

      assert {:ok, holder_uid} =
               AgentGatewaySync.ensure_device_for_agent(holder_agent_id, %{
                 hostname: "other-partition-#{uniq}",
                 source_ip: shared_ip,
                 partition: "site-b",
                 capabilities: ["sysmon"]
               })

      assert {:ok, agent_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "this-partition-#{uniq}",
                 source_ip: shared_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      refute agent_uid == holder_uid

      {:ok, holder_device} = Device.get_by_uid(holder_uid, false, actor: actor)
      {:ok, agent_device} = Device.get_by_uid(agent_uid, false, actor: actor)

      assert holder_device.partition == "site-b"
      assert holder_device.ip == shared_ip
      assert agent_device.partition == "default"
      assert agent_device.ip == shared_ip
      refute get_in(holder_device.metadata || %{}, ["released_conflicting_active_ip"])
    end

    # #4664: address evidence never decides identity. A new agent enrolling at an address an
    # Armis-identified device holds used to adopt that record, because it had no agent_id.
    test "a new agent at an address held by an Armis-identified device does not adopt it",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      agent_id = "agent-armis-addr-#{uniq}"
      held_ip = unique_test_ip(uniq, 0)
      armis_uid = "sr:" <> Ecto.UUID.generate()
      armis_id = "armis-synthetic-#{uniq}"

      assert {:ok, _device} =
               Device
               |> Ash.Changeset.for_create(:create, %{
                 uid: armis_uid,
                 hostname: "armis-host-#{uniq}",
                 ip: held_ip,
                 discovery_sources: ["armis"],
                 metadata: %{"armis_device_id" => armis_id, "integration_type" => "armis"},
                 last_seen_time: DateTime.shift(DateTime.utc_now(), hour: -1),
                 is_available: true
               })
               |> Ash.create(actor: actor)

      assert {:ok, _identifier} =
               DeviceIdentifier
               |> Ash.Changeset.for_create(:upsert, %{
                 device_id: armis_uid,
                 identifier_type: :armis_device_id,
                 identifier_value: armis_id,
                 partition: "default",
                 confidence: :strong,
                 source: "test-armis"
               })
               |> Ash.create(actor: actor)

      assert {:ok, agent_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "armis-host-#{uniq}",
                 source_ip: held_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      refute agent_uid == armis_uid

      {:ok, armis_device} = Device.get_by_uid(armis_uid, false, actor: actor)
      {:ok, agent_device} = Device.get_by_uid(agent_uid, false, actor: actor)

      assert is_nil(armis_device.agent_id)
      refute "agent" in (armis_device.discovery_sources || [])
      assert agent_device.agent_id == agent_id

      assert_ip_conflict_recorded(
        agent_uid,
        armis_uid,
        held_ip,
        "preserve_source_identity_release_stale_ip",
        actor
      )
    end

    test "a new agent sharing a hostname with a different agent's device does not adopt it",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      holder_agent_id = "agent-name-holder-#{uniq}"
      agent_id = "agent-name-twin-#{uniq}"
      held_ip = unique_test_ip(uniq, 0)

      :ok = AgentGatewaySync.upsert_agent(agent_id, %{host: held_ip, capabilities: ["sysmon"]})

      :ok =
        AgentGatewaySync.upsert_agent(holder_agent_id, %{host: held_ip, capabilities: ["sysmon"]})

      {:ok, holder_uid} =
        AgentGatewaySync.ensure_device_for_agent(holder_agent_id, %{
          hostname: "shared-name-#{uniq}",
          source_ip: held_ip,
          partition: "default",
          capabilities: ["sysmon"]
        })

      assert {:ok, agent_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "SHARED-NAME-#{uniq}",
                 source_ip: held_ip,
                 partition: "default",
                 capabilities: ["sysmon"]
               })

      refute agent_uid == holder_uid

      {:ok, holder_device} = Device.get_by_uid(holder_uid, false, actor: actor)
      {:ok, agent_device} = Device.get_by_uid(agent_uid, false, actor: actor)

      assert holder_device.agent_id == holder_agent_id
      assert holder_device.ip == held_ip
      assert agent_device.agent_id == agent_id

      assert_ip_conflict_recorded(
        agent_uid,
        holder_uid,
        held_ip,
        "preserve_source_identity_drop_conflicting_ip",
        actor
      )
    end

    test "supersedes an older duplicate-prefix agent when reenrollment resolves to the same device",
         %{
           unique_id: unique_id,
           actor: actor
         } do
      old_agent_id = "agent-dusk-#{unique_id}"
      replacement_agent_id = "agent-agent-dusk-#{unique_id}"
      source_ip = "192.168.50.#{rem(unique_id, 200) + 10}"

      # The host's MAC makes the re-enrolled agent the same device; a shared hostname and
      # address alone would not (#4664).
      attrs = %{
        hostname: "dusk-#{unique_id}",
        source_ip: source_ip,
        partition: "default",
        capabilities: ["sysmon"],
        host_macs: ["00:00:5e:00:53:4a"]
      }

      :ok =
        AgentGatewaySync.upsert_agent(old_agent_id, %{host: source_ip, capabilities: ["sysmon"]})

      {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(old_agent_id, attrs)

      set_agent_last_seen!(
        old_agent_id,
        DateTime.shift(DateTime.utc_now(), day: -1),
        actor
      )

      :ok =
        AgentGatewaySync.upsert_agent(replacement_agent_id, %{
          host: source_ip,
          capabilities: ["sysmon"]
        })

      assert {:ok, ^device_uid} =
               AgentGatewaySync.ensure_device_for_agent(replacement_agent_id, attrs)

      {:ok, old_agent} = Agent.get_by_uid(old_agent_id, actor: actor)
      {:ok, replacement_agent} = Agent.get_by_uid(replacement_agent_id, actor: actor)

      assert old_agent.status == :superseded
      assert old_agent.superseded_by == replacement_agent_id
      assert replacement_agent.status == :connected
      assert replacement_agent.device_uid == device_uid
    end

    test "supersedes an older renamed agent when reenrollment resolves to the same device",
         %{
           unique_id: unique_id,
           actor: actor
         } do
      old_agent_id = "agent-dusk-#{unique_id}"
      replacement_agent_id = "agent-dusk01-#{unique_id}"
      source_ip = "192.168.60.#{rem(unique_id, 200) + 10}"

      # The host's MAC makes the re-enrolled agent the same device; a shared hostname and
      # address alone would not (#4664).
      attrs = %{
        hostname: "dusk-#{unique_id}",
        source_ip: source_ip,
        partition: "default",
        capabilities: ["sysmon"],
        host_macs: ["00:00:5e:00:53:4b"]
      }

      :ok =
        AgentGatewaySync.upsert_agent(old_agent_id, %{host: source_ip, capabilities: ["sysmon"]})

      {:ok, device_uid} = AgentGatewaySync.ensure_device_for_agent(old_agent_id, attrs)

      set_agent_last_seen!(
        old_agent_id,
        DateTime.shift(DateTime.utc_now(), day: -1),
        actor
      )

      :ok =
        AgentGatewaySync.upsert_agent(replacement_agent_id, %{
          host: source_ip,
          capabilities: ["sysmon"]
        })

      assert {:ok, ^device_uid} =
               AgentGatewaySync.ensure_device_for_agent(replacement_agent_id, attrs)

      {:ok, old_agent} = Agent.get_by_uid(old_agent_id, actor: actor)
      {:ok, replacement_agent} = Agent.get_by_uid(replacement_agent_id, actor: actor)

      assert old_agent.status == :superseded
      assert old_agent.superseded_by == replacement_agent_id
      assert replacement_agent.status == :connected
      assert replacement_agent.device_uid == device_uid
    end

    test "supersedes a quiet same-device agent and transfers active assignments",
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

      # The host MAC is what makes the replacement the same device. A shared
      # address alone must not retire the previous identity.
      host_mac = "00:00:5e:00:53:4c"

      {:ok, device_uid} =
        AgentGatewaySync.ensure_device_for_agent(old_agent_id, %{
          hostname: "current-#{unique_id}",
          source_ip: source_ip,
          partition: partition,
          capabilities: ["mapper", "sweep"],
          host_macs: [host_mac]
        })

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

      set_agent_last_seen!(
        old_agent_id,
        DateTime.shift(DateTime.utc_now(), day: -1),
        actor
      )

      assert {:ok, ^device_uid} =
               AgentGatewaySync.ensure_device_for_agent(replacement_agent_id, %{
                 hostname: "current-#{unique_id}",
                 source_ip: source_ip,
                 partition: partition,
                 capabilities: ["mapper", "sweep"],
                 host_macs: [host_mac]
               })

      {:ok, old_agent} = Agent.get_by_uid(old_agent_id, actor: actor)
      {:ok, updated_mapper_job} = Ash.get(MapperJob, mapper_job.id, actor: actor)
      {:ok, updated_first_member_group} = Ash.get(SweepGroup, first_member_group.id, actor: actor)

      {:ok, updated_non_first_member_group} =
        Ash.get(SweepGroup, non_first_member_group.id, actor: actor)

      {:ok, updated_replacement_present_group} =
        Ash.get(SweepGroup, replacement_present_group.id, actor: actor)

      assert old_agent.status == :superseded
      assert old_agent.superseded_by == replacement_agent_id
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

  # link-agent-host-by-strong-identity. The agent reports its classified interface inventory,
  # and only a shared eligible MAC links it to a device another source knows. Its addresses and
  # hostname are corroboration: recorded for review, never a link. Every value is invented.
  describe "agent host identity" do
    test "an agent links by a NIC MAC on an interface it does not announce, whatever its hostname form",
         %{actor: actor} do
      for {form, offset} <- [{:short, 0}, {:fqdn, 4}] do
        uniq = System.unique_integer([:positive, :monotonic])
        name = "node#{uniq}"
        [announced_mac, known_mac] = host_macs(uniq, 2)
        known_ip = doc_ip(uniq, offset)
        announced_ip = doc_ip(uniq, offset + 1)
        known_uid = known_host!(name, known_ip, [known_mac], actor)
        agent_id = "agent-known-host-#{form}-#{uniq}"

        hostname = if form == :fqdn, do: "#{name}.site-a.example.com", else: name

        assert {:ok, ^known_uid} =
                 AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                   hostname: hostname,
                   source_ip: announced_ip,
                   partition: "default",
                   capabilities: ["sysmon"],
                   # An older agent's whole evidence: the announced interface's MAC alone.
                   host_macs: [announced_mac],
                   host_interfaces: [
                     host_nic("eno1", announced_mac, [announced_ip]),
                     host_nic("eno2", known_mac, [known_ip])
                   ]
                 })

        assert identifiers(known_uid, actor) ==
                 Enum.sort([
                   {:agent_id, agent_id},
                   {:mac, mac_value(announced_mac)},
                   {:mac, mac_value(known_mac)}
                 ])
      end
    end

    test "a veth-only container links by its globally administered announced MAC", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      [mac] = host_macs(uniq, 1)
      ip = doc_ip(uniq, 0)
      known_uid = known_host!("container#{uniq}", ip, [mac], actor)
      agent_id = "agent-container-#{uniq}"

      assert {:ok, ^known_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "container#{uniq}.example.com",
                 source_ip: ip,
                 host_macs: [mac],
                 host_interfaces: [
                   %{
                     name: "eth0",
                     kind: :HOST_INTERFACE_KIND_VIRTUAL,
                     mac: mac,
                     mac_provenance: :MAC_PROVENANCE_ASSIGNED,
                     ips: [ip]
                   }
                 ]
               })

      assert identifiers(known_uid, actor) ==
               Enum.sort([{:agent_id, agent_id}, {:mac, mac_value(mac)}])
    end

    test "physical MACs exclude announced veth and tap MACs", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      [physical_mac, veth_mac, tap_mac] = host_macs(uniq, 3)
      ip = doc_ip(uniq, 0)
      known_uid = known_host!("host#{uniq}", ip, [physical_mac], actor)
      agent_id = "agent-physical-#{uniq}"

      assert {:ok, ^known_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 source_ip: ip,
                 host_macs: [veth_mac],
                 host_interfaces: [
                   host_nic("eno1", physical_mac, [ip]),
                   %{name: "veth0", kind: :virtual, mac: veth_mac, permanent_mac: veth_mac},
                   %{name: "tap0", kind: :virtual, mac: tap_mac, permanent_mac: tap_mac}
                 ]
               })

      assert identifiers(known_uid, actor) ==
               Enum.sort([{:agent_id, agent_id}, {:mac, mac_value(physical_mac)}])
    end

    test "a veth-only agent rejects locally administered, multicast and reserved fallback MACs",
         %{actor: actor} do
      for mac <- ["02:1a:2c:00:00:01", "01:1a:2c:00:00:01", "00:00:00:00:00:00"] do
        uniq = System.unique_integer([:positive, :monotonic])
        agent_id = "agent-container-no-mac-#{uniq}"

        assert {:ok, uid} =
                 AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                   source_ip: doc_ip(uniq, 0),
                   host_macs: [mac],
                   host_interfaces: [%{name: "eth0", kind: :virtual, mac: mac}]
                 })

        assert identifiers(uid, actor) == [{:agent_id, agent_id}]
      end
    end

    test "same-named hosts at two sites with disjoint MACs never fuse, even at one address",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      name = "node#{uniq}"
      [site_a_mac, site_b_mac, site_b_second_mac] = host_macs(uniq, 3)
      shared_ip = doc_ip(uniq, 0)
      site_b_ip = doc_ip(uniq, 1)
      site_a_uid = known_host!(name, shared_ip, [site_a_mac], actor)
      agent_id = "agent-site-b-#{uniq}"

      # Site B uses site A's address plan on its second NIC.
      assert {:ok, site_b_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "#{name}.site-b.example.com",
                 source_ip: site_b_ip,
                 partition: "default",
                 capabilities: ["sysmon"],
                 host_macs: [site_b_mac],
                 host_interfaces: [
                   host_nic("eno1", site_b_mac, [site_b_ip]),
                   host_nic("eno2", site_b_second_mac, [shared_ip])
                 ]
               })

      refute site_b_uid == site_a_uid
      assert identifiers(site_a_uid, actor) == [{:mac, mac_value(site_a_mac)}]

      assert identifiers(site_b_uid, actor) ==
               Enum.sort([
                 {:agent_id, agent_id},
                 {:mac, mac_value(site_b_mac)},
                 {:mac, mac_value(site_b_second_mac)}
               ])

      assert corroboration_review(site_b_uid, site_a_uid, actor).subject == shared_ip
    end

    test "same-named integration arriving after an agent stays separate", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      name = "node#{uniq}"
      ip = doc_ip(uniq, 0)
      [mac] = host_macs(uniq, 1)
      agent_id = "agent-first-#{uniq}"

      integration_id =
        "proxmox:v3:#{Ecto.UUID.generate()}:#{Ecto.UUID.generate()}:cluster:node:#{name}"

      assert {:ok, agent_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: name,
                 source_ip: ip,
                 partition: "default",
                 host_interfaces: [host_nic("eno1", mac, [ip])]
               })

      assert :ok =
               ServiceRadar.Inventory.SyncIngestor.ingest_updates(
                 [
                   %{
                     "ip" => ip,
                     "hostname" => name,
                     "source" => "proxmox",
                     "metadata" => %{
                       "integration_type" => "proxmox",
                       "integration_id" => integration_id
                     }
                   }
                 ],
                 actor: actor
               )

      [identifier] =
        DeviceIdentifier
        |> Ash.Query.filter(
          identifier_type == :integration_id and identifier_value == ^integration_id
        )
        |> Ash.read!(actor: actor)

      refute identifier.device_id == agent_uid

      assert identifiers(agent_uid, actor) ==
               Enum.sort([{:agent_id, agent_id}, {:mac, mac_value(mac)}])

      assert identifiers(identifier.device_id, actor) == [{:integration_id, integration_id}]
      review = decision(:policy_block, [agent_uid, identifier.device_id], actor)
      assert review.reason == "hostname_agreement_not_identity"
      assert review.evidence["refusal"] == "agent_bound_holder"
    end

    test "shared eligible MACs do not create corroboration for an operator-distinct pair",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      name = "node#{uniq}"
      [agent_mac, holder_mac] = host_macs(uniq, 2)
      agent_ip = doc_ip(uniq, 0)
      holder_ip = doc_ip(uniq, 1)
      agent_id = "agent-distinct-#{uniq}"

      attrs = %{
        hostname: "#{name}.example.com",
        source_ip: agent_ip,
        partition: "default",
        host_interfaces: [host_nic("eno1", agent_mac, [agent_ip])]
      }

      assert {:ok, agent_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
      holder_uid = known_host!(name, holder_ip, [holder_mac], actor)
      operator = %{id: "identity-test-operator", email: "operator@example.com", role: :operator}

      DistinctDeviceAssertion
      |> Ash.Changeset.for_create(:assert, %{device_a: agent_uid, device_b: holder_uid},
        actor: operator
      )
      |> Ash.create!(actor: operator)

      attrs = %{
        attrs
        | host_interfaces: [
            host_nic("eno1", agent_mac, [agent_ip]),
            host_nic("eno2", holder_mac, [holder_ip])
          ]
      }

      assert {:ok, ^agent_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
      assert {:ok, %{deleted_at: nil}} = Device.get_by_uid(holder_uid, false, actor: actor)
      assert identifiers(holder_uid, actor) == [{:mac, mac_value(holder_mac)}]
      assert decision(:guard_block, [agent_uid, holder_uid], actor).reason == "asserted_distinct"

      assert {:ok, decisions} = IdentityDecision.for_device(agent_uid, actor: actor)
      refute Enum.any?(decisions, &(&1.reason == "agent_corroboration_not_identity"))
    end

    test "primary address corroboration survives address reassignment", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      name = "node#{uniq}"
      ip = doc_ip(uniq, 0)
      [known_mac, agent_mac] = host_macs(uniq, 2)
      known_uid = known_host!(name, ip, [known_mac], actor)

      assert {:ok, agent_uid} =
               AgentGatewaySync.ensure_device_for_agent("agent-primary-#{uniq}", %{
                 hostname: "#{name}.example.com",
                 source_ip: ip,
                 partition: "default",
                 host_interfaces: [host_nic("eno1", agent_mac, [ip])]
               })

      refute agent_uid == known_uid
      assert {:ok, %{ip: nil}} = Device.get_by_uid(known_uid, false, actor: actor)
      assert corroboration_review(agent_uid, known_uid, actor).subject == ip
    end

    # A hypervisor node an inventory knows only by its integration id, with the agent's address as
    # a confirmed alias. The agent shares no strong identifier with it, so it gets its own device;
    # the node keeps its identity and the agent takes none of it. The address follows the agent
    # (the node's alias is invalidated, as documented), and the pair goes to review.
    test "an agent sharing no strong identifier gets its own device and takes none of the other's",
         %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      name = "node#{uniq}"
      [mgmt_mac] = host_macs(uniq, 1)
      cluster_ip = doc_ip(uniq, 0)
      mgmt_ip = doc_ip(uniq, 1)

      integration_id =
        "proxmox:v3:#{Ecto.UUID.generate()}:#{Ecto.UUID.generate()}:cluster:node:#{name}"

      node_uid = integration_node!(name, cluster_ip, integration_id, actor)
      :ok = AvailabilityFixtures.ip_alias!(%{uid: node_uid}, mgmt_ip, DateTime.utc_now())
      agent_id = "agent-no-shared-id-#{uniq}"

      attrs = %{
        hostname: "#{name}.site-a.example.com",
        source_ip: mgmt_ip,
        partition: "default",
        capabilities: ["sysmon"],
        host_macs: [mgmt_mac],
        host_interfaces: [
          host_nic("eno1", mgmt_mac, [mgmt_ip])
        ]
      }

      assert {:ok, agent_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
      assert {:ok, ^agent_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)

      refute agent_uid == node_uid
      assert identifiers(node_uid, actor) == [{:integration_id, integration_id}]

      assert identifiers(agent_uid, actor) ==
               Enum.sort([
                 {:agent_id, agent_id},
                 {:mac, mac_value(mgmt_mac)}
               ])

      assert alias_state(node_uid, mgmt_ip) == "stale"
      assert decision(:alias_invalidated, [agent_uid, node_uid], actor)
      assert corroboration_review(agent_uid, node_uid, actor).subject == mgmt_ip
    end
  end

  # A Proxmox VE node's own certificate (pve-ssl.pem) is unique to the node: the inventory reads
  # its fingerprint from the PVE API and the agent on the node from the certificate its local
  # pveproxy serves. The shared value links a node the API reports with no MAC to its agent.
  describe "agent host identity by Proxmox node certificate" do
    test "an agent with no MAC links to its node's record by the node certificate", %{
      actor: actor
    } do
      uniq = System.unique_integer([:positive, :monotonic])
      certificate = node_certificate()
      scope = proxmox_scope()
      host_ref = ingest_proxmox_node!(actor, scope, uniq, "node#{uniq}", certificate)
      [node_uid] = live_holders(:integration_id, host_ref)
      agent_id = "agent-pve-#{uniq}"

      assert {:ok, ^node_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "node#{uniq}.example.com",
                 source_ip: doc_ip(uniq, 1),
                 partition: "default",
                 capabilities: ["sysmon"],
                 host_tls_fingerprints: [%{port: 8006, sha256: certificate}]
               })

      assert identifiers(node_uid, actor) ==
               Enum.sort([
                 {:agent_id, agent_id},
                 {:integration_id, host_ref},
                 {:tls_certificate_fingerprint, "pve:sha256:" <> certificate}
               ])
    end

    # Records split before the plugin and agent releases that report the certificate converge on
    # one device once both have reported it, whichever release lands first.
    test "a node and its agent split before the certificate was reported converge on one record",
         %{actor: actor} do
      for agent_first? <- [true, false] do
        uniq = System.unique_integer([:positive, :monotonic])
        certificate = node_certificate()
        scope = proxmox_scope()
        host_ref = ingest_proxmox_node!(actor, scope, uniq, "node#{uniq}", nil)
        agent_id = "agent-pve-split-#{uniq}"
        attrs = %{hostname: "node#{uniq}", source_ip: doc_ip(uniq, 1), partition: "default"}

        assert {:ok, agent_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
        assert [node_uid] = live_holders(:integration_id, host_ref)
        refute agent_uid == node_uid

        report_node = fn ->
          ^host_ref = ingest_proxmox_node!(actor, scope, uniq, "node#{uniq}", certificate)
        end

        report_agent = fn ->
          {:ok, _uid} =
            AgentGatewaySync.ensure_device_for_agent(
              agent_id,
              Map.put(attrs, :host_tls_fingerprints, [%{port: 8006, sha256: certificate}])
            )
        end

        steps =
          if agent_first?, do: [report_agent, report_node], else: [report_node, report_agent]

        Enum.each(steps, & &1.())

        assert [uid] = live_holders(:agent_id, agent_id)
        assert live_holders(:integration_id, host_ref) == [uid]
      end
    end

    test "same-named nodes with distinct certificates never fuse", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      [site_a_certificate, site_b_certificate] = [node_certificate(), node_certificate()]

      site_a_ref =
        ingest_proxmox_node!(actor, proxmox_scope(), uniq, "node#{uniq}", site_a_certificate)

      site_b_ref =
        ingest_proxmox_node!(actor, proxmox_scope(), uniq, "node#{uniq}", site_b_certificate)

      [site_a_uid] = live_holders(:integration_id, site_a_ref)
      [site_b_uid] = live_holders(:integration_id, site_b_ref)
      refute site_a_uid == site_b_uid
      agent_id = "agent-pve-site-b-#{uniq}"

      assert {:ok, ^site_b_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, %{
                 hostname: "node#{uniq}",
                 source_ip: doc_ip(uniq, 1),
                 partition: "default",
                 host_tls_fingerprints: [%{port: 8006, sha256: site_b_certificate}]
               })

      assert identifiers(site_a_uid, actor) ==
               Enum.sort([
                 {:integration_id, site_a_ref},
                 {:tls_certificate_fingerprint, "pve:sha256:" <> site_a_certificate}
               ])
    end

    # A node certificate copied with a cloned node's configuration is one value on two hosts.
    # Once both agents hold their own devices, the shared value never merges them.
    test "two agents reporting one certificate keep their own devices", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      certificate = node_certificate()

      enroll = fn n, fingerprints ->
        assert {:ok, uid} =
                 AgentGatewaySync.ensure_device_for_agent("agent-pve-clone-#{n}-#{uniq}", %{
                   hostname: "node#{uniq}",
                   source_ip: doc_ip(uniq, n),
                   partition: "default",
                   host_tls_fingerprints: fingerprints
                 })

        uid
      end

      [first_uid, second_uid] = for n <- 1..2, do: enroll.(n, [])
      shared = [%{port: 8006, sha256: certificate}]

      assert [^first_uid, ^second_uid] = for(n <- 1..2, do: enroll.(n, shared))
      refute first_uid == second_uid
      assert {:agent_id, "agent-pve-clone-1-#{uniq}"} in identifiers(first_uid, actor)
      assert {:agent_id, "agent-pve-clone-2-#{uniq}"} in identifiers(second_uid, actor)

      assert decision(:guard_block, [first_uid, second_uid], actor).reason ==
               "distinct_agent_identity"
    end

    # A renewed node certificate registers beside the old one, which ages out with its identifier.
    test "a renewed node certificate keeps the node's record", %{actor: actor} do
      uniq = System.unique_integer([:positive, :monotonic])
      [certificate, renewed] = [node_certificate(), node_certificate()]
      scope = proxmox_scope()
      host_ref = ingest_proxmox_node!(actor, scope, uniq, "node#{uniq}", certificate)
      [node_uid] = live_holders(:integration_id, host_ref)
      agent_id = "agent-pve-renewal-#{uniq}"

      attrs = fn fingerprint ->
        %{
          hostname: "node#{uniq}",
          source_ip: doc_ip(uniq, 1),
          partition: "default",
          host_tls_fingerprints: [%{port: 8006, sha256: fingerprint}]
        }
      end

      assert {:ok, ^node_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, attrs.(certificate))

      ^host_ref = ingest_proxmox_node!(actor, scope, uniq, "node#{uniq}", renewed)

      assert {:ok, ^node_uid} =
               AgentGatewaySync.ensure_device_for_agent(agent_id, attrs.(renewed))

      assert {:tls_certificate_fingerprint, "pve:sha256:" <> renewed} in identifiers(
               node_uid,
               actor
             )

      assert live_holders(:tls_certificate_fingerprint, "pve:sha256:" <> renewed) == [node_uid]
    end
  end

  # The user's decision of 2026-10-28: "armis records and stuff learned about an endpoint
  # through an agent should be fine to merge together". An agent's eligible MAC links it to, and
  # merges it with, an Armis-held record of the same endpoint, and the value pushed northbound
  # follows the merged device: the agent's check-in marks it available (legacy semantics through
  # the compatibility table, merged semantics through agent self-report evidence).
  describe "agent host identity and Armis northbound (user-approved change)" do
    setup %{actor: actor} do
      # A source needs a registered agent.
      agent_uid = "agent-" <> Ecto.UUID.generate()

      Agent
      |> Ash.Changeset.for_create(:register_connected, %{uid: agent_uid, name: agent_uid},
        actor: actor
      )
      |> Ash.create!(actor: actor)

      legacy =
        actor
        |> AvailabilityFixtures.armis_source!("SITE01 legacy")
        |> AvailabilityFixtures.keep_legacy_semantics!()

      {:ok, sources: [legacy, AvailabilityFixtures.armis_source!(actor, "SITE01 merged")]}
    end

    test "an agent linking onto an Armis record by a shared MAC makes both semantics push it up",
         %{actor: actor, sources: sources} do
      pushed =
        for source <- sources do
          uniq = System.unique_integer([:positive, :monotonic])
          [nic_mac] = host_macs(uniq, 1)
          armis = armis_endpoint!(actor, source, uniq, nic_mac)
          {:ok, _} = Availability.resolve_devices([armis.uid])
          before = pushed(source, armis.armis_id)

          assert {:ok, agent_uid} =
                   AgentGatewaySync.ensure_device_for_agent("agent-armis-link-#{uniq}", %{
                     hostname: "endpoint#{uniq}.site-a.example.com",
                     source_ip: armis.ip,
                     partition: "default",
                     capabilities: ["sysmon"],
                     host_macs: [nic_mac],
                     host_interfaces: [host_nic("eno1", nic_mac, [armis.ip])]
                   })

          assert agent_uid == armis.uid
          {:ok, _} = Availability.resolve_devices([armis.uid])

          replace_uid(
            {source.northbound_availability_semantics, before, pushed(source, armis.armis_id)},
            armis.uid
          )
        end

      # Legacy semantics pushed Armis's own "down" and now push the agent's check-in. Merged
      # semantics had no availability state for an Armis-only device and withheld it; the
      # agent's self-report now resolves it available.
      assert pushed == [
               {:legacy, {:device, false}, {:device, true}},
               {:merged, {:withheld, "missing_availability"}, {:device, true}}
             ]
    end

    test "merging an Armis record into the agent's device moves the Armis id to the agent's device",
         %{actor: actor, sources: sources} do
      for source <- sources do
        uniq = System.unique_integer([:positive, :monotonic])
        [agent_mac, endpoint_mac] = host_macs(uniq, 2)
        agent_id = "agent-armis-merge-#{uniq}"
        agent_ip = doc_ip(uniq, 3)

        attrs = %{
          hostname: "endpoint#{uniq}.site-a.example.com",
          source_ip: agent_ip,
          partition: "default",
          capabilities: ["sysmon"],
          host_macs: [agent_mac],
          host_interfaces: [host_nic("eno1", agent_mac, [agent_ip])]
        }

        assert {:ok, agent_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
        armis = armis_endpoint!(actor, source, uniq, endpoint_mac)

        # The agent's next check-in reports the endpoint's NIC too: the Resolver finds the two
        # records and merges them; the agent's device, holding the agent id, survives.
        attrs = %{
          attrs
          | host_interfaces: attrs.host_interfaces ++ [host_nic("eno2", endpoint_mac, [])]
        }

        assert {:ok, ^agent_uid} = AgentGatewaySync.ensure_device_for_agent(agent_id, attrs)
        {:ok, _} = Availability.resolve_devices([agent_uid])

        assert {:ok, %Device{deleted_reason: "merged"}} =
                 Device.get_by_uid(armis.uid, true, actor: actor)

        assert {:armis_device_id, armis.armis_id} in identifiers(agent_uid, actor)
        assert pushed(source, armis.armis_id) == {agent_uid, true}
      end
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

  defp enroll_moving_and_holder(moving_agent_id, original_ip, holder_agent_id, held_ip) do
    :ok =
      AgentGatewaySync.upsert_agent(moving_agent_id, %{
        host: original_ip,
        capabilities: ["sysmon"]
      })

    {:ok, moving_uid} =
      AgentGatewaySync.ensure_device_for_agent(moving_agent_id, %{
        hostname: "moving-host-#{moving_agent_id}",
        source_ip: original_ip,
        partition: "default",
        capabilities: ["sysmon"]
      })

    :ok =
      AgentGatewaySync.upsert_agent(holder_agent_id, %{host: held_ip, capabilities: ["sysmon"]})

    {:ok, holder_uid} =
      AgentGatewaySync.ensure_device_for_agent(holder_agent_id, %{
        hostname: "holder-host-#{holder_agent_id}",
        source_ip: held_ip,
        partition: "default",
        capabilities: ["sysmon"]
      })

    {moving_uid, holder_uid}
  end

  defp set_last_seen!(device_uid, last_seen_time, actor) do
    {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)

    {:ok, _device} =
      device
      |> Ash.Changeset.for_update(:gateway_sync, %{last_seen_time: last_seen_time})
      |> Ash.update(actor: actor)
  end

  # The device was last seen, and last observed with an identity (its agent's check-in), at
  # `observed_at`.
  defp set_observed!(device_uid, observed_at, actor) do
    {:ok, device} = Device.get_by_uid(device_uid, false, actor: actor)

    {:ok, _device} =
      device
      |> Ash.Changeset.for_update(:gateway_sync, %{
        last_seen_time: observed_at,
        identity_observed_at: observed_at
      })
      |> Ash.update(actor: actor)
  end

  defp assert_ip_conflict_recorded(
         device_uid,
         holder_uid,
         ip,
         proposed_action,
         actor,
         reason \\ nil
       ) do
    assert {:ok, decisions} = IdentityDecision.for_device(device_uid, actor: actor)

    assert Enum.any?(decisions, fn decision ->
             decision.decision_kind == :ip_conflict and decision.subject == ip and
               decision.device_uids == Enum.sort([device_uid, holder_uid]) and
               decision.evidence["proposed_action"] == proposed_action and
               (is_nil(reason) or decision.evidence["reason"] == reason)
           end)
  end

  defp set_agent_last_seen!(agent_id, last_seen_time, actor) do
    {:ok, agent} = Agent.get_by_uid(agent_id, actor: actor)

    {:ok, _agent} =
      agent
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:last_seen_time, last_seen_time)
      |> Ash.update(actor: actor)
  end

  # An agentless, Armis-identified device (so a check-in never adopts it) at `ip` in
  # `partition`, last seen at `last_seen_time`.
  defp create_seen_device!(partition, ip, last_seen_time, actor) do
    uid = "sr:" <> Ecto.UUID.generate()
    armis_id = "armis-synthetic-" <> Ecto.UUID.generate()

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: uid,
        ip: ip,
        partition: partition,
        discovery_sources: ["armis"],
        metadata: %{"armis_device_id" => armis_id, "integration_type" => "armis"},
        last_seen_time: last_seen_time,
        is_available: true
      })
      |> Ash.create(actor: actor)

    uid
  end

  # Distinct host addresses in the 198.18.0.0/15 benchmarking range, per test and offset.
  defp unique_test_ip(uniq, offset) do
    n = rem(uniq * 2 + offset, 512 * 250)
    net = div(n, 250)
    "198.#{18 + div(net, 256)}.#{rem(net, 256)}.#{rem(n, 250) + 1}"
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

  # -- agent host identity fixtures -------------------------------------------------------

  # A physical NIC as the agent's inventory reports it: its permanent MAC is identity.
  defp host_nic(name, mac, ips) do
    %{
      name: name,
      mac: mac,
      permanent_mac: mac,
      ips: ips,
      oper_state: "up",
      kind: :HOST_INTERFACE_KIND_PHYSICAL,
      mac_provenance: :MAC_PROVENANCE_PERMANENT,
      master: ""
    }
  end

  # Invented, globally administered MACs, distinct per test.
  defp host_macs(uniq, count) do
    for n <- 1..count do
      suffix = rem(uniq * 4 + n, 0x1000000)

      Enum.map_join(
        [
          0x00,
          0x1A,
          0x2C,
          div(suffix, 0x10000),
          rem(div(suffix, 0x100), 0x100),
          rem(suffix, 0x100)
        ],
        ":",
        &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0"))
      )
    end
  end

  defp mac_value(mac), do: mac |> String.replace(":", "") |> String.upcase()

  # Documentation addresses (RFC 5737), distinct per test and offset.
  defp doc_ip(uniq, offset) do
    n = rem(uniq * 8 + offset, 3 * 254)
    net = Enum.at(["192.0.2", "198.51.100", "203.0.113"], div(n, 254))
    "#{net}.#{rem(n, 254) + 1}"
  end

  # A host network discovery already identified: its NIC MACs, at an address.
  defp known_host!(hostname, ip, macs, actor) do
    uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: uid,
        hostname: hostname,
        ip: ip,
        type: "Hypervisor",
        discovery_sources: ["mapper"]
      })
      |> Ash.create(actor: actor)

    for mac <- macs, do: identifier!(uid, :mac, mac_value(mac), "mapper", actor)
    uid
  end

  # A hypervisor node an inventory reports only by its integration id.
  defp integration_node!(hostname, ip, integration_id, actor) do
    uid = "sr:" <> Ecto.UUID.generate()

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: uid,
        hostname: hostname,
        ip: ip,
        type: "Hypervisor",
        discovery_sources: ["hypervisor_enrichment"],
        metadata: %{"integration_id" => integration_id, "integration_type" => "proxmox"}
      })
      |> Ash.create(actor: actor)

    identifier!(uid, :integration_id, integration_id, "sync_ingestor", actor)
    uid
  end

  # An invented node certificate fingerprint: a bare SHA-256 hex digest, as the agent reports it.
  defp node_certificate, do: 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp proxmox_scope do
    %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "default"
    }
  end

  # A Proxmox node as the plugin reports it, with its node certificate when one is given. Returns
  # the node's integration id.
  defp ingest_proxmox_node!(actor, scope, uniq, node, certificate) do
    cluster = "cluster-#{uniq}"

    node_entry =
      then(%{"node" => node, "status" => "online", "ip" => doc_ip(uniq, 0)}, fn entry ->
        if certificate,
          do: Map.put(entry, "tls_certificate_fingerprint", "pve:sha256:" <> certificate),
          else: entry
      end)

    payload = %{
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "details" => %{
        "schema" => "serviceradar.proxmox_enrichment.v1",
        "targets" => [
          %{
            "cluster" => [%{"type" => "cluster", "name" => cluster}],
            "nodes" => [node_entry],
            "guests" => []
          }
        ]
      }
    }

    assert :ok = ProxmoxEnrichmentIngestor.ingest(payload, %{}, actor: actor, source_scope: scope)

    {:ok, identity} =
      IntegrationIdentity.proxmox_v3_fields(
        scope.integration_id,
        scope.controller_id,
        cluster,
        "node",
        node
      )

    identity.provider_ref
  end

  # The live devices holding an identifier.
  defp live_holders(type, value) do
    List.flatten(
      Repo.query!(
        """
        SELECT DISTINCT d.uid
        FROM platform.device_identifiers di
        JOIN platform.ocsf_devices d ON d.uid = di.device_id AND d.deleted_at IS NULL
        WHERE di.identifier_type = $1 AND di.identifier_value = $2
        """,
        [Atom.to_string(type), value]
      ).rows
    )
  end

  defp identifier!(uid, type, value, source, actor) do
    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:upsert, %{
        device_id: uid,
        identifier_type: type,
        identifier_value: value,
        partition: "default",
        confidence: :strong,
        source: source
      })
      |> Ash.create(actor: actor)

    :ok
  end

  # An endpoint Armis reports down, in an activated exact collection, whose NIC MAC network
  # discovery registered on its record (in the default partition, where an agent looks).
  defp armis_endpoint!(actor, source, uniq, nic_mac) do
    ip = doc_ip(uniq, 2)
    armis_id = "SITE01-EP-#{uniq}"
    AvailabilityFixtures.ingest_armis!(actor, source, ip, armis_id, false)

    %{rows: [[uid, hostname, mac]]} =
      Repo.query!(
        "SELECT uid, hostname, mac FROM platform.ocsf_devices WHERE ip = $1 AND deleted_at IS NULL",
        [ip]
      )

    identifier!(uid, :mac, mac_value(nic_mac), "mapper", actor)

    armis = %{uid: uid, ip: ip, hostname: hostname, mac: mac, armis_id: armis_id}
    AvailabilityFixtures.activate_armis_collection!(source, [armis])
    armis
  end

  # The production push path: the device the source's population pushes an id from and the value
  # it carries, or why the id is withheld.
  defp pushed(source, armis_id) do
    {:ok, population} = ArmisNorthboundPopulation.load(source)

    case Enum.find(population.candidates, &(&1.armis_device_id == armis_id)) do
      nil ->
        withheld = Enum.find(population.withheld, &(&1.source_object_id == armis_id))
        {:withheld, withheld && withheld.reason}

      candidate ->
        {candidate.device_id, candidate.is_available}
    end
  end

  # The pushes of one endpoint, naming its own device :device.
  defp replace_uid(tuple, uid) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(fn
      {^uid, value} -> {:device, value}
      other -> other
    end)
    |> List.to_tuple()
  end

  defp identifiers(uid, actor) do
    DeviceIdentifier
    |> Ash.Query.filter(device_id == ^uid)
    |> Ash.read!(actor: actor)
    |> Enum.map(&{&1.identifier_type, &1.identifier_value})
    |> Enum.sort()
  end

  defp alias_state(uid, ip) do
    %{rows: [[state]]} =
      Repo.query!(
        "SELECT state FROM platform.device_alias_states WHERE device_id = $1 AND alias_value = $2",
        [uid, ip]
      )

    state
  end

  defp decision(kind, uids, actor) do
    sorted = Enum.sort(uids)

    IdentityDecision
    |> Ash.Query.filter(decision_kind == ^kind)
    |> Ash.read!(actor: actor)
    |> Enum.find(&(Enum.sort(&1.device_uids) == sorted))
  end

  defp corroboration_review(uid, other_uid, actor) do
    review = decision(:policy_block, [uid, other_uid], actor)
    assert %{reason: "agent_corroboration_not_identity"} = review
    review
  end

  defp restore_env_snapshot(key, {:ok, value}),
    do: Application.put_env(:serviceradar_core, key, value)

  defp restore_env_snapshot(key, :error), do: Application.delete_env(:serviceradar_core, key)
end
