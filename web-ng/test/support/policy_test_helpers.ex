defmodule ServiceRadarWebNG.PolicyTestHelpers do
  @moduledoc """
  Test helpers and macros for testing Ash authorization policies.

  Provides convenient assertions for testing that policies correctly
  allow or deny actions based on actor roles and tenant membership.

  ## Usage

      use ServiceRadarWebNG.PolicyTestHelpers
      use ServiceRadarWebNG.AshTestHelpers

      describe "Device policies" do
        test "admin can read devices in their tenant" do
          tenant = tenant_fixture()
          device = device_fixture(tenant)
          actor = admin_actor(tenant)

          assert_authorized :read, Device, actor, tenant
        end

        test "viewer cannot update devices" do
          tenant = tenant_fixture()
          device = device_fixture(tenant)
          actor = viewer_actor(tenant)

          refute_authorized :update, Device, actor, tenant, device
        end
      end
  """

  @doc """
  Import all policy test helpers into the using module.
  """
  defmacro __using__(_opts) do
    quote do
      import ServiceRadarWebNG.PolicyTestHelpers
    end
  end

  @doc """
  Asserts that an actor is authorized to perform an action on a resource.

  ## Examples

      # Check read authorization on a resource type
      assert_authorized(:read, Device, actor, tenant)

      # Check update authorization on a specific record
      assert_authorized(:update, Device, actor, tenant, device)

      # Check create authorization
      assert_authorized(:create, Device, actor, tenant)
  """
  defmacro assert_authorized(action, resource, actor, tenant, record \\ nil) do
    quote do
      result =
        ServiceRadarWebNG.PolicyTestHelpers.check_authorization(
          unquote(action),
          unquote(resource),
          unquote(actor),
          unquote(tenant),
          unquote(record)
        )

      case result do
        :authorized ->
          assert true

        {:unauthorized, reason} ->
          flunk("""
          Expected #{inspect(unquote(actor).role)} to be authorized for #{unquote(action)} on #{inspect(unquote(resource))}
          Tenant: #{inspect(unquote(tenant).id)}
          Record: #{inspect(unquote(record))}
          Reason: #{inspect(reason)}
          """)
      end
    end
  end

  @doc """
  Refutes that an actor is authorized to perform an action on a resource.

  ## Examples

      # Check that viewer cannot update
      refute_authorized(:update, Device, viewer_actor, tenant, device)

      # Check that user from other tenant cannot read
      refute_authorized(:read, Device, other_tenant_actor, tenant)
  """
  defmacro refute_authorized(action, resource, actor, tenant, record \\ nil) do
    quote do
      result =
        ServiceRadarWebNG.PolicyTestHelpers.check_authorization(
          unquote(action),
          unquote(resource),
          unquote(actor),
          unquote(tenant),
          unquote(record)
        )

      case result do
        :authorized ->
          flunk("""
          Expected #{inspect(unquote(actor).role)} to be DENIED for #{unquote(action)} on #{inspect(unquote(resource))}
          Tenant: #{inspect(unquote(tenant).id)}
          Record: #{inspect(unquote(record))}
          But action was authorized.
          """)

        {:unauthorized, _reason} ->
          assert true
      end
    end
  end

  @doc """
  Checks if an actor is authorized to perform an action.
  Returns :authorized or {:unauthorized, reason}.
  """
  def check_authorization(action, resource, actor, tenant, record \\ nil)

  def check_authorization(:read, resource, actor, tenant, _record) do
    case Ash.can?({resource, :read}, actor, tenant: tenant.id) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  def check_authorization(:create, resource, actor, tenant, _record) do
    case Ash.can?({resource, :create}, actor, tenant: tenant.id) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  def check_authorization(:update, _resource, actor, tenant, record) when not is_nil(record) do
    case Ash.can?({record, :update}, actor, tenant: tenant.id) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  def check_authorization(:destroy, _resource, actor, tenant, record) when not is_nil(record) do
    case Ash.can?({record, :destroy}, actor, tenant: tenant.id) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  def check_authorization(action, resource, actor, tenant, record) do
    target = if record, do: {record, action}, else: {resource, action}

    case Ash.can?(target, actor, tenant: tenant.id) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  @doc """
  Tests that cross-tenant access is denied.
  Creates resources in one tenant and tries to access from another.

  ## Example

      test "cross-tenant isolation" do
        assert_tenant_isolation(Device, :read)
      end
  """
  defmacro assert_tenant_isolation(resource, _action) do
    quote do
      import ServiceRadarWebNG.AshTestHelpers

      tenant_a = tenant_fixture(%{name: "Isolation Test A", slug: "isolation-a"})
      tenant_b = tenant_fixture(%{name: "Isolation Test B", slug: "isolation-b"})

      # Create resource in tenant A
      resource_a =
        ServiceRadarWebNG.PolicyTestHelpers.create_resource_for_tenant(
          unquote(resource),
          tenant_a
        )

      # Actor from tenant B should not be able to access
      actor_b = admin_actor(tenant_b)

      # Try to read with tenant A's context but tenant B's actor
      result = Ash.read(unquote(resource), actor: actor_b, tenant: tenant_b.id)

      case result do
        {:ok, resources} ->
          resource_ids = Enum.map(resources, & &1.id)

          refute resource_a.id in resource_ids,
                 "Resource from tenant A should not be visible to tenant B"

        {:error, _} ->
          # Error is also acceptable - means access was denied
          assert true
      end
    end
  end

  @doc """
  Helper to create a resource for a given tenant.
  Routes to the appropriate fixture function based on resource type.
  """
  def create_resource_for_tenant(resource, tenant) do
    import ServiceRadarWebNG.AshTestHelpers

    case resource do
      ServiceRadar.Inventory.Device -> device_fixture(tenant)
      ServiceRadar.Infrastructure.Gateway -> gateway_fixture(tenant)
      ServiceRadar.Identity.User -> user_fixture(tenant)
      ServiceRadar.Monitoring.Alert -> alert_fixture(tenant)
      ServiceRadar.Monitoring.ServiceCheck -> service_check_fixture(tenant)
      ServiceRadar.Edge.OnboardingPackage -> onboarding_package_fixture(tenant)
      _ -> raise "Unknown resource type: #{inspect(resource)}"
    end
  end

  @doc """
  Tests a complete RBAC matrix for a resource.

  Verifies that:
  - Admins can perform all actions
  - Operators can read and update but not destroy
  - Viewers can only read

  ## Example

      test "device RBAC" do
        assert_rbac_matrix(Device, [:read, :update, :destroy])
      end
  """
  defmacro assert_rbac_matrix(resource, actions) do
    quote do
      import ServiceRadarWebNG.AshTestHelpers

      tenant = tenant_fixture()

      record =
        ServiceRadarWebNG.PolicyTestHelpers.create_resource_for_tenant(unquote(resource), tenant)

      # Test each role
      for role <- [:admin, :operator, :viewer] do
        actor =
          case role do
            :admin -> admin_actor(tenant)
            :operator -> operator_actor(tenant)
            :viewer -> viewer_actor(tenant)
          end

        for action <- unquote(actions) do
          expected = ServiceRadarWebNG.PolicyTestHelpers.expected_permission(role, action)

          actual =
            ServiceRadarWebNG.PolicyTestHelpers.check_authorization(
              action,
              unquote(resource),
              actor,
              tenant,
              record
            )

          if expected do
            assert actual == :authorized,
                   "Expected #{role} to be authorized for #{action} on #{inspect(unquote(resource))}, got: #{inspect(actual)}"
          else
            assert match?({:unauthorized, _}, actual),
                   "Expected #{role} to be DENIED for #{action} on #{inspect(unquote(resource))}, got: #{inspect(actual)}"
          end
        end
      end
    end
  end

  @doc """
  Returns expected permission for a role/action combination.
  Based on the standard RBAC matrix:
  - admin: all permissions
  - operator: read, update, create (no destroy)
  - viewer: read only
  """
  def expected_permission(role, action) do
    case {role, action} do
      {:admin, _} -> true
      {:operator, :read} -> true
      {:operator, :create} -> true
      {:operator, :update} -> true
      {:operator, :destroy} -> false
      {:viewer, :read} -> true
      {:viewer, _} -> false
      _ -> false
    end
  end
end
