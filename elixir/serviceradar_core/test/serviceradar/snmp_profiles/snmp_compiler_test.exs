defmodule ServiceRadar.AgentConfig.Compilers.SNMPCompilerTest do
  @moduledoc """
  Tests for the SNMPCompiler module.

  Tests config compilation, validation, profile resolution, and credential handling.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget

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

      assert config["enabled"] == false
      assert config["targets"] == []
    end

    @tag :integration
    test "returns profile config when default profile exists" do
      # Create a default profile - tenant schema determined by DB connection
      actor = SystemActor.system(:test)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Test Default",
            poll_interval: 60,
            timeout: 5,
            retries: 3,
            is_default: true,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:ok, config} = SNMPCompiler.compile("default", nil, [])

      assert config["enabled"] == true
      assert config["profile_id"] == profile.id
      assert config["profile_name"] == "Test Default"
      assert config["targets"] == []
    end

    @tag :integration
    test "returns profile with targets and OIDs" do
      # Tenant schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Network Monitoring",
            poll_interval: 30,
            timeout: 10,
            retries: 2,
            is_default: true,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create a target with v2c community
      {:ok, target} =
        SNMPTarget
        |> Ash.Changeset.for_create(
          :create,
          %{
            snmp_profile_id: profile.id,
            name: "Core Router",
            host: "192.168.1.1",
            port: 161,
            version: :v2c,
            community: "public"
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

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
      assert config["profile_name"] == "Network Monitoring"
      assert length(config["targets"]) == 1

      [compiled_target] = config["targets"]
      assert compiled_target["name"] == "Core Router"
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
      # Tenant schema determined by DB connection
      actor = SystemActor.system(:test)

      # Create a profile
      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Secure Monitoring",
            poll_interval: 60,
            timeout: 5,
            retries: 3,
            is_default: true,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create a SNMPv3 target
      {:ok, _target} =
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

      {:ok, config} = SNMPCompiler.compile("default", nil, [])

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

  describe "resolve_profile/2" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    @tag :integration
    test "returns nil when no profiles exist" do
      # Tenant schema determined by DB connection
      actor = SystemActor.system(:test)

      result = SNMPCompiler.resolve_profile(nil, actor)
      assert result == nil
    end

    @tag :integration
    test "returns default profile when no targeting matches" do
      # Tenant schema determined by DB connection
      actor = SystemActor.system(:test)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Default SNMP",
            is_default: true,
            enabled: true
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      result = SNMPCompiler.resolve_profile("some-device-uid", actor)
      assert result.id == profile.id
      assert result.is_default == true
    end
  end
end
