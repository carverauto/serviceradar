defmodule ServiceRadar.SysmonProfiles.SysmonProfileSeederTest do
  @moduledoc """
  Tests for the SysmonProfileSeeder module.

  Unit tests verify module structure.
  Integration tests (tagged :database) verify actual profile seeding.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.SysmonProfiles.{SysmonProfile, SysmonProfileSeeder}

  require Ash.Query

  describe "module structure" do
    test "module is loaded and defined" do
      assert Code.ensure_loaded?(SysmonProfileSeeder)
    end

    test "defines seed_for_tenant function" do
      functions = SysmonProfileSeeder.__info__(:functions)
      assert {:seed_for_tenant, 1} in functions
    end
  end

  describe "seed_for_tenant/1" do
    @tag :integration
    setup do
      tenant = ServiceRadar.TestSupport.create_tenant_schema!("sysmon-seeder")

      on_exit(fn ->
        ServiceRadar.TestSupport.drop_tenant_schema!(tenant.tenant_slug)
      end)

      {:ok, tenant_slug: tenant.tenant_slug}
    end

    @tag :integration
    test "creates default profile when none exists", %{tenant_slug: tenant_slug} do
      tenant = %{slug: tenant_slug}

      result = SysmonProfileSeeder.seed_for_tenant(tenant)

      assert result == :ok or match?({:ok, _}, result)

      # Verify the profile was created
      schema = TenantSchemas.schema_for_tenant(tenant)
      actor = SystemActor.system(:test)

      query =
        SysmonProfile
        |> Ash.Query.for_read(:get_default, %{}, actor: actor, tenant: schema)

      {:ok, profile} = Ash.read_one(query, actor: actor)

      assert profile != nil
      assert profile.name == "Default"
      assert profile.is_default == true
      assert profile.enabled == true
      assert profile.sample_interval == "10s"
      assert profile.collect_cpu == true
      assert profile.collect_memory == true
      assert profile.collect_disk == true
      assert profile.collect_network == false
      assert profile.collect_processes == false
    end

    @tag :integration
    test "does not create duplicate profile when called twice", %{tenant_slug: tenant_slug} do
      tenant = %{slug: tenant_slug}

      # Seed once
      SysmonProfileSeeder.seed_for_tenant(tenant)

      # Seed again
      result = SysmonProfileSeeder.seed_for_tenant(tenant)
      assert result == :ok

      # Verify only one default profile exists
      schema = TenantSchemas.schema_for_tenant(tenant)
      actor = SystemActor.system(:test)

      query =
        SysmonProfile
        |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: schema)
        |> Ash.Query.filter(is_default == true)

      {:ok, profiles} = Ash.read(query, actor: actor)

      assert length(profiles) == 1
    end

    @tag :integration
    test "default profile has correct thresholds", %{tenant_slug: tenant_slug} do
      tenant = %{slug: tenant_slug}

      SysmonProfileSeeder.seed_for_tenant(tenant)

      schema = TenantSchemas.schema_for_tenant(tenant)
      actor = SystemActor.system(:test)

      query =
        SysmonProfile
        |> Ash.Query.for_read(:get_default, %{}, actor: actor, tenant: schema)

      {:ok, profile} = Ash.read_one(query, actor: actor)

      assert profile.thresholds["cpu_warning"] == "80"
      assert profile.thresholds["cpu_critical"] == "95"
      assert profile.thresholds["memory_warning"] == "85"
      assert profile.thresholds["memory_critical"] == "95"
      assert profile.thresholds["disk_warning"] == "80"
      assert profile.thresholds["disk_critical"] == "95"
    end
  end
end
