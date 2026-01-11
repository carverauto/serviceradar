defmodule ServiceRadarWebNG.MultiTenantFixtures do
  @moduledoc """
  Test helpers for creating multi-tenant test data.

  Provides fixtures for tenants and tenant-scoped resources to test
  isolation and access control across tenant boundaries.
  """

  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Infrastructure.Gateway

  @doc """
  Returns a system actor that bypasses all authorization.
  Used for creating test fixtures.
  """
  def system_actor do
    %{
      id: "00000000-0000-0000-0000-000000000000",
      email: "system@serviceradar.test",
      role: :super_admin,
      tenant_id: nil
    }
  end

  @doc """
  Creates a tenant with unique name and slug.
  """
  def tenant_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Test Tenant #{unique}",
      slug: "test-tenant-#{unique}",
      contact_email: "contact-#{unique}@example.com",
      plan: :pro
    }

    attrs = Map.merge(defaults, attrs)

    Tenant
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor(), authorize?: false)
    |> Ash.create!()
  end

  @doc """
  Creates a user belonging to the given tenant.
  """
  def tenant_user_fixture(tenant, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      email: "user-#{unique}@example.com",
      display_name: "Test User #{unique}",
      tenant_id: tenant.id,
      password: "test_password_123!",
      password_confirmation: "test_password_123!"
    }

    attrs = Map.merge(defaults, attrs)

    User
    |> Ash.Changeset.for_create(:register_with_password, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant.id
    )
    |> Ash.create!()
  end

  @doc """
  Creates a user with admin role belonging to the given tenant.
  """
  def tenant_admin_fixture(tenant, attrs \\ %{}) do
    user = tenant_user_fixture(tenant, attrs)

    user
    |> Ash.Changeset.for_update(:update_role, %{role: :admin},
      actor: system_actor(),
      authorize?: false,
      tenant: tenant.id
    )
    |> Ash.update!()
  end

  @doc """
  Creates an actor map for the given user, suitable for Ash queries.
  """
  def actor_for_user(user) do
    %{
      id: user.id,
      email: user.email,
      tenant_id: user.tenant_id,
      role: user.role || :viewer
    }
  end

  @doc """
  Creates a device belonging to the given tenant.
  """
  def tenant_device_fixture(tenant, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      uid: "device-#{unique}",
      hostname: "host-#{unique}",
      type_id: 0,
      is_available: true,
      first_seen_time: DateTime.utc_now(),
      last_seen_time: DateTime.utc_now()
    }

    attrs = Map.merge(defaults, attrs)

    Device
    |> Ash.Changeset.for_create(:create, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant.id
    )
    |> Ash.create!()
  end

  @doc """
  Creates a gateway belonging to the given tenant.
  """
  def tenant_gateway_fixture(tenant, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      id: "gateway-#{unique}",
      component_id: "test-component-#{unique}",
      registration_source: "manual"
    }

    attrs = Map.merge(defaults, attrs)

    Gateway
    |> Ash.Changeset.for_create(:register, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant.id
    )
    |> Ash.create!()
  end

  @doc """
  Creates an agent belonging to the given tenant.
  """
  def tenant_agent_fixture(tenant, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      uid: "agent-#{unique}",
      name: "Test Agent #{unique}",
      type_id: 1,
      type: "sysmon"
    }

    attrs = Map.merge(defaults, attrs)

    ServiceRadar.Infrastructure.Agent
    |> Ash.Changeset.for_create(:register_connected, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant.id
    )
    |> Ash.create!()
  end

  @doc """
  Creates a service check belonging to the given tenant.
  """
  def tenant_service_check_fixture(tenant, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    # Note: `enabled` is not in the accept list for :create, defaults to true
    defaults = %{
      name: "Test Check #{unique}",
      check_type: :http,
      target: "https://example.com",
      interval_seconds: 60,
      timeout_seconds: 30
    }

    attrs = Map.merge(defaults, attrs) |> Map.drop([:enabled])

    ServiceRadar.Monitoring.ServiceCheck
    |> Ash.Changeset.for_create(:create, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant.id
    )
    |> Ash.create!()
  end

  @doc """
  Creates an alert belonging to the given tenant.
  """
  def tenant_alert_fixture(tenant, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      title: "Test Alert #{unique}",
      severity: :warning,
      description: "This is a test alert",
      source_type: :service_check,
      source_id: "check-#{unique}"
    }

    attrs = Map.merge(defaults, attrs)

    ServiceRadar.Monitoring.Alert
    |> Ash.Changeset.for_create(:trigger, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant.id
    )
    |> Ash.create!()
  end

  @doc """
  Creates a complete multi-tenant test scenario with two tenants,
  each having a user, admin, and some resources.

  Returns a map with all the created resources:

      %{
        tenant_a: %{tenant: ..., user: ..., admin: ..., device: ..., gateway: ...},
        tenant_b: %{tenant: ..., user: ..., admin: ..., device: ..., gateway: ...}
      }
  """
  def multi_tenant_scenario do
    tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a"})
    tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b"})

    %{
      tenant_a: %{
        tenant: tenant_a,
        user: tenant_user_fixture(tenant_a),
        admin: tenant_admin_fixture(tenant_a),
        device: tenant_device_fixture(tenant_a),
        gateway: tenant_gateway_fixture(tenant_a)
      },
      tenant_b: %{
        tenant: tenant_b,
        user: tenant_user_fixture(tenant_b),
        admin: tenant_admin_fixture(tenant_b),
        device: tenant_device_fixture(tenant_b),
        gateway: tenant_gateway_fixture(tenant_b)
      }
    }
  end
end
