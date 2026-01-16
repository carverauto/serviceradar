defmodule ServiceRadarWebNG.AshTestHelpers do
  @moduledoc """
  Comprehensive test helpers for Ash resources.

  Provides fixtures, actors, and policy testing utilities for all
  ServiceRadar Ash domains: Identity, Inventory, Infrastructure,
  Monitoring, and Edge.

  ## Usage

      use ServiceRadarWebNG.AshTestHelpers

      test "creates a device" do
        tenant = tenant_fixture()
        device = device_fixture(tenant)
        assert device.id
      end

  ## Actors

  The module provides several actor types for testing authorization:

  - `system_actor/0` - Bypasses all authorization (super_admin)
  - `admin_actor/0` - Admin role
  - `operator_actor/0` - Operator role
  - `viewer_actor/0` - Viewer role (read-only)
  """

  alias ServiceRadar.Identity.{Tenant, User, ApiToken}
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Infrastructure.{Gateway, Agent, Checker, Partition}
  alias ServiceRadar.Monitoring.{Alert, ServiceCheck, PollingSchedule}
  alias ServiceRadar.Edge.OnboardingPackage

  @doc """
  Import all Ash test helpers into the using module.
  """
  defmacro __using__(_opts) do
    quote do
      import ServiceRadarWebNG.AshTestHelpers
    end
  end

  # ============================================================================
  # System Actor
  # ============================================================================

  @doc """
  Returns a system actor that bypasses all authorization.
  Used for creating test fixtures without policy restrictions.

  In a tenant instance, tenant isolation is handled by PostgreSQL search_path,
  not by actor.
  """
  def system_actor do
    %{
      id: "00000000-0000-0000-0000-000000000000",
      email: "system@serviceradar.test",
      role: :super_admin
    }
  end

  # ============================================================================
  # Role-Based Actors
  # ============================================================================

  @doc """
  Creates an admin actor.

  In a tenant instance, tenant isolation is handled by PostgreSQL search_path.
  The actor only needs id, email, and role.
  """
  def admin_actor(_tenant \\ nil) do
    %{
      id: Ecto.UUID.generate(),
      email: "admin-#{System.unique_integer([:positive])}@test.local",
      role: :admin
    }
  end

  @doc """
  Creates an operator actor.

  In a tenant instance, tenant isolation is handled by PostgreSQL search_path.
  """
  def operator_actor(_tenant \\ nil) do
    %{
      id: Ecto.UUID.generate(),
      email: "operator-#{System.unique_integer([:positive])}@test.local",
      role: :operator
    }
  end

  @doc """
  Creates a viewer actor.

  In a tenant instance, tenant isolation is handled by PostgreSQL search_path.
  """
  def viewer_actor(_tenant \\ nil) do
    %{
      id: Ecto.UUID.generate(),
      email: "viewer-#{System.unique_integer([:positive])}@test.local",
      role: :viewer
    }
  end

  @doc """
  Creates an actor map from a User struct.

  In a tenant instance, tenant isolation is handled by PostgreSQL search_path.
  """
  def actor_for_user(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      role: user.role || :viewer
    }
  end

  # ============================================================================
  # Identity Domain Fixtures
  # ============================================================================

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

    attrs = Map.merge(defaults, Map.new(attrs))

    Tenant
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  @doc """
  Creates a user belonging to the given tenant.
  """
  def user_fixture(tenant, attrs \\ %{})

  def user_fixture(%Tenant{} = tenant, attrs) do
    user_fixture(tenant.id, attrs)
  end

  def user_fixture(_id, attrs) when is_binary(_id) do
    unique = System.unique_integer([:positive])

    # In tenant-instance model, users are created in the schema determined by DB connection
    defaults = %{
      email: "user-#{unique}@example.com",
      display_name: "Test User #{unique}",
      password: "test_password_123!",
      password_confirmation: "test_password_123!"
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    User
    |> Ash.Changeset.for_create(:register_with_password, attrs, actor: system_actor())
    |> Ash.create!()
  end

  @doc """
  Creates a user with admin role belonging to the given tenant.
  """
  def admin_user_fixture(tenant, attrs \\ %{}) do
    user = user_fixture(tenant, attrs)

    user
    |> Ash.Changeset.for_update(:update_role, %{role: :admin}, actor: system_actor())
    |> Ash.update!()
  end

  @doc """
  Creates a user with operator role belonging to the given tenant.
  """
  def operator_user_fixture(tenant, attrs \\ %{}) do
    user = user_fixture(tenant, attrs)

    user
    |> Ash.Changeset.for_update(:update_role, %{role: :operator}, actor: system_actor())
    |> Ash.update!()
  end

  @doc """
  Creates an API token for the given user.
  """
  def api_token_fixture(user, attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    raw_token = "srk_" <> Base.encode64(:crypto.strong_rand_bytes(32))

    defaults = %{
      name: "Test Token #{unique}",
      scope: :full_access,
      user_id: user.id,
      token: raw_token
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    ApiToken
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  # ============================================================================
  # Inventory Domain Fixtures
  # ============================================================================

  @doc """
  Creates a device belonging to the given tenant.
  """
  def device_fixture(tenant, attrs \\ %{})

  def device_fixture(%Tenant{} = tenant, attrs) do
    device_fixture(tenant.id, attrs)
  end

  def device_fixture(_id, attrs) when is_binary(_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      uid: "device-#{unique}",
      hostname: "host-#{unique}.local",
      type_id: 0,
      is_available: true,
      first_seen_time: DateTime.utc_now(),
      last_seen_time: DateTime.utc_now()
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Device
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  # ============================================================================
  # Infrastructure Domain Fixtures
  # ============================================================================

  @doc """
  Creates a partition belonging to the given tenant.
  """
  def partition_fixture(tenant, attrs \\ %{})

  def partition_fixture(%Tenant{} = tenant, attrs) do
    partition_fixture(tenant.id, attrs)
  end

  def partition_fixture(_id, attrs) when is_binary(_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Partition #{unique}",
      slug: "partition-#{unique}",
      description: "Test partition #{unique}",
      cidr_ranges: ["10.#{rem(unique, 256)}.0.0/16"]
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Partition
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  @doc """
  Creates a gateway belonging to the given tenant.
  """
  def gateway_fixture(tenant, attrs \\ %{})

  def gateway_fixture(%Tenant{} = tenant, attrs) do
    gateway_fixture(tenant.id, attrs)
  end

  def gateway_fixture(_id, attrs) when is_binary(_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      id: "gateway-#{unique}",
      component_id: "component-#{unique}",
      registration_source: "manual"
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Gateway
    |> Ash.Changeset.for_create(:register, attrs, actor: system_actor())
    |> Ash.create!()
  end

  @doc """
  Creates an agent belonging to the given gateway.
  """
  def agent_fixture(gateway, attrs \\ %{})

  def agent_fixture(%Gateway{} = gateway, attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      uid: "agent-#{unique}",
      name: "Test Agent #{unique}",
      type_id: 0,
      gateway_id: gateway.id
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    # In a tenant instance, DB connection's search_path determines the schema
    Agent
    |> Ash.Changeset.for_create(:register, attrs, actor: system_actor())
    |> Ash.create!()
  end

  @doc """
  Creates a checker belonging to the given agent.
  """
  def checker_fixture(agent, attrs \\ %{})

  def checker_fixture(%Agent{} = agent, attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Checker #{unique}",
      type: "grpc",
      config: %{},
      agent_uid: agent.uid
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    # In a tenant instance, DB connection's search_path determines the schema
    Checker
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  # ============================================================================
  # Monitoring Domain Fixtures
  # ============================================================================

  @doc """
  Creates a service check belonging to the given tenant.
  """
  def service_check_fixture(tenant, attrs \\ %{})

  def service_check_fixture(%Tenant{} = tenant, attrs) do
    service_check_fixture(tenant.id, attrs)
  end

  def service_check_fixture(_id, attrs) when is_binary(_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Service Check #{unique}",
      check_type: :http,
      target: "https://example.com/health",
      interval_seconds: 60
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    ServiceCheck
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  @doc """
  Creates an alert belonging to the given tenant.
  """
  def alert_fixture(tenant, attrs \\ %{})

  def alert_fixture(%Tenant{} = tenant, attrs) do
    alert_fixture(tenant.id, attrs)
  end

  def alert_fixture(_id, attrs) when is_binary(_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      title: "Test Alert #{unique}",
      severity: :warning,
      source_type: :device,
      description: "This is a test alert #{unique}"
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Alert
    |> Ash.Changeset.for_create(:trigger, attrs, actor: system_actor())
    |> Ash.create!()
  end

  @doc """
  Creates a polling schedule belonging to the given tenant.
  """
  def polling_schedule_fixture(tenant, attrs \\ %{})

  def polling_schedule_fixture(%Tenant{} = tenant, attrs) do
    polling_schedule_fixture(tenant.id, attrs)
  end

  def polling_schedule_fixture(_id, attrs) when is_binary(_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Polling Schedule #{unique}",
      schedule_type: :interval,
      interval_seconds: 60
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    PollingSchedule
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  # ============================================================================
  # Edge Domain Fixtures
  # ============================================================================

  @doc """
  Creates an onboarding package belonging to the given tenant.
  """
  def onboarding_package_fixture(tenant, attrs \\ %{})

  def onboarding_package_fixture(%Tenant{} = tenant, attrs) do
    onboarding_package_fixture(tenant.id, attrs)
  end

  def onboarding_package_fixture(_id, attrs) when is_binary(_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      label: "Onboarding Package #{unique}",
      component_id: "component-#{unique}",
      component_type: :gateway,
      gateway_id: "gateway-#{unique}",
      site: "site-#{unique}",
      security_mode: :spire
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    OnboardingPackage
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  # ============================================================================
  # Multi-Tenant Scenarios
  # ============================================================================

  @doc """
  Creates a complete test scenario with a tenant and resources.

  Returns a map with all the created resources:

      %{
        tenant: ...,
        admin: ...,
        operator: ...,
        viewer: ...,
        device: ...,
        gateway: ...,
        agent: ...
      }
  """
  def tenant_scenario do
    tenant = tenant_fixture(%{name: "Test Tenant", slug: "test-tenant-scenario"})
    build_tenant_resources(tenant)
  end

  defp build_tenant_resources(tenant) do
    gateway = gateway_fixture(tenant)

    %{
      tenant: tenant,
      admin: admin_user_fixture(tenant),
      operator: operator_user_fixture(tenant),
      viewer: user_fixture(tenant),
      device: device_fixture(tenant),
      gateway: gateway,
      agent: agent_fixture(gateway)
    }
  end

  @doc """
  Creates a full infrastructure hierarchy for testing.

  Returns:
      %{
        tenant: ...,
        partition: ...,
        gateway: ...,
        agents: [...],
        checkers: [...],
        devices: [...]
      }
  """
  def infrastructure_scenario(opts \\ []) do
    agent_count = Keyword.get(opts, :agents, 2)
    device_count = Keyword.get(opts, :devices, 3)

    tenant = tenant_fixture()
    partition = partition_fixture(tenant)
    gateway = gateway_fixture(tenant, %{partition_id: partition.id})

    agents =
      for _ <- 1..agent_count do
        agent_fixture(gateway)
      end

    checkers =
      Enum.flat_map(agents, fn agent ->
        [
          checker_fixture(agent, %{type: "grpc"}),
          checker_fixture(agent, %{type: "snmp"})
        ]
      end)

    devices =
      for _ <- 1..device_count do
        device_fixture(tenant)
      end

    %{
      tenant: tenant,
      partition: partition,
      gateway: gateway,
      agents: agents,
      checkers: checkers,
      devices: devices
    }
  end
end
