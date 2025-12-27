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

  # ===========================================================================
  # Partition-Aware Policies
  # ===========================================================================

  @doc """
  Check if the resource's partition_id matches the actor's partition context.

  If the actor has no partition_id set, access is allowed to all partitions
  within their tenant (backward compatible behavior).

  If the actor has a partition_id set, access is restricted to resources
  in that specific partition.

  ## Usage

      policy action_type(:read) do
        authorize_if partition_matches()
      end
  """
  defmacro partition_matches do
    quote do
      expr(
        is_nil(^actor(:partition_id)) or
          partition_id == ^actor(:partition_id)
      )
    end
  end

  @doc """
  Combined check for tenant AND partition isolation.

  Ensures the resource belongs to the actor's tenant AND is either:
  - In the actor's specified partition, or
  - Accessible because the actor has no partition restriction

  ## Usage

      policy action_type(:read) do
        authorize_if tenant_and_partition_match()
      end
  """
  defmacro tenant_and_partition_match do
    quote do
      expr(
        tenant_id == ^actor(:tenant_id) and
          (is_nil(^actor(:partition_id)) or partition_id == ^actor(:partition_id))
      )
    end
  end

  @doc """
  Check for resources that have an optional partition_id.

  Some resources may have partition_id as an optional field. This macro
  handles the case where the resource's partition_id might be nil.

  ## Usage

      policy action_type(:read) do
        authorize_if optional_partition_matches()
      end
  """
  defmacro optional_partition_matches do
    quote do
      expr(
        is_nil(^actor(:partition_id)) or
          is_nil(partition_id) or
          partition_id == ^actor(:partition_id)
      )
    end
  end

  @doc """
  Require that the actor has specified a partition context.

  Useful for actions that must operate within a specific partition,
  such as IP-based queries in overlapping address spaces.

  ## Usage

      policy action(:by_ip_address) do
        authorize_if has_partition_context()
      end
  """
  defmacro has_partition_context do
    quote do
      expr(not is_nil(^actor(:partition_id)))
    end
  end
end
