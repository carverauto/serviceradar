defmodule ServiceRadar.Repo do
  @moduledoc """
  ServiceRadar Core database repository.

  Uses AshPostgres for Ash resource persistence. The database connection
  is configured via the :serviceradar_core application config.

  Tenant isolation is handled by the database connection's `search_path`,
  set by CNPG scoped credentials. The application code is tenant-unaware.

  ## Inherited Ecto.Repo Functions

  This module inherits all standard Ecto.Repo functions via AshPostgres.Repo,
  including `transact/2` and `all_by/3` from Ecto 3.12+.
  """
  use AshPostgres.Repo,
    otp_app: :serviceradar_core

  def installed_extensions do
    # Extensions available in the database
    ["uuid-ossp", "citext", "ash-functions"]
  end

  def min_pg_version do
    %Version{major: 15, minor: 0, patch: 0}
  end

  @doc """
  Returns all tenant schemas for migrations and cross-tenant operations.

  In tenant instance deployments, the schema is set by DB connection's
  search_path so there's no need to enumerate tenants.
  """
  def all_tenants do
    # Schema is set by DB connection's search_path (CNPG credentials)
    # No need to enumerate tenants
    []
  end
end
