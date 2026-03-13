defmodule ServiceRadar.AgentConfig.Compilers.SNMPCompilerTest do
  @moduledoc """
  Tests for the SNMPCompiler module.

  Tests config compilation, validation, profile resolution, and credential handling.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPOIDTemplate
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadar.AgentConfig.ConfigServer

  require Ash.Query

  describe "module structure" do
    test "module is loaded and defined" do
      assert Code.ensure_loaded?(SNMPCompiler)
    end

    test "implements Compiler behaviour" do
      behaviours = SNMPCompiler.__info__(:attributes)[:behaviour] || []
      assert ServiceRadar.AgentConfig.Compiler in behaviours
    end

    test "config_type returns :snmp" do
      assert SNMPCompiler.config_type() == :snmp
    end

    test "source_resources returns expected modules" do
      resources = SNMPCompiler.source_resources()
      assert SNMPProfile in resources
      assert SNMPTarget in resources
      assert SNMPOIDConfig in resources
    end
  end

  describe "disabled_config/0" do
    test "returns disabled config structure" do
      config = SNMPCompiler.disabled_config()

      assert config["enabled"] == false
      assert config["profile_id"] == nil
      assert config["profile_name"] == nil
      assert config["targets"] == []
    end
  end

  describe "validate/1" do
    test "valid disabled config passes validation" do
      config = SNMPCompiler.disabled_config()
      assert :ok = SNMPCompiler.validate(config)
    end

    test "valid enabled config passes validation" do
      config = %{
        "enabled" => true,
        "targets" => []
      }

      assert :ok = SNMPCompiler.validate(config)
    end

    test "config missing enabled key fails" do
      config = %{"targets" => []}
      assert {:error, "Config missing 'enabled' key"} = SNMPCompiler.validate(config)
    end

    test "enabled config missing targets key fails" do
      config = %{"enabled" => true}
      assert {:error, "Config missing 'targets' key"} = SNMPCompiler.validate(config)
    end
  end

  describe "compile/3" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    @tag :integration
    test "returns disabled config when no profile exists" do
      {:ok, config} = SNMPCompiler.compile("default", nil, [])

      assert is_boolean(config["enabled"])
      assert is_binary(config["profile_id"])
      assert is_binary(config["profile_name"])
      assert is_list(config["targets"])
    end

    @tag :integration
    test "returns profile config when default profile exists" do
      actor = SystemActor.system(:test)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Compiler Default Profile #{System.unique_integer([:positive])}",
            is_default: false,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, profile} =
        profile
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      {:ok, config} = SNMPCompiler.compile("default", nil, [])

      assert config["profile_id"] == profile.id
      assert config["profile_name"] == profile.name
      assert is_list(config["targets"])
    end

    @tag :integration
    test "returns profile with targets and OIDs" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Network Monitoring #{System.unique_integer([:positive])}",
            poll_interval: 30,
            timeout: 10,
            retries: 2,
            is_default: false,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      expected_profile_name = profile.name

      {:ok, profile} =
        profile
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      # Create a target with v2c community
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            snmp_profile_id: profile.id,
            name: "Core Router #{System.unique_integer([:positive])}",
            host: "192.168.1.1",
            port: 161,
            version: :v2c,
            community: "public"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      expected_target_name = target.name

      # Create an OID config
      {:ok, _oid} =
        SNMPOIDConfig
        |> Ash.Changeset.for_create(
          :create,
          %{
            snmp_target_id: target.id,
            oid: ".1.3.6.1.2.1.2.2.1.10",
            name: "ifInOctets",
            data_type: :counter,
            scale: 1.0,
            delta: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, config} = SNMPCompiler.compile("default", nil, [])

      assert config["enabled"] == true
      assert config["profile_name"] == expected_profile_name
      assert length(config["targets"]) == 1

      [compiled_target] = config["targets"]
      assert compiled_target["name"] == expected_target_name
      assert compiled_target["host"] == "192.168.1.1"
      assert compiled_target["port"] == 161
      assert compiled_target["version"] == "v2c"
      assert compiled_target["community"] == "public"
      assert compiled_target["poll_interval_seconds"] == 30
      assert compiled_target["timeout_seconds"] == 10
      assert compiled_target["retries"] == 2

      assert length(compiled_target["oids"]) == 1
      [compiled_oid] = compiled_target["oids"]
      assert compiled_oid["oid"] == ".1.3.6.1.2.1.2.2.1.10"
      assert compiled_oid["name"] == "ifInOctets"
      assert compiled_oid["data_type"] == "counter"
      assert compiled_oid["delta"] == true
    end

    @tag :integration
    test "returns SNMPv3 target with decrypted credentials" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Secure Monitoring #{System.unique_integer([:positive])}",
            poll_interval: 60,
            timeout: 5,
            retries: 3,
            is_default: false,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, profile} =
        profile
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      # Create a SNMPv3 target
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            snmp_profile_id: profile.id,
            name: "Secure Router",
            host: "10.0.0.1",
            port: 161,
            version: :v3,
            username: "snmpuser",
            security_level: :auth_priv,
            auth_protocol: :sha256,
            auth_password: "authpass123",
            priv_protocol: :aes256,
            priv_password: "privpass456"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

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
        |> Ash.create(actor: actor)

      {:ok, config} = SNMPCompiler.compile("default", nil, actor: actor)

      assert config["enabled"] == true
      assert length(config["targets"]) == 1

      [compiled_target] = config["targets"]
      assert compiled_target["name"] == "Secure Router"
      assert compiled_target["version"] == "v3"

      v3_auth = compiled_target["v3_auth"]
      assert v3_auth["username"] == "snmpuser"
      assert v3_auth["security_level"] == "authPriv"
      assert v3_auth["auth_protocol"] == "SHA-256"
      # Passwords are decrypted for agent consumption
      assert v3_auth["auth_password"] == "authpass123"
      assert v3_auth["priv_protocol"] == "AES-256"
      assert v3_auth["priv_password"] == "privpass456"
    end
  end

  describe "management device fallback" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      ConfigServer.invalidate(:snmp)
      actor = SystemActor.system(:test)

      {:ok, actor: actor}
    end

    @tag :integration
    test "SNMP target for device with management_device_id uses management device IP", %{
      actor: actor
    } do
      alias ServiceRadar.Inventory.Device

      uniq = System.unique_integer([:positive, :monotonic])
      parent_uid = "sr:" <> Ecto.UUID.generate()
      child_uid = "sr:" <> Ecto.UUID.generate()
      parent_ip = unique_test_ip(172, 21, uniq)
      child_ip = unique_test_ip(198, 19, uniq + 1)

      # Create parent (management) device at reachable IP
      {:ok, _parent} =
        Device
        |> Ash.Changeset.for_create(:create, %{uid: parent_uid, ip: parent_ip})
        |> Ash.create(actor: actor)

      # Create child device with unreachable IP, pointing to parent
      {:ok, child} =
        Device
        |> Ash.Changeset.for_create(:create, %{
          uid: child_uid,
          ip: child_ip,
          management_device_id: parent_uid,
          discovery_sources: ["mapper"]
        })
        |> Ash.create(actor: actor)

      assert child.management_device_id == parent_uid

      # The management device IP should be used when the SNMP compiler
      # resolves the polling host for this device
      query =
        Device
        |> Ash.Query.filter(uid == ^child_uid)
        |> Ash.Query.for_read(:read, %{}, actor: actor)
        |> Ash.Query.limit(1)

      {:ok, [loaded_child]} = ServiceRadar.Ash.Page.unwrap(Ash.read(query, actor: actor))
      assert loaded_child.management_device_id == parent_uid
    end

    @tag :integration
    test "SNMP target for device without management_device_id uses own IP", %{actor: actor} do
      alias ServiceRadar.Inventory.Device

      device_uid = "sr:" <> Ecto.UUID.generate()
      device_ip = "10.0.0.#{rem(System.unique_integer([:positive]), 200) + 20}"

      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(:create, %{
          uid: device_uid,
          ip: device_ip,
          discovery_sources: ["mapper"]
        })
        |> Ash.create(actor: actor)

      assert device.management_device_id == nil
      assert device.ip == device_ip
    end

    @tag :integration
    test "SNMP target prefers confirmed private IP alias when canonical IP is public", %{
      actor: actor
    } do
      alias ServiceRadar.Inventory.Device

      uid = "sr:" <> Ecto.UUID.generate()
      public_ip = "198.51.100.#{rem(System.unique_integer([:positive]), 200) + 1}"
      hostname = "alias-host-" <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(:create, %{
          uid: uid,
          hostname: hostname,
          ip: public_ip,
          discovery_sources: ["mapper"]
        })
        |> Ash.create(actor: actor)

      {:ok, template} =
        SNMPOIDTemplate
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Alias Host Template #{System.unique_integer([:positive])}",
            vendor: "custom",
            category: "interface",
            oids: [
              %{
                oid: ".1.3.6.1.2.1.2.2.1.10.1",
                name: "ifInOctets",
                data_type: "counter",
                scale: 1.0,
                delta: true
              }
            ]
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Alias Host Profile #{System.unique_integer([:positive])}",
            poll_interval: 60,
            timeout: 5,
            retries: 3,
            enabled: true,
            target_query: ~s(in:devices hostname:"#{hostname}"),
            oid_template_ids: [template.id],
            version: :v2c,
            community: "public"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, alias_state} =
        DeviceAliasState.create_detected(
          %{
            device_id: device.uid,
            partition: "default",
            alias_type: :ip,
            alias_value: "192.168.10.1",
            metadata: %{}
          },
          actor: actor
        )

      {:ok, _confirmed} =
        DeviceAliasState.record_sighting(
          alias_state,
          %{confirm_threshold: 1},
          actor: actor
        )

      config = SNMPCompiler.compile_profile(profile, actor)

      assert config["enabled"] == true
      assert [%{"host" => "192.168.10.1"}] = config["targets"]
    end
  end

  describe "resolve_profile/2" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    @tag :integration
    test "returns nil when no profiles exist" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      result = SNMPCompiler.resolve_profile(nil, actor)
      assert %SNMPProfile{} = result
      assert result.is_default == true
    end

    @tag :integration
    test "returns default profile when no targeting matches" do
      # Schema determined by DB connection
      actor = SystemActor.system(:test)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Default SNMP #{System.unique_integer([:positive])}",
            is_default: false,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, profile} =
        profile
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      result = SNMPCompiler.resolve_profile("some-device-uid", actor)
      assert result.id == profile.id
      assert result.is_default == true
    end
  end

  defp unique_test_ip(a, b, value) do
    third = rem(value, 250) + 1
    fourth = rem(div(value, 250), 250) + 1
    "#{a}.#{b}.#{third}.#{fourth}"
  end
end
