defmodule ServiceRadarWebNGWeb.TenantResolver do
  @moduledoc """
  Simplified tenant resolver for single-tenant instance deployments.

  This module provides schema resolution for Ash queries. In single-tenant mode,
  the tenant is implicit from the deployment (PostgreSQL search_path is set by
  infrastructure). The default_tenant_id configuration determines the schema prefix.
  """

  alias ServiceRadar.Cluster.TenantSchemas

  @doc """
  Returns the configured default tenant ID for this instance.

  In single-tenant deployments, this is set via :serviceradar_core, :default_tenant_id
  configuration and represents the one tenant this instance serves.
  """
  def default_tenant_id do
    Application.get_env(:serviceradar_core, :default_tenant_id)
  end

  @doc """
  Returns the database schema name for the default tenant.

  Used for Ash queries that need explicit schema context.
  """
  def default_tenant_schema do
    case default_tenant_id() do
      nil -> nil
      "" -> nil
      tenant_id -> schema_for_tenant_id(tenant_id)
    end
  end

  @doc """
  Converts a tenant ID to its database schema name.

  Returns nil if tenant_id is nil or cannot be resolved.
  """
  def schema_for_tenant_id(nil), do: nil

  def schema_for_tenant_id(tenant_id) when is_binary(tenant_id) do
    try do
      TenantSchemas.schema_for_id(tenant_id)
    rescue
      ArgumentError -> nil
    end
  end
end
