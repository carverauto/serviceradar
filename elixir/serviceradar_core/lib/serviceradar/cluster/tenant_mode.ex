defmodule ServiceRadar.Cluster.TenantMode do
  @moduledoc """
  Feature flag for tenant-aware vs tenant-unaware mode.

  ## Tenant-Aware Mode (default, legacy)

  When `TENANT_AWARE_MODE=true` (the default), the application:
  - Passes `tenant:` parameter to all Ash operations
  - Uses `SystemActor.for_tenant()` for scoped operations
  - Can use `TenantSchemas.list_schemas()` to iterate tenants

  ## Tenant-Unaware Mode (new architecture)

  When `TENANT_AWARE_MODE=false`, the application:
  - Does NOT pass `tenant:` parameter to Ash operations
  - Relies on PostgreSQL `search_path` set by connection credentials
  - Cannot access other tenant schemas (DB enforces isolation)
  - Uses simplified `SystemActor.system()` for background operations

  ## Migration Strategy

  1. Deploy with `TENANT_AWARE_MODE=true` (existing behavior)
  2. Test with `TENANT_AWARE_MODE=false` in dev environment
  3. Deploy tenant instances with scoped credentials and `TENANT_AWARE_MODE=false`
  4. Control Plane keeps `TENANT_AWARE_MODE=true` for cross-tenant operations

  ## Usage

      # Check the current mode
      if TenantMode.tenant_aware?() do
        Ash.read!(query, actor: actor, tenant: schema)
      else
        Ash.read!(query, actor: actor)
      end

      # Get tenant option for Ash operations
      opts = TenantMode.tenant_opts(schema_name)
      Ash.read!(query, [actor: actor] ++ opts)
  """

  @doc """
  Returns true if the application is running in tenant-aware mode.

  Defaults to `true` for backward compatibility.
  """
  @spec tenant_aware?() :: boolean()
  def tenant_aware? do
    case Application.get_env(:serviceradar_core, :tenant_aware_mode) do
      nil -> default_tenant_aware_mode()
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      _ -> default_tenant_aware_mode()
    end
  end

  @doc """
  Returns Ash operation options for tenant context.

  In tenant-aware mode, returns `[tenant: schema_name]`.
  In tenant-unaware mode, returns `[]` (tenant is implicit from DB connection).
  """
  @spec tenant_opts(String.t() | nil) :: keyword()
  def tenant_opts(schema_name) do
    if tenant_aware?() and schema_name do
      [tenant: schema_name]
    else
      []
    end
  end

  @doc """
  Conditionally applies tenant context to Ash options.

  ## Examples

      opts = [actor: actor]
      opts = TenantMode.with_tenant(opts, schema_name)
      Ash.read!(query, opts)
  """
  @spec with_tenant(keyword(), String.t() | nil) :: keyword()
  def with_tenant(opts, schema_name) do
    opts ++ tenant_opts(schema_name)
  end

  @doc """
  Returns the effective tenant schema for logging/debugging.

  In tenant-aware mode, returns the explicitly provided schema.
  In tenant-unaware mode, returns the schema from DB connection config.
  """
  @spec effective_tenant(String.t() | nil) :: String.t()
  def effective_tenant(explicit_schema) do
    if tenant_aware?() do
      explicit_schema || "(none)"
    else
      # In tenant-unaware mode, the schema is set by DB connection
      Application.get_env(:serviceradar_core, :tenant_schema) ||
        System.get_env("DB_SCHEMA") ||
        "(from connection)"
    end
  end

  @doc """
  Creates a system actor appropriate for the current tenant mode.

  In tenant-aware mode, creates an actor with `tenant_id` using `SystemActor.for_tenant/2`.
  In tenant-unaware mode, creates an actor without `tenant_id` using `SystemActor.system/1`.

  ## Parameters

    - `component` - Atom identifying the system component (e.g., `:state_monitor`)
    - `tenant_id` - The tenant UUID (only used in tenant-aware mode)

  ## Examples

      # In tenant-aware mode (TENANT_AWARE_MODE=true)
      actor = TenantMode.system_actor(:worker, "tenant-uuid")
      # => %{id: "system:worker", role: :system, tenant_id: "tenant-uuid", ...}

      # In tenant-unaware mode (TENANT_AWARE_MODE=false)
      actor = TenantMode.system_actor(:worker, "tenant-uuid")
      # => %{id: "system:worker", role: :system, ...}  # no tenant_id
  """
  @spec system_actor(atom(), String.t() | nil) :: map()
  def system_actor(component, tenant_id) when is_atom(component) do
    alias ServiceRadar.Actors.SystemActor

    if tenant_aware?() and tenant_id do
      SystemActor.for_tenant(tenant_id, component)
    else
      SystemActor.system(component)
    end
  end

  @doc """
  Returns full Ash operation options with actor and optional tenant.

  Combines the actor and tenant context into a single options list.
  In tenant-unaware mode, the tenant option is omitted.

  ## Parameters

    - `component` - Atom identifying the system component
    - `tenant_id` - The tenant UUID (for actor creation in tenant-aware mode)
    - `schema_name` - The tenant schema (for tenant option in tenant-aware mode)

  ## Examples

      opts = TenantMode.ash_opts(:worker, tenant_id, schema)
      Ash.read!(query, opts)

      # In tenant-aware mode returns: [actor: %{...}, tenant: "tenant_xyz"]
      # In tenant-unaware mode returns: [actor: %{...}]
  """
  @spec ash_opts(atom(), String.t() | nil, String.t() | nil) :: keyword()
  def ash_opts(component, tenant_id, schema_name) when is_atom(component) do
    actor = system_actor(component, tenant_id)
    [actor: actor] ++ tenant_opts(schema_name)
  end

  # Default to tenant-aware mode for backward compatibility
  defp default_tenant_aware_mode do
    # Check environment variable as fallback
    case System.get_env("TENANT_AWARE_MODE") do
      "false" -> false
      "0" -> false
      _ -> true
    end
  end
end
