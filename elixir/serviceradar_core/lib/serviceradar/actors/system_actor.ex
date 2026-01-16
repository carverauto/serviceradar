defmodule ServiceRadar.Actors.SystemActor do
  @moduledoc """
  Generates system actors for background operations.

  System actors allow background processes (GenServers, Oban workers, seeders)
  to perform Ash operations while maintaining authorization policy enforcement.

  ## Usage

      # For tenant instance code (search_path determines schema)
      actor = SystemActor.system(:state_monitor)
      Gateway |> Ash.read(actor: actor)

      # For platform-wide operations (bootstrap, tenant management)
      actor = SystemActor.platform(:tenant_bootstrap)
      Tenant |> Ash.read(actor: actor)

  ## When to Use Each Type

  - `system/1` - Use in tenant instance code where the DB connection's
    search_path is set by CNPG credentials (tenant-unaware mode).
    Each instance serves a single tenant, so no tenant_id is needed.

  - `platform/1` - Use for cross-tenant operations in the public schema
    (tenant management, operator bootstrap, etc.)

  ## Why Not authorize?: false?

  Using `authorize?: false` bypasses ALL authorization policies including
  tenant isolation. This creates security vulnerabilities where background
  operations could inadvertently access cross-tenant data.

  System actors ensure:
  1. Authorization policies are properly evaluated
  2. Operations are auditable with identifiable actors
  3. New security policies apply to all operations

  ## Actor Structure

  System actors are maps with the following fields:
  - `id` - Unique identifier (e.g., "system:state_monitor")
  - `email` - Descriptive email for audit logs (e.g., "state-monitor@system.serviceradar")
  - `role` - Either `:system` or `:super_admin` (platform-wide)
  """

  @type component :: atom()

  @type system_actor :: %{
          id: String.t(),
          email: String.t(),
          role: :system
        }

  @type platform_actor :: %{
          id: String.t(),
          email: String.t(),
          role: :super_admin
        }

  @doc """
  Creates a platform-level system actor for cross-tenant operations.

  The actor will have:
  - `role: :super_admin` - Full access across all tenants
  - No `tenant_id` - Not scoped to any specific tenant

  ## Important

  Only use for legitimate cross-tenant operations like:
  - Platform bootstrap (before tenants exist)
  - Tenant management operations
  - Cross-tenant analytics or reporting
  - Seeding default data across tenants

  Regular tenant operations should use `system/1` instead.

  ## Parameters

  - `component` - Atom identifying the system component (e.g., `:tenant_bootstrap`, `:operator_bootstrap`)

  ## Examples

      iex> SystemActor.platform(:tenant_bootstrap)
      %{
        id: "platform:tenant_bootstrap",
        email: "tenant-bootstrap@platform.serviceradar",
        role: :super_admin
      }

      iex> SystemActor.platform(:operator_bootstrap)
      %{
        id: "platform:operator_bootstrap",
        email: "operator-bootstrap@platform.serviceradar",
        role: :super_admin
      }
  """
  @spec platform(component()) :: platform_actor()
  def platform(component) when is_atom(component) do
    %{
      id: "platform:#{component}",
      email: "#{component_to_email(component)}@platform.serviceradar",
      role: :super_admin
    }
  end

  @doc """
  Creates a system actor for tenant-unaware mode.

  In tenant-unaware mode, the tenant is implicit from the database connection's
  `search_path`, so we don't need to include `tenant_id` in the actor.

  The actor will have:
  - `role: :system` - Recognized by authorization policies
  - No `tenant_id` - Tenant isolation is enforced by DB connection

  ## Parameters

  - `component` - Atom identifying the system component (e.g., `:state_monitor`, `:sweep_compiler`)

  ## Examples

      iex> SystemActor.system(:state_monitor)
      %{
        id: "system:state_monitor",
        email: "state-monitor@system.serviceradar",
        role: :system
      }

  ## When to Use

  Use `system/1` in tenant instance code where the DB connection's
  search_path is set by CNPG credentials (tenant isolation is implicit).
  Each instance serves a single tenant, so no tenant_id is needed.
  """
  @spec system(component()) :: %{id: String.t(), email: String.t(), role: :system}
  def system(component) when is_atom(component) do
    %{
      id: "system:#{component}",
      email: "#{component_to_email(component)}@system.serviceradar",
      role: :system
    }
  end

  @doc """
  Checks if the given actor is a system actor.

  ## Examples

      iex> SystemActor.system_actor?(%{role: :system})
      true

      iex> SystemActor.system_actor?(%{role: :super_admin})
      true

      iex> SystemActor.system_actor?(%{role: :admin})
      false

      iex> SystemActor.system_actor?(nil)
      false
  """
  @spec system_actor?(any()) :: boolean()
  def system_actor?(%{role: :system}), do: true
  def system_actor?(%{role: :super_admin, id: "platform:" <> _}), do: true
  def system_actor?(_), do: false

  # Converts an atom component name to an email-friendly string
  # :state_monitor -> "state-monitor"
  # :sweep_compiler -> "sweep-compiler"
  defp component_to_email(component) do
    component
    |> Atom.to_string()
    |> String.replace("_", "-")
  end
end
