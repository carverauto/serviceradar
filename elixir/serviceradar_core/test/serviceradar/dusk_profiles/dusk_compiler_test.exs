defmodule ServiceRadar.AgentConfig.Compilers.DuskCompilerTest do
  @moduledoc """
  Tests for the DuskCompiler module.

  Tests config compilation, validation, and profile resolution.
  In the single-deployment architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.DuskCompiler
  alias ServiceRadar.DuskProfiles.DuskProfile

  require Ash.Query

  describe "module structure" do
    test "module is loaded and defined" do
      assert Code.ensure_loaded?(DuskCompiler)
    end

    test "implements Compiler behaviour" do
      behaviours = DuskCompiler.__info__(:attributes)[:behaviour] || []
      assert ServiceRadar.AgentConfig.Compiler in behaviours
    end

    test "config_type returns :dusk" do
      assert DuskCompiler.config_type() == :dusk
    end

    test "source_resources returns expected modules" do
      resources = DuskCompiler.source_resources()
      assert DuskProfile in resources
    end
  end

  describe "default_config/0" do
    test "returns valid config structure with dusk disabled" do
      config = DuskCompiler.default_config()

      assert config["enabled"] == false
      assert config["node_address"] == ""
      assert config["timeout"] == "5m"
      assert config["profile_id"] == nil
      assert config["profile_name"] == nil
      assert config["config_source"] == "default"
    end
  end

  describe "validate/1" do
    test "valid disabled config passes validation" do
      config = DuskCompiler.default_config()
      assert :ok = DuskCompiler.validate(config)
    end

    test "valid enabled config passes validation" do
      config = %{
        "enabled" => true,
        "node_address" => "localhost:8080",
        "timeout" => "5m"
      }

      assert :ok = DuskCompiler.validate(config)
    end

    test "config missing enabled key fails" do
      config = %{"node_address" => "localhost:8080"}
      assert {:error, "Config missing 'enabled' key"} = DuskCompiler.validate(config)
    end

    test "enabled config missing node_address fails" do
      config = %{"enabled" => true, "node_address" => ""}
      assert {:error, "Config enabled but missing 'node_address'"} = DuskCompiler.validate(config)
    end

    test "enabled config with node_address passes" do
      config = %{"enabled" => true, "node_address" => "localhost:8080"}
      assert :ok = DuskCompiler.validate(config)
    end
  end

  describe "compile/3" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    @tag :integration
    test "returns disabled default config when no profile exists" do
      {:ok, config} = DuskCompiler.compile("default", "agent-1", [])

      assert config["enabled"] == false
      assert config["node_address"] == ""
      assert config["config_source"] == "default"
    end

    @tag :integration
    test "returns profile config when default profile exists" do
      # Create a default profile
      actor = SystemActor.system(:test)

      {:ok, profile} =
        DuskProfile
        |> Ash.Changeset.for_create(:create, %{
          name: "Test Default Dusk",
          node_address: "localhost:8080",
          timeout: "10m",
          is_default: true,
          enabled: true
        }, actor: actor)
        |> Ash.create(actor: actor)

      {:ok, config} = DuskCompiler.compile("default", "agent-1", [])

      assert config["enabled"] == true
      assert config["node_address"] == "localhost:8080"
      assert config["timeout"] == "10m"
      assert config["profile_id"] == profile.id
      assert config["profile_name"] == "Test Default Dusk"
    end
  end

  describe "compile_profile/1" do
    test "converts profile to config format" do
      profile = %DuskProfile{
        id: "test-uuid",
        name: "Production Dusk Node",
        enabled: true,
        node_address: "dusk-node.example.com:8080",
        timeout: "5m",
        is_default: false,
        target_query: "in:devices tags.role:dusk-node"
      }

      config = DuskCompiler.compile_profile(profile)

      assert config["enabled"] == true
      assert config["node_address"] == "dusk-node.example.com:8080"
      assert config["timeout"] == "5m"
      assert config["profile_id"] == "test-uuid"
      assert config["profile_name"] == "Production Dusk Node"
      assert config["config_source"] == "srql"
    end

    test "sets config_source to default for default profile" do
      profile = %DuskProfile{
        id: "default-uuid",
        name: "Default Dusk Profile",
        enabled: true,
        node_address: "localhost:8080",
        timeout: "5m",
        is_default: true,
        target_query: nil
      }

      config = DuskCompiler.compile_profile(profile)
      assert config["config_source"] == "default"
    end

    test "sets config_source to profile when no target_query and not default" do
      profile = %DuskProfile{
        id: "profile-uuid",
        name: "Named Profile",
        enabled: true,
        node_address: "localhost:8080",
        timeout: "5m",
        is_default: false,
        target_query: nil
      }

      config = DuskCompiler.compile_profile(profile)
      assert config["config_source"] == "profile"
    end
  end
end
