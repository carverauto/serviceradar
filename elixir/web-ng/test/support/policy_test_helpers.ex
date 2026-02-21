defmodule ServiceRadarWebNG.PolicyTestHelpers do
  @moduledoc """
  Test helpers and macros for testing Ash authorization policies.

  Provides convenient assertions for testing that policies correctly
  allow or deny actions based on actor roles.

  ## Usage

      use ServiceRadarWebNG.PolicyTestHelpers
      use ServiceRadarWebNG.AshTestHelpers

      describe "Device policies" do
        test "admin can read devices" do
          device = device_fixture()
          actor = admin_actor()

          assert_authorized :read, Device, actor
        end

        test "viewer cannot update devices" do
          device = device_fixture()
          actor = viewer_actor()

          refute_authorized :update, Device, actor, device
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
      assert_authorized(:read, Device, actor)

      # Check update authorization on a specific record
      assert_authorized(:update, Device, actor, device)

      # Check create authorization
      assert_authorized(:create, Device, actor)
  """
  defmacro assert_authorized(action, resource, actor, record \\ nil) do
    quote do
      result =
        ServiceRadarWebNG.PolicyTestHelpers.check_authorization(
          unquote(action),
          unquote(resource),
          unquote(actor),
          unquote(record)
        )

      case result do
        :authorized ->
          assert true

        {:unauthorized, reason} ->
          flunk("""
          Expected #{inspect(unquote(actor).role)} to be authorized for #{unquote(action)} on #{inspect(unquote(resource))}
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
      refute_authorized(:update, Device, viewer_actor, device)
  """
  defmacro refute_authorized(action, resource, actor, record \\ nil) do
    quote do
      result =
        ServiceRadarWebNG.PolicyTestHelpers.check_authorization(
          unquote(action),
          unquote(resource),
          unquote(actor),
          unquote(record)
        )

      case result do
        :authorized ->
          flunk("""
          Expected #{inspect(unquote(actor).role)} to be DENIED for #{unquote(action)} on #{inspect(unquote(resource))}
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
  def check_authorization(action, resource, actor, record \\ nil)

  def check_authorization(:read, resource, actor, _record) do
    case Ash.can?({resource, :read}, actor) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  def check_authorization(:create, resource, actor, _record) do
    case Ash.can?({resource, :create}, actor) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  def check_authorization(:update, _resource, actor, record) when not is_nil(record) do
    case Ash.can?({record, :update}, actor) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  def check_authorization(:destroy, _resource, actor, record) when not is_nil(record) do
    case Ash.can?({record, :destroy}, actor) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  def check_authorization(action, resource, actor, record) do
    target = if record, do: {record, action}, else: {resource, action}

    case Ash.can?(target, actor) do
      {:ok, true} -> :authorized
      {:ok, false} -> {:unauthorized, :forbidden}
      {:ok, true, _} -> :authorized
      {:ok, false, _} -> {:unauthorized, :forbidden}
      {:error, error} -> {:unauthorized, error}
    end
  end

  @doc """
  Helper to create a resource for testing.
  Routes to the appropriate fixture function based on resource type.
  """
  def create_resource(resource) do
    import ServiceRadarWebNG.AshTestHelpers

    case resource do
      ServiceRadar.Inventory.Device -> device_fixture()
      ServiceRadar.Infrastructure.Gateway -> gateway_fixture()
      ServiceRadar.Identity.User -> user_fixture()
      ServiceRadar.Monitoring.Alert -> alert_fixture()
      ServiceRadar.Monitoring.ServiceCheck -> service_check_fixture()
      ServiceRadar.Edge.OnboardingPackage -> onboarding_package_fixture()
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

      record =
        ServiceRadarWebNG.PolicyTestHelpers.create_resource(unquote(resource))

      # Test each role
      for role <- [:admin, :operator, :viewer] do
        actor =
          case role do
            :admin -> admin_actor()
            :operator -> operator_actor()
            :viewer -> viewer_actor()
          end

        for action <- unquote(actions) do
          expected = ServiceRadarWebNG.PolicyTestHelpers.expected_permission(role, action)

          actual =
            ServiceRadarWebNG.PolicyTestHelpers.check_authorization(
              action,
              unquote(resource),
              actor,
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
