defmodule ServiceRadar.Edge.SNMPConfigDistributionIntegrationTest do
  @moduledoc """
  Integration tests for SNMP configuration distribution from control plane to agent.

  Tests that:
  - SNMP profiles are compiled correctly
  - Agent config includes SNMP configuration
  - SRQL-based targeting resolves profiles to devices
  - Proto encoding produces valid SNMP config
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  # Schema is determined by DB connection's search_path
  setup do
    ConfigServer.invalidate(:snmp)

    actor = %{
      id: Ash.UUID.generate(),
      email: "snmp-config@serviceradar.local",
      role: :admin
    }

    agent_id = "agent-#{System.unique_integer([:positive])}"

    {:ok, actor: actor, agent_id: agent_id}
  end

  describe "SNMP config compilation" do
    @tag :integration
    test "includes SNMP config in agent payload with default profile", %{
      actor: actor,
      agent_id: agent_id
    } do
      unique_id = System.unique_integer([:positive])
      device_uid = Ecto.UUID.generate()

      # Create a device
      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: "router-#{unique_id}",
            ip: "192.168.1.#{rem(unique_id, 254) + 1}",
            type_id: 3,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create()

      # Create a default SNMP profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Default SNMP Profile",
            is_default: false,
            enabled: true,
            poll_interval: 60,
            timeout: 5,
            retries: 2
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _profile} =
        profile
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      # Create an SNMP target
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Router Target",
            host: device.ip,
            port: 161,
            version: :v2c,
            community: "public",
            snmp_profile_id: profile.id
          },
          actor: actor
        )
        |> Ash.create()

      # Create OID config for the target
      {:ok, _oid} =
        SNMPOIDConfig
        |> Ash.Changeset.for_create(
          :create,
          %{
            oid: ".1.3.6.1.2.1.1.3.0",
            name: "sysUpTime",
            data_type: :timeticks,
            snmp_target_id: target.id
          },
          actor: actor
        )
        |> Ash.create()

      # Get SNMP config via ConfigServer
      {:ok, entry} = ConfigServer.get_config(:snmp, "default", agent_id)

      assert is_map(entry.config)
      assert entry.config["enabled"] == true

      # Verify targets are included
      targets = entry.config["targets"]
      assert is_list(targets)
      refute Enum.empty?(targets)

      target_config = Enum.find(targets, fn t -> t["host"] == device.ip end)
      assert target_config != nil
      assert target_config["port"] == 161
      assert target_config["version"] == "v2c"

      # Verify OIDs are included
      oids = target_config["oids"]
      assert is_list(oids)
      assert Enum.any?(oids, fn o -> o["oid"] == ".1.3.6.1.2.1.1.3.0" end)
    end

    @tag :integration
    test "SRQL targeting matches device to profile", %{
      actor: actor,
      agent_id: agent_id
    } do
      unique_id = System.unique_integer([:positive])
      device_uid = Ecto.UUID.generate()

      # Create a device with specific hostname pattern
      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            hostname: "core-switch-#{unique_id}",
            ip: "10.0.#{rem(unique_id, 254) + 1}.1",
            type_id: 3,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create()

      # Create a targeting SNMP profile that matches core-switch-* devices
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Core Switch Profile",
            target_query: ~s(in:devices hostname:"core-switch-#{unique_id}"),
            priority: 1_000_000 + unique_id,
            enabled: true,
            poll_interval: 30,
            timeout: 3,
            retries: 1
          },
          actor: actor
        )
        |> Ash.create()

      # Create a target for the profile
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Switch Target",
            host: device.ip,
            port: 161,
            version: :v2c,
            community: "switch-community",
            snmp_profile_id: profile.id
          },
          actor: actor
        )
        |> Ash.create()

      # Create OID config
      {:ok, _oid} =
        SNMPOIDConfig
        |> Ash.Changeset.for_create(
          :create,
          %{
            oid: ".1.3.6.1.2.1.2.2.1.10",
            name: "ifInOctets",
            data_type: :counter,
            delta: true,
            snmp_target_id: target.id
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:snmp)

      # Get config - the targeting profile should be resolved for this device
      {:ok, entry} =
        ConfigServer.get_config(:snmp, "default", agent_id, device_uid: device.uid)

      assert is_map(entry.config)
      assert entry.config["enabled"] == true

      targets = entry.config["targets"]
      refute Enum.empty?(targets)
    end

    @tag :integration
    test "device-specific SNMP config cache is scoped by device uid", %{
      actor: actor,
      agent_id: agent_id
    } do
      unique_id = System.unique_integer([:positive])

      {:ok, first_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: Ecto.UUID.generate(),
            hostname: "edge-switch-a-#{unique_id}",
            ip: "10.11.#{rem(unique_id, 200) + 1}.10",
            type_id: 3,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, second_device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: Ecto.UUID.generate(),
            hostname: "edge-switch-b-#{unique_id}",
            ip: "10.12.#{rem(unique_id, 200) + 1}.10",
            type_id: 3,
            created_time: DateTime.utc_now(),
            modified_time: DateTime.utc_now()
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, first_profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Scoped Profile A #{unique_id}",
            target_query: ~s(in:devices hostname:"#{first_device.hostname}"),
            priority: 2_000_000 + unique_id,
            enabled: true,
            poll_interval: 30,
            timeout: 3,
            retries: 1
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, second_profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Scoped Profile B #{unique_id}",
            target_query: ~s(in:devices hostname:"#{second_device.hostname}"),
            priority: 2_100_000 + unique_id,
            enabled: true,
            poll_interval: 30,
            timeout: 3,
            retries: 1
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, first_target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Scoped Target A",
            host: first_device.ip,
            port: 161,
            version: :v2c,
            community: "community-a",
            snmp_profile_id: first_profile.id
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, second_target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Scoped Target B",
            host: second_device.ip,
            port: 161,
            version: :v2c,
            community: "community-b",
            snmp_profile_id: second_profile.id
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _first_oid} =
        SNMPOIDConfig
        |> Ash.Changeset.for_create(
          :create,
          %{
            oid: ".1.3.6.1.2.1.1.3.0",
            name: "sysUpTimeA",
            data_type: :timeticks,
            snmp_target_id: first_target.id
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _second_oid} =
        SNMPOIDConfig
        |> Ash.Changeset.for_create(
          :create,
          %{
            oid: ".1.3.6.1.2.1.1.5.0",
            name: "sysNameB",
            data_type: :string,
            snmp_target_id: second_target.id
          },
          actor: actor
        )
        |> Ash.create()

      ConfigServer.invalidate(:snmp)

      {:ok, first_entry} =
        ConfigServer.get_config(:snmp, "default", agent_id, device_uid: first_device.uid)

      {:ok, second_entry} =
        ConfigServer.get_config(:snmp, "default", agent_id, device_uid: second_device.uid)

      first_hosts = Enum.map(first_entry.config["targets"], & &1["host"])
      second_hosts = Enum.map(second_entry.config["targets"], & &1["host"])

      assert first_device.ip in first_hosts
      refute second_device.ip in first_hosts

      assert second_device.ip in second_hosts
      refute first_device.ip in second_hosts
    end

    @tag :integration
    test "agent config generator includes SNMP in full config", %{
      actor: actor,
      agent_id: agent_id
    } do
      unique_id = System.unique_integer([:positive])

      # Create a default SNMP profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Agent Test Profile #{unique_id}",
            is_default: false,
            enabled: true,
            poll_interval: 120
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _profile} =
        profile
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      # Create a target
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Target",
            host: "10.10.10.#{rem(unique_id, 254) + 1}",
            port: 161,
            version: :v2c,
            community: "test",
            snmp_profile_id: profile.id
          },
          actor: actor
        )
        |> Ash.create()

      # Create OID
      {:ok, _oid} =
        SNMPOIDConfig
        |> Ash.Changeset.for_create(
          :create,
          %{
            oid: ".1.3.6.1.2.1.1.1.0",
            name: "sysDescr",
            data_type: :string,
            snmp_target_id: target.id
          },
          actor: actor
        )
        |> Ash.create()

      # Generate full agent config
      {:ok, agent_config} = AgentConfigGenerator.generate_config(agent_id)
      payload = Jason.decode!(agent_config.config_json)

      # SNMP is carried in the dedicated proto field, not in config_json.
      refute Map.has_key?(payload, "snmp")

      snmp_config = agent_config.snmp_config
      assert snmp_config != nil
      assert snmp_config.enabled == true
      assert is_list(snmp_config.targets)
      refute Enum.empty?(snmp_config.targets)
    end

    @tag :integration
    test "disabled profile does not include SNMP config", %{
      actor: actor,
      agent_id: agent_id
    } do
      unique_id = System.unique_integer([:positive])

      # Create a disabled SNMP profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Disabled Profile #{unique_id}",
            is_default: false,
            enabled: false,
            poll_interval: 60
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, _profile} =
        profile
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      # Get config
      {:ok, entry} = ConfigServer.get_config(:snmp, "default", agent_id)

      # Should be disabled or have no targets
      assert entry.config["enabled"] == false || entry.config["targets"] == []
    end

    @tag :integration
    test "SNMPv3 config is properly compiled", %{
      actor: actor,
      agent_id: agent_id
    } do
      unique_id = System.unique_integer([:positive])

      # Create profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "SNMPv3 Profile #{unique_id}",
            is_default: false,
            enabled: true,
            poll_interval: 60
          },
          actor: actor
        )
        |> Ash.create()

      {:ok, profile} =
        profile
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      # Create SNMPv3 target
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "SNMPv3 Target",
            host: "10.20.30.#{rem(unique_id, 254) + 1}",
            port: 161,
            version: :v3,
            username: "admin",
            security_level: :auth_priv,
            auth_protocol: :sha,
            auth_password: "authpass123",
            priv_protocol: :aes,
            priv_password: "privpass456",
            snmp_profile_id: profile.id
          },
          actor: actor
        )
        |> Ash.create()

      # Create OID
      {:ok, _oid} =
        SNMPOIDConfig
        |> Ash.Changeset.for_create(
          :create,
          %{
            oid: ".1.3.6.1.2.1.1.5.0",
            name: "sysName",
            data_type: :string,
            snmp_target_id: target.id
          },
          actor: actor
        )
        |> Ash.create()

      # Get config
      {:ok, entry} = ConfigServer.get_config(:snmp, "default", agent_id)

      assert entry.config["enabled"] == true

      targets = entry.config["targets"]
      v3_target = Enum.find(targets, fn t -> t["version"] == "v3" end)

      assert v3_target != nil
      assert v3_target["v3_auth"] != nil
      assert v3_target["v3_auth"]["username"] == "admin"
      assert v3_target["v3_auth"]["security_level"] == "authPriv"
      assert v3_target["v3_auth"]["auth_protocol"] == "SHA"
      assert v3_target["v3_auth"]["priv_protocol"] == "AES"
      # Passwords should be present (may be encrypted)
      assert v3_target["v3_auth"]["auth_password"] != nil
      assert v3_target["v3_auth"]["priv_password"] != nil
    end
  end
end
