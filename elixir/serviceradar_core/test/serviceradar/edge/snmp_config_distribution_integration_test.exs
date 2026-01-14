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

  setup do
    %{tenant_id: tenant_id, tenant_slug: tenant_slug} =
      TestSupport.create_tenant_schema!("snmp-config")

    on_exit(fn ->
      TestSupport.drop_tenant_schema!(tenant_slug)
    end)

    actor = %{
      id: Ash.UUID.generate(),
      email: "snmp-config@serviceradar.local",
      role: :admin,
      tenant_id: tenant_id
    }

    agent_id = "agent-#{System.unique_integer([:positive])}"

    {:ok, tenant_id: tenant_id, actor: actor, agent_id: agent_id}
  end

  describe "SNMP config compilation" do
    @tag :integration
    test "includes SNMP config in agent payload with default profile", %{
      tenant_id: tenant_id,
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
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Create a default SNMP profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Default SNMP Profile",
            is_default: true,
            enabled: true,
            poll_interval_seconds: 60,
            timeout_seconds: 5,
            retries: 2
          },
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Create an SNMP target
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Router Target",
            host: device.ip,
            port: 161,
            snmp_version: :v2c,
            community: "public",
            snmp_profile_id: profile.id
          },
          actor: actor,
          tenant: tenant_id,
          authorize?: false
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
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Get SNMP config via ConfigServer
      {:ok, entry} = ConfigServer.get_config(tenant_id, :snmp, "default", agent_id)

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
      tenant_id: tenant_id,
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
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Create a targeting SNMP profile that matches core-switch-* devices
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Core Switch Profile",
            target_query: "in:devices hostname:core-switch-*",
            priority: 10,
            enabled: true,
            poll_interval_seconds: 30,
            timeout_seconds: 3,
            retries: 1
          },
          actor: actor,
          tenant: tenant_id,
          authorize?: false
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
            snmp_version: :v2c,
            community: "switch-community",
            snmp_profile_id: profile.id
          },
          actor: actor,
          tenant: tenant_id,
          authorize?: false
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
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Get config - the targeting profile should be resolved for this device
      {:ok, entry} =
        ConfigServer.get_config(tenant_id, :snmp, "default", agent_id, device_uid: device.uid)

      assert is_map(entry.config)
      assert entry.config["enabled"] == true

      targets = entry.config["targets"]
      refute Enum.empty?(targets)
    end

    @tag :integration
    test "agent config generator includes SNMP in full config", %{
      tenant_id: tenant_id,
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
            name: "Agent Test Profile",
            is_default: true,
            enabled: true,
            poll_interval_seconds: 120
          },
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Create a target
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Target",
            host: "10.10.10.#{rem(unique_id, 254) + 1}",
            port: 161,
            snmp_version: :v2c,
            community: "test",
            snmp_profile_id: profile.id
          },
          actor: actor,
          tenant: tenant_id,
          authorize?: false
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
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Generate full agent config
      {:ok, agent_config} = AgentConfigGenerator.generate_config(agent_id, tenant_id)
      payload = Jason.decode!(agent_config.config_json)

      # Verify SNMP config is included
      snmp_payload = payload["snmp"]
      assert snmp_payload != nil
      assert snmp_payload["enabled"] == true
      assert is_list(snmp_payload["targets"])
      refute Enum.empty?(snmp_payload["targets"])
    end

    @tag :integration
    test "disabled profile does not include SNMP config", %{
      tenant_id: tenant_id,
      actor: actor,
      agent_id: agent_id
    } do
      # Create a disabled SNMP profile
      {:ok, _profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Disabled Profile",
            is_default: true,
            enabled: false,
            poll_interval_seconds: 60
          },
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Get config
      {:ok, entry} = ConfigServer.get_config(tenant_id, :snmp, "default", agent_id)

      # Should be disabled or have no targets
      assert entry.config["enabled"] == false || entry.config["targets"] == []
    end

    @tag :integration
    test "SNMPv3 config is properly compiled", %{
      tenant_id: tenant_id,
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
            name: "SNMPv3 Profile",
            is_default: true,
            enabled: true,
            poll_interval_seconds: 60
          },
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Create SNMPv3 target
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "SNMPv3 Target",
            host: "10.20.30.#{rem(unique_id, 254) + 1}",
            port: 161,
            snmp_version: :v3,
            v3_username: "admin",
            v3_security_level: :auth_priv,
            v3_auth_protocol: :sha,
            v3_auth_password: "authpass123",
            v3_priv_protocol: :aes,
            v3_priv_password: "privpass456",
            snmp_profile_id: profile.id
          },
          actor: actor,
          tenant: tenant_id,
          authorize?: false
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
          actor: actor,
          tenant: tenant_id,
          authorize?: false
        )
        |> Ash.create()

      # Get config
      {:ok, entry} = ConfigServer.get_config(tenant_id, :snmp, "default", agent_id)

      assert entry.config["enabled"] == true

      targets = entry.config["targets"]
      v3_target = Enum.find(targets, fn t -> t["version"] == "v3" end)

      assert v3_target != nil
      assert v3_target["v3_auth"] != nil
      assert v3_target["v3_auth"]["username"] == "admin"
      assert v3_target["v3_auth"]["security_level"] == "auth_priv"
      assert v3_target["v3_auth"]["auth_protocol"] == "sha"
      assert v3_target["v3_auth"]["priv_protocol"] == "aes"
      # Passwords should be present (may be encrypted)
      assert v3_target["v3_auth"]["auth_password"] != nil
      assert v3_target["v3_auth"]["priv_password"] != nil
    end
  end
end
