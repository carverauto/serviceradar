defmodule ServiceRadar.TenantIsolationTest do
  @moduledoc """
  Tests for multi-tenant data isolation.

  Verifies that:
  - Users can only access resources in their own tenant
  - Tenant context is properly enforced on all queries
  - Cross-tenant access is prevented by policies

  NOTE: Some tests are pending investigation of Ash multitenancy
  with `global? true` configuration. See GitHub issue for details.
  """
  use ServiceRadarWebNG.DataCase, async: false

  # Pending: investigate multi-tenancy filtering with `global? true`.
  # The Inventory and Infrastructure resources use global? true which
  # may affect how tenant filtering works. These tests need to be
  # updated once the multitenancy behavior is clarified.
  @moduletag :pending_multitenancy_investigation

  alias ServiceRadar.Identity.User
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Infrastructure.Poller

  import ServiceRadarWebNG.MultiTenantFixtures

  describe "User tenant isolation" do
    setup do
      scenario = multi_tenant_scenario()
      {:ok, scenario}
    end

    test "users can only see users in their own tenant", %{tenant_a: a, tenant_b: b} do
      actor_a = actor_for_user(a.user)
      actor_b = actor_for_user(b.user)

      # User A should see users in Tenant A
      {:ok, users_a} = Ash.read(User, actor: actor_a, tenant: a.tenant.id)
      user_ids_a = Enum.map(users_a, & &1.id)
      assert a.user.id in user_ids_a
      assert a.admin.id in user_ids_a

      # User A should NOT see users in Tenant B
      refute b.user.id in user_ids_a
      refute b.admin.id in user_ids_a

      # User B should see users in Tenant B
      {:ok, users_b} = Ash.read(User, actor: actor_b, tenant: b.tenant.id)
      user_ids_b = Enum.map(users_b, & &1.id)
      assert b.user.id in user_ids_b
      assert b.admin.id in user_ids_b

      # User B should NOT see users in Tenant A
      refute a.user.id in user_ids_b
      refute a.admin.id in user_ids_b
    end

    test "tenant filter is applied even without authorization", %{tenant_a: a, tenant_b: b} do
      # Query with tenant context and system actor but skipped authorization
      # This tests that tenant filtering happens even when not authorizing
      system = %{id: "00000000-0000-0000-0000-000000000000", role: :super_admin}
      {:ok, users_a} = Ash.read(User, actor: system, tenant: a.tenant.id, authorize?: false)
      user_ids = Enum.map(users_a, & &1.id)

      # Should only see Tenant A users
      assert a.user.id in user_ids
      refute b.user.id in user_ids
    end
  end

  describe "Device tenant isolation" do
    setup do
      scenario = multi_tenant_scenario()
      {:ok, scenario}
    end

    test "users can only see devices in their own tenant", %{tenant_a: a, tenant_b: b} do
      actor_a = actor_for_user(a.user)

      # User A should see devices in Tenant A
      {:ok, devices} = Ash.read(Device, actor: actor_a, tenant: a.tenant.id)
      device_ids = Enum.map(devices, & &1.id)

      assert a.device.id in device_ids
      refute b.device.id in device_ids
    end

    test "querying with wrong tenant returns empty", %{tenant_a: a, tenant_b: b} do
      actor_a = actor_for_user(a.user)

      # User A querying with Tenant B context should see nothing
      # (The tenant context filters, even if actor is from different tenant)
      {:ok, devices} = Ash.read(Device, actor: actor_a, tenant: b.tenant.id)
      assert devices == []
    end
  end

  describe "Poller tenant isolation" do
    setup do
      scenario = multi_tenant_scenario()
      {:ok, scenario}
    end

    test "users can only see pollers in their own tenant", %{tenant_a: a, tenant_b: b} do
      actor_a = actor_for_user(a.user)

      # User A should see pollers in Tenant A
      {:ok, pollers} = Ash.read(Poller, actor: actor_a, tenant: a.tenant.id)
      poller_ids = Enum.map(pollers, & &1.id)

      assert a.poller.id in poller_ids
      refute b.poller.id in poller_ids
    end
  end

  describe "Cross-tenant access prevention" do
    setup do
      scenario = multi_tenant_scenario()
      {:ok, scenario}
    end

    test "cannot get device from another tenant by ID", %{tenant_a: a, tenant_b: b} do
      actor_a = actor_for_user(a.user)

      # Try to get Tenant B's device using Tenant A's context
      result = Ash.get(Device, b.device.id, actor: actor_a, tenant: a.tenant.id)

      # Should return not found (tenant filter prevents access)
      # The error may be wrapped in Ash.Error.Invalid
      assert {:error, error} = result
      assert match?(%Ash.Error.Invalid{}, error) or match?(%Ash.Error.Query.NotFound{}, error)
    end

    test "cannot get user from another tenant by ID", %{tenant_a: a, tenant_b: b} do
      actor_a = actor_for_user(a.user)

      # Try to get Tenant B's user using Tenant A's context
      result = Ash.get(User, b.user.id, actor: actor_a, tenant: a.tenant.id)

      # Should return not found (tenant filter prevents access)
      # The error may be wrapped in Ash.Error.Invalid
      assert {:error, error} = result
      assert match?(%Ash.Error.Invalid{}, error) or match?(%Ash.Error.Query.NotFound{}, error)
    end
  end

  describe "Tenant creation and user assignment" do
    test "new tenant can be created with users" do
      tenant = tenant_fixture(%{name: "New Tenant", slug: "new-tenant"})
      assert tenant.id
      assert tenant.name == "New Tenant"
      assert tenant.status == :active

      user = tenant_user_fixture(tenant, %{email: "new@example.com"})
      assert user.id
      assert user.tenant_id == tenant.id
    end

    test "user roles are tenant-scoped" do
      tenant = tenant_fixture()
      admin = tenant_admin_fixture(tenant)

      assert admin.role == :admin
      assert admin.tenant_id == tenant.id

      # Admin in this tenant shouldn't affect other tenants
      other_tenant = tenant_fixture()
      other_user = tenant_user_fixture(other_tenant)

      # Other user is not admin
      assert other_user.role == nil || other_user.role == :viewer
    end
  end
end
