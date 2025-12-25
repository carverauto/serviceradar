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
  - `admin_actor/1` - Admin role for a tenant
  - `operator_actor/1` - Operator role for a tenant
  - `viewer_actor/1` - Viewer role (read-only) for a tenant
  """

  alias ServiceRadar.Identity.{Tenant, User, ApiToken}
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Infrastructure.{Poller, Agent, Checker, Partition}
  alias ServiceRadar.Monitoring.{Alert, Event, ServiceCheck}
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
  """
  def system_actor do
    %{
      id: "00000000-0000-0000-0000-000000000000",
      email: "system@serviceradar.test",
      role: :super_admin,
      tenant_id: nil
    }
  end

  # ============================================================================
  # Role-Based Actors
  # ============================================================================

  @doc """
  Creates an admin actor for the given tenant.
  """
  def admin_actor(tenant) when is_struct(tenant, Tenant) do
    admin_actor(tenant.id)
  end

  def admin_actor(tenant_id) when is_binary(tenant_id) do
    %{
      id: Ecto.UUID.generate(),
      email: "admin-#{System.unique_integer([:positive])}@test.local",
      role: :admin,
      tenant_id: tenant_id
    }
  end

  @doc """
  Creates an operator actor for the given tenant.
  """
  def operator_actor(tenant) when is_struct(tenant, Tenant) do
    operator_actor(tenant.id)
  end

  def operator_actor(tenant_id) when is_binary(tenant_id) do
    %{
      id: Ecto.UUID.generate(),
      email: "operator-#{System.unique_integer([:positive])}@test.local",
      role: :operator,
      tenant_id: tenant_id
    }
  end

  @doc """
  Creates a viewer actor for the given tenant.
  """
  def viewer_actor(tenant) when is_struct(tenant, Tenant) do
    viewer_actor(tenant.id)
  end

  def viewer_actor(tenant_id) when is_binary(tenant_id) do
    %{
      id: Ecto.UUID.generate(),
      email: "viewer-#{System.unique_integer([:positive])}@test.local",
      role: :viewer,
      tenant_id: tenant_id
    }
  end

  @doc """
  Creates an actor map from a User struct.
  """
  def actor_for_user(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      role: user.role || :viewer,
      tenant_id: user.tenant_id
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
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor(), authorize?: false)
    |> Ash.create!()
  end

  @doc """
  Creates a user belonging to the given tenant.
  """
  def user_fixture(tenant, attrs \\ %{})

  def user_fixture(%Tenant{} = tenant, attrs) do
    user_fixture(tenant.id, attrs)
  end

  def user_fixture(tenant_id, attrs) when is_binary(tenant_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      email: "user-#{unique}@example.com",
      display_name: "Test User #{unique}",
      tenant_id: tenant_id,
      password: "test_password_123!",
      password_confirmation: "test_password_123!"
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    User
    |> Ash.Changeset.for_create(:register_with_password, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant_id
    )
    |> Ash.create!()
  end

  @doc """
  Creates a user with admin role belonging to the given tenant.
  """
  def admin_user_fixture(tenant, attrs \\ %{}) do
    user = user_fixture(tenant, attrs)

    user
    |> Ash.Changeset.for_update(:update_role, %{role: :admin},
      actor: system_actor(),
      authorize?: false,
      tenant: tenant.id
    )
    |> Ash.update!()
  end

  @doc """
  Creates a user with operator role belonging to the given tenant.
  """
  def operator_user_fixture(tenant, attrs \\ %{}) do
    user = user_fixture(tenant, attrs)

    user
    |> Ash.Changeset.for_update(:update_role, %{role: :operator},
      actor: system_actor(),
      authorize?: false,
      tenant: tenant.id
    )
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
    |> Ash.Changeset.for_create(:create, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: user.tenant_id
    )
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

  def device_fixture(tenant_id, attrs) when is_binary(tenant_id) do
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
    |> Ash.Changeset.for_create(:create, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant_id
    )
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

  def partition_fixture(tenant_id, attrs) when is_binary(tenant_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Partition #{unique}",
      slug: "partition-#{unique}",
      description: "Test partition #{unique}",
      cidr_ranges: ["10.#{rem(unique, 256)}.0.0/16"]
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Partition
    |> Ash.Changeset.for_create(:create, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant_id
    )
    |> Ash.create!()
  end

  @doc """
  Creates a poller belonging to the given tenant.
  """
  def poller_fixture(tenant, attrs \\ %{})

  def poller_fixture(%Tenant{} = tenant, attrs) do
    poller_fixture(tenant.id, attrs)
  end

  def poller_fixture(tenant_id, attrs) when is_binary(tenant_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      id: "poller-#{unique}",
      component_id: "component-#{unique}",
      registration_source: "manual"
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Poller
    |> Ash.Changeset.for_create(:register, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant_id
    )
    |> Ash.create!()
  end

  @doc """
  Creates an agent belonging to the given poller.
  """
  def agent_fixture(poller, attrs \\ %{})

  def agent_fixture(%Poller{} = poller, attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      uid: "agent-#{unique}",
      name: "Test Agent #{unique}",
      type_id: 0,
      poller_id: poller.id
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Agent
    |> Ash.Changeset.for_create(:register, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: poller.tenant_id
    )
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

    Checker
    |> Ash.Changeset.for_create(:create, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: agent.tenant_id
    )
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

  def service_check_fixture(tenant_id, attrs) when is_binary(tenant_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      name: "Service Check #{unique}",
      check_type: :http,
      target: "https://example.com/health",
      interval_seconds: 60
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    ServiceCheck
    |> Ash.Changeset.for_create(:create, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant_id
    )
    |> Ash.create!()
  end

  @doc """
  Creates an alert belonging to the given tenant.
  """
  def alert_fixture(tenant, attrs \\ %{})

  def alert_fixture(%Tenant{} = tenant, attrs) do
    alert_fixture(tenant.id, attrs)
  end

  def alert_fixture(tenant_id, attrs) when is_binary(tenant_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      title: "Test Alert #{unique}",
      severity: :warning,
      source_type: :device,
      description: "This is a test alert #{unique}"
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Alert
    |> Ash.Changeset.for_create(:trigger, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant_id
    )
    |> Ash.create!()
  end

  @doc """
  Creates an event belonging to the given tenant.
  """
  def event_fixture(tenant, attrs \\ %{})

  def event_fixture(%Tenant{} = tenant, attrs) do
    event_fixture(tenant.id, attrs)
  end

  def event_fixture(tenant_id, attrs) when is_binary(tenant_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      category: :system,
      event_type: "system.test.#{unique}",
      severity: 1,  # 1 = Info
      message: "Test event #{unique}",
      source_type: :system,
      source_id: "test",
      source_name: "Test System"
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    Event
    |> Ash.Changeset.for_create(:record, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant_id
    )
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

  def onboarding_package_fixture(tenant_id, attrs) when is_binary(tenant_id) do
    unique = System.unique_integer([:positive])

    defaults = %{
      label: "Onboarding Package #{unique}",
      component_id: "component-#{unique}",
      component_type: :poller,
      poller_id: "poller-#{unique}",
      site: "site-#{unique}",
      security_mode: :spire
    }

    attrs = Map.merge(defaults, Map.new(attrs))

    OnboardingPackage
    |> Ash.Changeset.for_create(:create, attrs,
      actor: system_actor(),
      authorize?: false,
      tenant: tenant_id
    )
    |> Ash.create!()
  end

  # ============================================================================
  # Multi-Tenant Scenarios
  # ============================================================================

  @doc """
  Creates a complete multi-tenant test scenario with two tenants,
  each having users with different roles and some resources.

  Returns a map with all the created resources:

      %{
        tenant_a: %{
          tenant: ...,
          admin: ...,
          operator: ...,
          viewer: ...,
          device: ...,
          poller: ...
        },
        tenant_b: %{...}
      }
  """
  def multi_tenant_scenario do
    tenant_a = tenant_fixture(%{name: "Tenant A", slug: "tenant-a"})
    tenant_b = tenant_fixture(%{name: "Tenant B", slug: "tenant-b"})

    %{
      tenant_a: build_tenant_resources(tenant_a),
      tenant_b: build_tenant_resources(tenant_b)
    }
  end

  defp build_tenant_resources(tenant) do
    poller = poller_fixture(tenant)

    %{
      tenant: tenant,
      admin: admin_user_fixture(tenant),
      operator: operator_user_fixture(tenant),
      viewer: user_fixture(tenant),
      device: device_fixture(tenant),
      poller: poller,
      agent: agent_fixture(poller)
    }
  end

  @doc """
  Creates a full infrastructure hierarchy for testing.

  Returns:
      %{
        tenant: ...,
        partition: ...,
        poller: ...,
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
    poller = poller_fixture(tenant, %{partition_id: partition.id})

    agents =
      for _ <- 1..agent_count do
        agent_fixture(poller)
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
      poller: poller,
      agents: agents,
      checkers: checkers,
      devices: devices
    }
  end
end
