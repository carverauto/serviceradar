defmodule ServiceRadar.Repo do
  @moduledoc """
  ServiceRadar Core database repository.

  Uses AshPostgres for Ash resource persistence. The database connection
  is configured via the :serviceradar_core application config.

  ## Tenant Modes

  The repository supports two tenant isolation modes controlled by
  `TENANT_AWARE_MODE` environment variable:

  ### Tenant-Aware Mode (default, TENANT_AWARE_MODE=true)

  - Uses `TenantSchemas.list_schemas()` to enumerate all tenant schemas
  - Ash operations require explicit `tenant:` parameter
  - Suitable for Control Plane that manages multiple tenants

  ### Tenant-Unaware Mode (TENANT_AWARE_MODE=false)

  - Tenant is implicit from database connection's `search_path`
  - Ash operations don't need `tenant:` parameter
  - Suitable for tenant instances with scoped CNPG credentials

  ## Inherited Ecto.Repo Functions

  This module inherits all standard Ecto.Repo functions via AshPostgres.Repo,
  including `transact/2` and `all_by/3` from Ecto 3.12+.
  """
  use AshPostgres.Repo,
    otp_app: :serviceradar_core

  alias ServiceRadar.Cluster.TenantMode

  def installed_extensions do
    # Extensions available in the database
    ["uuid-ossp", "citext", "ash-functions"]
  end

  def min_pg_version do
    %Version{major: 15, minor: 0, patch: 0}
  end

  @doc """
  Returns all tenant schemas for migrations and cross-tenant operations.

  In tenant-aware mode, returns all tenant schemas from the database.
  In tenant-unaware mode, returns an empty list (there's only "self").
  """
  def all_tenants do
    if TenantMode.tenant_aware?() do
      ServiceRadar.Cluster.TenantSchemas.list_schemas()
    else
      # In tenant-unaware mode, the schema is set by DB connection
      # There's no need to enumerate tenants for migrations
      []
    end
  end
end
