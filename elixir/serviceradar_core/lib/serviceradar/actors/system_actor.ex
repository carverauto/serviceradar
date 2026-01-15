defmodule ServiceRadar.Actors.SystemActor do
  @moduledoc """
  Generates tenant-scoped system actors for background operations.

  System actors allow background processes (GenServers, Oban workers, seeders)
  to perform Ash operations while maintaining tenant isolation policy enforcement.

  ## Usage

      # For tenant-scoped operations
      actor = SystemActor.for_tenant(tenant_id, :state_monitor)
      Gateway |> Ash.read(actor: actor, tenant: tenant_schema)

      # For platform-wide operations (bootstrap, tenant management)
      actor = SystemActor.platform(:tenant_bootstrap)
      Tenant |> Ash.read(actor: actor)

  ## Why Not authorize?: false?

  Using `authorize?: false` bypasses ALL authorization policies including
  tenant isolation. This creates security vulnerabilities where background
  operations could inadvertently access cross-tenant data.

  System actors ensure:
  1. Tenant isolation policies are enforced via `actor(:tenant_id)`
  2. Operations are auditable with identifiable actors
  3. New security policies apply to all operations

  ## Actor Structure

  System actors are maps with the following fields:
  - `id` - Unique identifier (e.g., "system:state_monitor")
  - `email` - Descriptive email for audit logs (e.g., "state-monitor@system.serviceradar")
  - `role` - Either `:system` (tenant-scoped) or `:super_admin` (platform-wide)
  - `tenant_id` - The tenant UUID (only for tenant-scoped actors)
  """

  @type component :: atom()

  @type tenant_actor :: %{
          id: String.t(),
          email: String.t(),
          role: :system,
          tenant_id: String.t()
        }

  @type platform_actor :: %{
          id: String.t(),
          email: String.t(),
          role: :super_admin
        }

  @doc """
  Creates a system actor for tenant-scoped operations.

  The actor will have:
  - `role: :system` - Recognized by authorization policies
  - `tenant_id` - Ensures tenant isolation policies are enforced

  ## Parameters

  - `tenant_id` - The tenant UUID this actor operates within
  - `component` - Atom identifying the system component (e.g., `:state_monitor`, `:sweep_compiler`)

  ## Examples

      iex> SystemActor.for_tenant("abc-123", :state_monitor)
      %{
        id: "system:state_monitor",
        email: "state-monitor@system.serviceradar",
        role: :system,
        tenant_id: "abc-123"
      }

      iex> SystemActor.for_tenant("abc-123", :sweep_compiler)
      %{
        id: "system:sweep_compiler",
        email: "sweep-compiler@system.serviceradar",
        role: :system,
        tenant_id: "abc-123"
      }
  """
  @spec for_tenant(String.t(), component()) :: tenant_actor()
  def for_tenant(tenant_id, component) when is_binary(tenant_id) and is_atom(component) do
    %{
      id: "system:#{component}",
      email: "#{component_to_email(component)}@system.serviceradar",
      role: :system,
      tenant_id: tenant_id
    }
  end

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

  Regular tenant operations should use `for_tenant/2` instead.

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

  Use `system/1` when `TENANT_AWARE_MODE=false` and the tenant context
  is provided by database credentials (schema-scoped CNPG users).

  Use `for_tenant/2` when `TENANT_AWARE_MODE=true` and the tenant must
  be explicitly passed to Ash operations.
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

      iex> SystemActor.system_actor?(%{role: :system, tenant_id: "abc"})
      true

      iex> SystemActor.system_actor?(%{role: :super_admin})
      true

      iex> SystemActor.system_actor?(%{role: :admin, tenant_id: "abc"})
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
