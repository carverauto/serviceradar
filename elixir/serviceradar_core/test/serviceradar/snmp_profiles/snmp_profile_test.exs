defmodule ServiceRadar.SNMPProfiles.SNMPProfileTest do
  @moduledoc """
  Tests for the SNMPProfile resource.

  Tests resource creation, validation, and policy enforcement.
  """

  use ExUnit.Case, async: false

  alias ResourceInfo, as: ResourceInfo
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query

  describe "module structure" do
    test "module is loaded and defined" do
      assert Code.ensure_loaded?(SNMPProfile)
    end

    test "is an Ash resource" do
      assert function_exported?(SNMPProfile, :spark_dsl_config, 0)
    end
  end

  describe "default values" do
    test "poll_interval defaults to 60" do
      # Get attribute default from resource
      attrs = ResourceInfo.attributes(SNMPProfile)
      poll_interval = Enum.find(attrs, &(&1.name == :poll_interval))
      assert poll_interval.default == 60
    end

    test "timeout defaults to 5" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      timeout = Enum.find(attrs, &(&1.name == :timeout))
      assert timeout.default == 5
    end

    test "retries defaults to 3" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      retries = Enum.find(attrs, &(&1.name == :retries))
      assert retries.default == 3
    end

    test "is_default defaults to false" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      is_default = Enum.find(attrs, &(&1.name == :is_default))
      assert is_default.default == false
    end

    test "enabled defaults to true" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      enabled = Enum.find(attrs, &(&1.name == :enabled))
      assert enabled.default == true
    end

    test "priority defaults to 0" do
      attrs = ResourceInfo.attributes(SNMPProfile)
      priority = Enum.find(attrs, &(&1.name == :priority))
      assert priority.default == 0
    end
  end

  describe "actions" do
    test "has create action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :create))
    end

    test "has update action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :update))
    end

    test "has read action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :read))
    end

    test "has set_as_default action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :set_as_default))
    end

    test "has get_default action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :get_default))
    end

    test "has list_targeting_profiles action" do
      actions = ResourceInfo.actions(SNMPProfile)
      assert Enum.any?(actions, &(&1.name == :list_targeting_profiles))
    end
  end

  describe "CRUD operations" do
    @tag :integration
    setup do
      tenant = ServiceRadar.TestSupport.create_tenant_schema!("snmp-profile")

      on_exit(fn ->
        ServiceRadar.TestSupport.drop_tenant_schema!(tenant.tenant_slug)
      end)

      {:ok, tenant_slug: tenant.tenant_slug}
    end

    @tag :integration
    test "creates a profile with required fields", %{
      tenant_slug: tenant_slug
    } do
      schema = TenantSchemas.schema_for_tenant(%{slug: tenant_slug})
      actor = SystemActor.system(:test)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Test Profile"},
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert profile.name == "Test Profile"
      assert profile.poll_interval == 60
      assert profile.timeout == 5
      assert profile.retries == 3
      assert profile.is_default == false
      assert profile.enabled == true
      assert profile.priority == 0
    end

    @tag :integration
    test "creates a profile with all fields", %{
      tenant_slug: tenant_slug
    } do
      schema = TenantSchemas.schema_for_tenant(%{slug: tenant_slug})
      actor = SystemActor.system(:test)

      {:ok, profile} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Custom Profile",
            description: "A custom monitoring profile",
            poll_interval: 30,
            timeout: 10,
            retries: 5,
            is_default: false,
            enabled: true,
            target_query: "in:devices tags.role:network",
            priority: 50
          },
          actor: actor
        )
        |> Ash.create(actor: actor)

      assert profile.name == "Custom Profile"
      assert profile.description == "A custom monitoring profile"
      assert profile.poll_interval == 30
      assert profile.timeout == 10
      assert profile.retries == 5
      assert profile.target_query == "in:devices tags.role:network"
      assert profile.priority == 50
    end

    @tag :integration
    test "enforces unique name per tenant", %{
      tenant_slug: tenant_slug
    } do
      schema = TenantSchemas.schema_for_tenant(%{slug: tenant_slug})
      actor = SystemActor.system(:test)

      {:ok, _profile1} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Duplicate Name"},
          actor: actor
        )
        |> Ash.create(actor: actor)

      {:error, _error} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Duplicate Name"},
          actor: actor
        )
        |> Ash.create(actor: actor)
    end

    @tag :integration
    test "set_as_default clears other defaults", %{
      tenant_slug: tenant_slug
    } do
      schema = TenantSchemas.schema_for_tenant(%{slug: tenant_slug})
      actor = SystemActor.system(:test)

      # Create first profile as default
      {:ok, profile1} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Profile 1", is_default: true},
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Create second profile
      {:ok, profile2} =
        SNMPProfile
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Profile 2"},
          actor: actor
        )
        |> Ash.create(actor: actor)

      # Set profile2 as default
      {:ok, updated_profile2} =
        profile2
        |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
        |> Ash.update(actor: actor)

      assert updated_profile2.is_default == true

      # Reload profile1 and check it's no longer default
      {:ok, reloaded_profile1} = Ash.get(SNMPProfile, profile1.id, actor: actor)
      assert reloaded_profile1.is_default == false
    end
  end
end
