defmodule ServiceRadar.Identity.Changes.InitializeTenantInfrastructure do
  @moduledoc """
  Ash change that initializes tenant infrastructure after tenant creation.

  This change runs after a tenant is successfully created and:

  1. Creates per-tenant Horde registry and DynamicSupervisor
  2. Registers slug -> UUID mapping for admin lookups
  3. Provisions per-tenant Oban queues for job isolation
  4. Enqueues NATS account creation job for tenant isolation

  ## Usage

  Add to tenant create actions:

  ```elixir
  create :create do
    accept [:name, :slug, ...]
    change ServiceRadar.Identity.Changes.InitializeTenantInfrastructure
  end
  ```

  ## Note on Multitenancy

  Tenant data is isolated in per-tenant PostgreSQL schemas (`strategy :context`).
  Tenant schema creation and migrations are executed before the tenant is usable.
  """

  use Ash.Resource.Change

  alias ServiceRadar.Cluster.{TenantRegistry, TenantSchemas}
  alias ServiceRadar.NATS.Workers.CreateAccountWorker
  alias ServiceRadar.Oban.TenantQueues

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

    Logger.info("Initializing infrastructure for tenant: #{tenant_slug} (#{tenant_id})")

    with {:ok, _schema} <- TenantSchemas.create_schema(tenant_slug) do
      # 1. Create per-tenant Horde registry and DynamicSupervisor
      case TenantRegistry.ensure_registry(tenant_id, tenant_slug) do
        {:ok, %{registry: registry, supervisor: supervisor}} ->
          Logger.debug(
            "Created TenantRegistry infrastructure: registry=#{registry}, supervisor=#{supervisor}"
          )

        {:error, reason} ->
          Logger.error("Failed to create TenantRegistry for #{tenant_slug}: #{inspect(reason)}")
          # Don't fail the tenant creation, just log the error
          # Registry will be lazily created on first gateway/agent connection
      end

      # 2. Provision per-tenant Oban queues for job isolation
      case TenantQueues.provision_tenant(tenant_id) do
        :ok ->
          Logger.debug("Provisioned Oban queues for tenant: #{tenant_slug}")

        {:error, reason} ->
          Logger.error("Failed to provision Oban queues for #{tenant_slug}: #{inspect(reason)}")
          # Don't fail tenant creation, queues can be provisioned later
      end

      # 3. Enqueue NATS account creation job for tenant isolation
      case CreateAccountWorker.enqueue(tenant_id) do
        {:ok, _job} ->
          Logger.debug("Enqueued NATS account creation for tenant: #{tenant_slug}")

        {:error, reason} ->
          Logger.error(
            "Failed to enqueue NATS account creation for #{tenant_slug}: #{inspect(reason)}"
          )

          # Don't fail tenant creation, account can be created later via admin action
      end

      {:ok, tenant}
    else
      {:error, reason} ->
        Logger.error("Failed to initialize tenant schema for #{tenant_slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
