defmodule ServiceRadar.Identity.Changes.InitializeTenantInfrastructure do
  @moduledoc """
  Ash change that initializes tenant infrastructure after tenant creation.

  This change runs after a tenant is successfully created and:

  1. Creates per-tenant Horde registry and DynamicSupervisor
  2. Registers slug -> UUID mapping for admin lookups
  3. Optionally creates PostgreSQL schema for enterprise tenants

  ## Usage

  Add to tenant create actions:

  ```elixir
  create :create do
    accept [:name, :slug, ...]
    change ServiceRadar.Identity.Changes.InitializeTenantInfrastructure
  end
  ```

  ## Configuration

  The `:auto_create_schema` option controls PostgreSQL schema creation:

  - `false` (default) - Don't create schema automatically
  - `true` - Create schema for all tenants
  - `:enterprise_only` - Only create schema for enterprise plan tenants

  Configure in your app config:

  ```elixir
  config :serviceradar_core, :tenant_infrastructure,
    auto_create_schema: :enterprise_only
  ```
  """

  use Ash.Resource.Change

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Cluster.TenantSchemas

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, tenant ->
      initialize_tenant(tenant)
    end)
  end

  @doc """
  Initializes infrastructure for a tenant.

  Can be called manually for existing tenants that need initialization.
  """
  @spec initialize_tenant(struct()) :: {:ok, struct()} | {:error, term()}
  def initialize_tenant(tenant) do
    tenant_id = tenant.id
    tenant_slug = to_string(tenant.slug)
    plan = tenant.plan

    Logger.info("Initializing infrastructure for tenant: #{tenant_slug} (#{tenant_id})")

    # 1. Create per-tenant Horde registry and DynamicSupervisor
    case TenantRegistry.ensure_registry(tenant_id, tenant_slug) do
      {:ok, %{registry: registry, supervisor: supervisor}} ->
        Logger.debug(
          "Created TenantRegistry infrastructure: registry=#{registry}, supervisor=#{supervisor}"
        )

      {:error, reason} ->
        Logger.error("Failed to create TenantRegistry for #{tenant_slug}: #{inspect(reason)}")
        # Don't fail the tenant creation, just log the error
        # Registry will be lazily created on first poller/agent connection
    end

    # 2. Optionally create PostgreSQL schema
    case should_create_schema?(plan) do
      true ->
        case TenantSchemas.create_schema(tenant_slug, run_migrations: true) do
          {:ok, schema_name} ->
            Logger.info("Created PostgreSQL schema: #{schema_name}")

          {:error, reason} ->
            Logger.error("Failed to create schema for #{tenant_slug}: #{inspect(reason)}")
            # Don't fail tenant creation, schema can be created later
        end

      false ->
        :ok
    end

    {:ok, tenant}
  end

  defp should_create_schema?(plan) do
    case Application.get_env(:serviceradar_core, :tenant_infrastructure, [])
         |> Keyword.get(:auto_create_schema, false) do
      true -> true
      false -> false
      :enterprise_only -> plan in [:enterprise, "enterprise"]
    end
  end
end
