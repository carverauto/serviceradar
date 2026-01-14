defmodule ServiceRadar.SysmonProfiles.SysmonProfileAssignmentTest do
  @moduledoc """
  E2E tests for sysmon profile assignment and resolution.

  Tests the flow: Create profile → assign to tag → verify agent receives config
  This covers task 5.1 from the sysmon-consolidation spec.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SysmonProfiles.{SysmonProfile, SysmonProfileAssignment}

  @moduletag :integration

  setup_all do
    tenant = ServiceRadar.TestSupport.create_tenant_schema!("sysmon-e2e")

    on_exit(fn ->
      ServiceRadar.TestSupport.drop_tenant_schema!(tenant.tenant_slug)
    end)

    {:ok, tenant_id: tenant.tenant_id, tenant_slug: tenant.tenant_slug}
  end

  setup %{tenant_id: tenant_id, tenant_slug: tenant_slug} do
    unique_id = :erlang.unique_integer([:positive])
    schema = TenantSchemas.schema_for_tenant(%{slug: tenant_slug})
    actor = SystemActor.for_tenant(tenant_id, :test)

    {:ok,
     tenant_id: tenant_id,
     tenant_slug: tenant_slug,
     schema: schema,
     actor: actor,
     unique_id: unique_id}
  end

  describe "E2E: profile -> tag -> agent receives config (5.1)" do
    test "device with matching tag receives tag-assigned profile", %{
      tenant_id: tenant_id,
      schema: schema,
      actor: actor,
      unique_id: unique_id
    } do
      # Step 1: Create a custom sysmon profile
      {:ok, profile} =
        SysmonProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Production Profile #{unique_id}",
            sample_interval: "5s",
            collect_cpu: true,
            collect_memory: true,
            collect_disk: true,
            collect_network: true,
            collect_processes: true,
            disk_paths: ["/", "/var", "/home"],
            thresholds: %{"cpu_warning" => "75", "cpu_critical" => "90"},
            enabled: true
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Step 2: Create a device with a specific tag
      device_uid = "device-#{unique_id}"

      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            name: "Production Server #{unique_id}",
            hostname: "prod-server-#{unique_id}",
            type_id: 1,
            type: "Server",
            is_available: true,
            tags: %{"environment" => "production", "tier" => "frontend"}
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Step 3: Create a tag assignment linking the profile to the tag
      {:ok, _assignment} =
        SysmonProfileAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{
            profile_id: profile.id,
            assignment_type: :tag,
            tag_key: "environment",
            tag_value: "production",
            priority: 100
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Step 4: Create an agent linked to this device
      agent_uid = "agent-#{unique_id}"

      {:ok, _agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: agent_uid,
            name: "Test Agent #{unique_id}",
            type_id: 4,
            capabilities: ["sysmon", "icmp"],
            device_uid: device.uid,
            tenant_id: tenant_id
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Step 5: Verify the sysmon compiler resolves to the correct profile
      {:ok, config} =
        SysmonCompiler.compile(tenant_id, "default", agent_uid, device_uid: device.uid)

      assert config["enabled"] == true
      assert config["sample_interval"] == "5s"
      assert config["collect_network"] == true
      assert config["collect_processes"] == true
      assert config["disk_paths"] == ["/", "/var", "/home"]
      assert config["thresholds"]["cpu_warning"] == "75"
      assert config["profile_id"] == profile.id
      assert config["profile_name"] == "Production Profile #{unique_id}"
    end

    test "device-specific assignment takes precedence over tag", %{
      tenant_id: tenant_id,
      schema: schema,
      actor: actor,
      unique_id: unique_id
    } do
      # Create tag-based profile
      {:ok, tag_profile} =
        SysmonProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Tag Profile #{unique_id}",
            sample_interval: "30s",
            collect_network: false,
            enabled: true
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Create device-specific profile
      {:ok, device_profile} =
        SysmonProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Device Profile #{unique_id}",
            sample_interval: "1s",
            collect_network: true,
            enabled: true
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Create device with tag
      device_uid = "priority-device-#{unique_id}"

      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            name: "Priority Test Device",
            type_id: 1,
            tags: %{"role" => "database"}
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Create tag assignment
      {:ok, _tag_assignment} =
        SysmonProfileAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{
            profile_id: tag_profile.id,
            assignment_type: :tag,
            tag_key: "role",
            tag_value: "database",
            priority: 100
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Create device-specific assignment (should take precedence)
      {:ok, _device_assignment} =
        SysmonProfileAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{
            profile_id: device_profile.id,
            assignment_type: :device,
            device_uid: device.uid,
            priority: 50
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Verify device-specific profile wins
      {:ok, config} = SysmonCompiler.compile(tenant_id, "default", nil, device_uid: device.uid)

      assert config["sample_interval"] == "1s"
      assert config["collect_network"] == true
      assert config["profile_id"] == device_profile.id
      assert config["profile_name"] == "Device Profile #{unique_id}"
    end

    test "higher priority tag assignment wins over lower", %{
      tenant_id: tenant_id,
      schema: schema,
      actor: actor,
      unique_id: unique_id
    } do
      # Create low priority profile
      {:ok, low_profile} =
        SysmonProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Low Priority Profile #{unique_id}",
            sample_interval: "60s",
            enabled: true
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Create high priority profile
      {:ok, high_profile} =
        SysmonProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "High Priority Profile #{unique_id}",
            sample_interval: "2s",
            enabled: true
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Create device with multiple matching tags
      device_uid = "multi-tag-device-#{unique_id}"

      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            name: "Multi-tag Device",
            type_id: 1,
            tags: %{"env" => "prod", "critical" => "yes"}
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Low priority tag assignment
      {:ok, _low_assignment} =
        SysmonProfileAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{
            profile_id: low_profile.id,
            assignment_type: :tag,
            tag_key: "env",
            tag_value: "prod",
            priority: 10
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # High priority tag assignment
      {:ok, _high_assignment} =
        SysmonProfileAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{
            profile_id: high_profile.id,
            assignment_type: :tag,
            tag_key: "critical",
            tag_value: "yes",
            priority: 100
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Verify high priority profile wins
      {:ok, config} = SysmonCompiler.compile(tenant_id, "default", nil, device_uid: device.uid)

      assert config["sample_interval"] == "2s"
      assert config["profile_id"] == high_profile.id
    end

    test "device without matching tags falls back to default profile", %{
      tenant_id: tenant_id,
      schema: schema,
      actor: actor,
      unique_id: unique_id
    } do
      # Create default profile
      {:ok, default_profile} =
        SysmonProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Tenant Default #{unique_id}",
            sample_interval: "15s",
            is_default: true,
            enabled: true
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Create a tag profile (won't match)
      {:ok, tag_profile} =
        SysmonProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Unmatched Profile #{unique_id}",
            sample_interval: "3s",
            enabled: true
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Create tag assignment for a different tag
      {:ok, _assignment} =
        SysmonProfileAssignment
        |> Ash.Changeset.for_create(
          :create,
          %{
            profile_id: tag_profile.id,
            assignment_type: :tag,
            tag_key: "region",
            tag_value: "us-west",
            priority: 100
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Create device WITHOUT the matching tag
      device_uid = "untagged-device-#{unique_id}"

      {:ok, device} =
        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: device_uid,
            name: "Untagged Device",
            type_id: 1,
            tags: %{"team" => "platform"}
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Verify fallback to default profile
      {:ok, config} = SysmonCompiler.compile(tenant_id, "default", nil, device_uid: device.uid)

      assert config["sample_interval"] == "15s"
      assert config["profile_id"] == default_profile.id
      assert config["profile_name"] == "Tenant Default #{unique_id}"
    end
  end

  describe "AgentConfigGenerator sysmon integration" do
    test "generate_config includes sysmon_config from resolved profile", %{
      tenant_id: tenant_id,
      schema: schema,
      actor: actor,
      unique_id: unique_id
    } do
      # Create a custom profile
      {:ok, profile} =
        SysmonProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Generator Test Profile #{unique_id}",
            sample_interval: "7s",
            collect_cpu: true,
            collect_memory: true,
            collect_disk: false,
            collect_network: true,
            is_default: true,
            enabled: true
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      agent_uid = "generator-test-agent-#{unique_id}"

      # Create agent
      {:ok, _agent} =
        Agent
        |> Ash.Changeset.for_create(
          :register_connected,
          %{
            uid: agent_uid,
            name: "Generator Test Agent",
            type_id: 4,
            capabilities: ["sysmon"],
            tenant_id: tenant_id
          },
          actor: actor,
          tenant: schema
        )
        |> Ash.create(actor: actor)

      # Generate full config
      {:ok, config} = AgentConfigGenerator.generate_config(agent_uid, tenant_id)

      # Verify sysmon_config is included
      assert config.sysmon_config != nil
      assert config.sysmon_config.enabled == true
      assert config.sysmon_config.sample_interval == "7s"
      assert config.sysmon_config.collect_disk == false
      assert config.sysmon_config.collect_network == true
      assert config.sysmon_config.profile_id == profile.id
    end
  end
end
