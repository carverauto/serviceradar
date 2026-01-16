defmodule ServiceRadar.AgentConfig.Compilers.SysmonCompilerTest do
  @moduledoc """
  Tests for the SysmonCompiler module.

  Tests config compilation, validation, and profile resolution.
  In the tenant-instance architecture, tests run against the single schema
  determined by PostgreSQL search_path.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.SysmonProfiles.SysmonProfile

  require Ash.Query

  describe "module structure" do
    test "module is loaded and defined" do
      assert Code.ensure_loaded?(SysmonCompiler)
    end

    test "implements Compiler behaviour" do
      behaviours = SysmonCompiler.__info__(:attributes)[:behaviour] || []
      assert ServiceRadar.AgentConfig.Compiler in behaviours
    end

    test "config_type returns :sysmon" do
      assert SysmonCompiler.config_type() == :sysmon
    end

    test "source_resources returns expected modules" do
      resources = SysmonCompiler.source_resources()
      assert SysmonProfile in resources
    end
  end

  describe "default_config/0" do
    test "returns valid config structure" do
      config = SysmonCompiler.default_config()

      assert config["enabled"] == true
      assert config["sample_interval"] == "10s"
      assert config["collect_cpu"] == true
      assert config["collect_memory"] == true
      assert config["collect_disk"] == true
      assert config["collect_network"] == false
      assert config["collect_processes"] == false
      assert config["disk_paths"] == []
      assert config["disk_exclude_paths"] == []
      assert config["thresholds"] == %{}
      assert config["profile_name"] == "Default"
      assert config["config_source"] == "default"
    end
  end

  describe "validate/1" do
    test "valid config passes validation" do
      config = SysmonCompiler.default_config()
      assert :ok = SysmonCompiler.validate(config)
    end

    test "config missing enabled key fails" do
      config = %{"sample_interval" => "10s"}
      assert {:error, "Config missing 'enabled' key"} = SysmonCompiler.validate(config)
    end

    test "config missing sample_interval key fails" do
      config = %{"enabled" => true}
      assert {:error, "Config missing 'sample_interval' key"} = SysmonCompiler.validate(config)
    end
  end

  describe "compile/3" do
    @tag :integration
    setup do
      ServiceRadar.TestSupport.start_core!()
      :ok
    end

    @tag :integration
    test "returns default config when no profile exists" do
      {:ok, config} = SysmonCompiler.compile("default", "agent-1", [])

      assert config["enabled"] == true
      assert config["sample_interval"] == "10s"
      assert config["config_source"] == "default"
    end

    @tag :integration
    test "returns profile config when default profile exists" do
      # Create a default profile
      actor = SystemActor.system(:test)

      {:ok, profile} =
        SysmonProfile
        |> Ash.Changeset.for_create(:create, %{
          name: "Test Default",
          sample_interval: "30s",
          collect_cpu: true,
          collect_memory: true,
          collect_disk: false,
          collect_network: true,
          collect_processes: true,
          disk_paths: ["/", "/data"],
          disk_exclude_paths: ["/var/lib/docker"],
          thresholds: %{"cpu_warning" => "75"},
          is_default: true,
          enabled: true
        }, actor: actor)
        |> Ash.create(actor: actor)

      {:ok, config} = SysmonCompiler.compile("default", "agent-1", [])

      assert config["enabled"] == true
      assert config["sample_interval"] == "30s"
      assert config["collect_disk"] == false
      assert config["collect_network"] == true
      assert config["collect_processes"] == true
      assert config["disk_paths"] == ["/", "/data"]
      assert config["disk_exclude_paths"] == ["/var/lib/docker"]
      assert config["thresholds"]["cpu_warning"] == "75"
      assert config["profile_id"] == profile.id
      assert config["profile_name"] == "Test Default"
    end
  end

  describe "compile_profile/1" do
    test "converts profile to config format" do
      profile = %SysmonProfile{
        id: "test-uuid",
        name: "Production Monitoring",
        enabled: true,
        sample_interval: "5s",
        collect_cpu: true,
        collect_memory: true,
        collect_disk: true,
        collect_network: true,
        collect_processes: true,
        disk_paths: ["/", "/var", "/home"],
        disk_exclude_paths: ["/var/lib/docker"],
        thresholds: %{
          "cpu_warning" => "70",
          "cpu_critical" => "90"
        },
        is_default: false,
        target_query: "in:devices tags.env:prod"
      }

      config = SysmonCompiler.compile_profile(profile)

      assert config["enabled"] == true
      assert config["sample_interval"] == "5s"
      assert config["collect_cpu"] == true
      assert config["collect_memory"] == true
      assert config["collect_disk"] == true
      assert config["collect_network"] == true
      assert config["collect_processes"] == true
      assert config["disk_paths"] == ["/", "/var", "/home"]
      assert config["disk_exclude_paths"] == ["/var/lib/docker"]
      assert config["thresholds"]["cpu_warning"] == "70"
      assert config["thresholds"]["cpu_critical"] == "90"
      assert config["profile_id"] == "test-uuid"
      assert config["profile_name"] == "Production Monitoring"
      assert config["config_source"] == "srql"
    end

    test "sets config_source to default for default profile" do
      profile = %SysmonProfile{
        id: "default-uuid",
        name: "Default Profile",
        enabled: true,
        sample_interval: "10s",
        collect_cpu: true,
        collect_memory: true,
        collect_disk: true,
        collect_network: false,
        collect_processes: false,
        disk_paths: [],
        disk_exclude_paths: [],
        thresholds: %{},
        is_default: true,
        target_query: nil
      }

      config = SysmonCompiler.compile_profile(profile)
      assert config["config_source"] == "default"
    end
  end
end
