defmodule ServiceRadar.Policies do
  @moduledoc """
  Base policy macros and checks for ServiceRadar authorization.

  Provides reusable policy patterns for RBAC and multi-tenancy.

  ## Roles

  - `:viewer` - Read-only access to tenant data
  - `:operator` - Can create and modify resources within tenant
  - `:admin` - Full tenant management including user management
  - `:super_admin` - Platform-wide access, bypasses all policies

  ## Usage

      defmodule MyApp.MyResource do
        use Ash.Resource, ...

        policies do
          # Import common policies
          import ServiceRadar.Policies

          # Super admin bypass
          bypass always() do
            authorize_if is_super_admin()
          end

          # Tenant isolation
          policy action_type(:read) do
            authorize_if tenant_matches()
          end
        end
      end
  """

  @doc """
  Check if the actor has super_admin role.
  Super admins bypass all tenant restrictions.
  """
  defmacro is_super_admin do
    quote do
      actor_attribute_equals(:role, :super_admin)
    end
  end

  @doc """
  Check if the actor has admin role (or higher).
  """
  defmacro is_admin do
    quote do
      expr(^actor(:role) in [:admin, :super_admin])
    end
  end

  @doc """
  Check if the actor has operator role (or higher).
  """
  defmacro is_operator do
    quote do
      expr(^actor(:role) in [:operator, :admin, :super_admin])
    end
  end

  @doc """
  Check if the actor has at least viewer role.
  """
  defmacro is_viewer do
    quote do
      expr(^actor(:role) in [:viewer, :operator, :admin, :super_admin])
    end
  end

  @doc """
  Check if the resource's tenant_id matches the actor's tenant_id.
  Used for tenant isolation policies.
  """
  defmacro tenant_matches do
    quote do
      expr(tenant_id == ^actor(:tenant_id))
    end
  end

  @doc """
  Check if actor is accessing their own record.
  Useful for user self-management policies.
  """
  defmacro is_self do
    quote do
      expr(id == ^actor(:id))
    end
  end
end
