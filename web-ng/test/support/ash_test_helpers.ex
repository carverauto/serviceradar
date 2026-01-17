defmodule ServiceRadarWebNG.AshTestHelpers do
  @moduledoc """
  Comprehensive test helpers for Ash resources.

  Provides fixtures, actors, and policy testing utilities for all
  ServiceRadar Ash domains: Identity, Inventory, Infrastructure,
  Monitoring, and Edge.

  ## Usage

      use ServiceRadarWebNG.AshTestHelpers

      test "creates a device" do
        device = device_fixture()
        assert device.id
      end

  ## Actors

  The module provides several actor types for testing authorization:

  - `system_actor/0` - Bypasses all authorization (system)
  - `admin_actor/0` - Admin role
  - `operator_actor/0` - Operator role
  - `viewer_actor/0` - Viewer role (read-only)
  """

  alias ServiceRadar.Identity.{User, ApiToken}
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
      role: :system
    }
  end

  # ============================================================================
  # Role-Based Actors
  # ============================================================================

  @doc """
  Creates an admin actor.
  """
  def admin_actor do
    %{
      id: Ecto.UUID.generate(),
      email: "admin-#{System.unique_integer([:positive])}@test.local",
      role: :admin
    }
  end

  @doc """
  Creates an operator actor.
  """
  def operator_actor do
    %{
      id: Ecto.UUID.generate(),
      email: "operator-#{System.unique_integer([:positive])}@test.local",
      role: :operator
    }
  end

  @doc """
  Creates a viewer actor.
  """
  def viewer_actor do
    %{
      id: Ecto.UUID.generate(),
      email: "viewer-#{System.unique_integer([:positive])}@test.local",
      role: :viewer
    }
  end

  @doc """
  Creates an actor map from a User struct.
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
  Creates a user fixture.
  """
  def user_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

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
  Creates a user with admin role.
  """
  def admin_user_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)

    user
    |> Ash.Changeset.for_update(:update_role, %{role: :admin}, actor: system_actor())
    |> Ash.update!()
  end

  @doc """
  Creates a user with operator role.
  """
  def operator_user_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)

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
  Creates a device fixture.
  """
  def device_fixture(attrs \\ %{}) do
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
  Creates a partition fixture.
  """
  def partition_fixture(attrs \\ %{}) do
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
  Creates a gateway fixture.
  """
  def gateway_fixture(attrs \\ %{}) do
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

    Checker
    |> Ash.Changeset.for_create(:create, attrs, actor: system_actor())
    |> Ash.create!()
  end

  # ============================================================================
  # Monitoring Domain Fixtures
  # ============================================================================

  @doc """
  Creates a service check fixture.
  """
  def service_check_fixture(attrs \\ %{}) do
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
  Creates an alert fixture.
  """
  def alert_fixture(attrs \\ %{}) do
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
  Creates a polling schedule fixture.
  """
  def polling_schedule_fixture(attrs \\ %{}) do
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
  Creates an onboarding package fixture.
  """
  def onboarding_package_fixture(attrs \\ %{}) do
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
  # Test Scenarios
  # ============================================================================

  @doc """
  Creates a complete test scenario with users and resources.

  Returns a map with all the created resources:

      %{
        admin: ...,
        operator: ...,
        viewer: ...,
        device: ...,
        gateway: ...,
        agent: ...
      }
  """
  def test_scenario do
    gateway = gateway_fixture()

    %{
      admin: admin_user_fixture(),
      operator: operator_user_fixture(),
      viewer: user_fixture(),
      device: device_fixture(),
      gateway: gateway,
      agent: agent_fixture(gateway)
    }
  end

  @doc """
  Creates a full infrastructure hierarchy for testing.

  Returns:
      %{
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

    partition = partition_fixture()
    gateway = gateway_fixture(%{partition_id: partition.id})

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
        device_fixture()
      end

    %{
      partition: partition,
      gateway: gateway,
      agents: agents,
      checkers: checkers,
      devices: devices
    }
  end
end
