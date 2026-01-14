defmodule ServiceRadar.AgentConfig.Compilers.SysmonCompilerTest do
  @moduledoc """
  Tests for the SysmonCompiler module.

  Tests config compilation, validation, and profile resolution.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.SysmonProfiles.{SysmonProfile, SysmonProfileAssignment}

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
      assert SysmonProfileAssignment in resources
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
      assert config["disk_paths"] == ["/"]
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

  describe "compile/4" do
    @tag :integration
    setup do
      tenant = ServiceRadar.TestSupport.create_tenant_schema!("sysmon-compiler")

      on_exit(fn ->
        ServiceRadar.TestSupport.drop_tenant_schema!(tenant.tenant_slug)
      end)

      {:ok, tenant_id: tenant.tenant_id, tenant_slug: tenant.tenant_slug}
    end

    @tag :integration
    test "returns default config when no profile exists", %{tenant_id: tenant_id} do
      {:ok, config} = SysmonCompiler.compile(tenant_id, "default", nil, [])

      assert config["enabled"] == true
      assert config["sample_interval"] == "10s"
      assert config["config_source"] == "default"
    end

    @tag :integration
    test "returns profile config when default profile exists", %{tenant_id: tenant_id, tenant_slug: tenant_slug} do
      # Create a default profile
      schema = TenantSchemas.schema_for_tenant(%{slug: tenant_slug})
      actor = SystemActor.for_tenant(tenant_id, :test)

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
          thresholds: %{"cpu_warning" => "75"},
          is_default: true,
          enabled: true
        }, actor: actor, tenant: schema)
        |> Ash.create(actor: actor)

      {:ok, config} = SysmonCompiler.compile(tenant_id, "default", nil, [])

      assert config["enabled"] == true
      assert config["sample_interval"] == "30s"
      assert config["collect_disk"] == false
      assert config["collect_network"] == true
      assert config["collect_processes"] == true
      assert config["disk_paths"] == ["/", "/data"]
      assert config["thresholds"]["cpu_warning"] == "75"
      assert config["profile_id"] == profile.id
      assert config["profile_name"] == "Test Default"
    end
  end

  describe "compile_profile/4" do
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
        thresholds: %{
          "cpu_warning" => "70",
          "cpu_critical" => "90"
        }
      }

      config = SysmonCompiler.compile_profile(profile, "tenant_test", %{}, "profile")

      assert config["enabled"] == true
      assert config["sample_interval"] == "5s"
      assert config["collect_cpu"] == true
      assert config["collect_memory"] == true
      assert config["collect_disk"] == true
      assert config["collect_network"] == true
      assert config["collect_processes"] == true
      assert config["disk_paths"] == ["/", "/var", "/home"]
      assert config["thresholds"]["cpu_warning"] == "70"
      assert config["thresholds"]["cpu_critical"] == "90"
      assert config["profile_id"] == "test-uuid"
      assert config["profile_name"] == "Production Monitoring"
      assert config["config_source"] == "profile"
    end
  end
end
