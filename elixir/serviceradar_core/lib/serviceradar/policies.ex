defmodule ServiceRadar.Policies do
  @moduledoc """
  Base policy macros and checks for ServiceRadar authorization.

  Provides reusable policy patterns for RBAC.

  ## Instance Isolation

  Each instance deployment is fully isolated:
  - DB connection's search_path determines the schema

  ## Roles

  - `:viewer` - Read-only access to instance data
  - `:operator` - Can create and modify resources within instance
  - `:admin` - Full instance management including user management

  ## Usage

      defmodule MyApp.MyResource do
        use Ash.Resource, ...

        policies do
          import ServiceRadar.Policies

          # DB connection's search_path determines the schema
          policy action_type(:read) do
            authorize_if is_viewer()
          end
        end
      end
  """

  @doc """
  Check if the actor has admin role (or higher).
  """
  defmacro is_admin do
    quote do
      expr(^actor(:role) == :admin)
    end
  end

  @doc """
  Check if the actor has operator role (or higher).
  """
  defmacro is_operator do
    quote do
      expr(^actor(:role) in [:operator, :admin])
    end
  end

  @doc """
  Check if the actor has at least viewer role.
  """
  defmacro is_viewer do
    quote do
      expr(^actor(:role) in [:viewer, :operator, :admin])
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

  @doc """
  Allow system actors to bypass all policy checks.
  """
  defmacro system_bypass do
    quote do
      bypass always() do
        authorize_if actor_attribute_equals(:role, :system)
      end
    end
  end

  @doc """
  Allow all authenticated actors in the deployment to read.
  """
  defmacro read_all do
    quote do
      policy action_type(:read) do
        authorize_if always()
      end
    end
  end

  @doc """
  Allow viewers, operators, and admins to read.
  """
  defmacro read_viewer_plus do
    quote do
      policy action_type(:read) do
        authorize_if is_viewer()
      end
    end
  end

  @doc """
  Allow operators and admins to read.
  """
  defmacro read_operator_plus do
    quote do
      policy action_type(:read) do
        authorize_if is_operator()
      end
    end
  end

  @doc """
  Restrict one or more action types to admins.
  """
  defmacro admin_action_type(action_type_or_types) do
    quote do
      policy action_type(unquote(action_type_or_types)) do
        authorize_if is_admin()
      end
    end
  end

  @doc """
  Restrict one or more action types to operators and admins.
  """
  defmacro operator_action_type(action_type_or_types) do
    quote do
      policy action_type(unquote(action_type_or_types)) do
        authorize_if is_operator()
      end
    end
  end

  @doc """
  Restrict one or more named actions to admins.
  """
  defmacro admin_action(actions) do
    quote do
      policy action(unquote(actions)) do
        authorize_if is_admin()
      end
    end
  end

  @doc """
  Restrict one or more named actions to operators and admins.
  """
  defmacro operator_action(actions) do
    quote do
      policy action(unquote(actions)) do
        authorize_if is_operator()
      end
    end
  end

  # ===========================================================================
  # Partition-Aware Policies
  # ===========================================================================

  @doc """
  Check if the resource's partition_id matches the actor's partition context.

  If the actor has no partition_id set, access is allowed to all partitions
  (backward compatible behavior).

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
