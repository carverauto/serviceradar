defmodule ServiceRadarWebNGWeb.TenantResolver do
  @moduledoc """
  Simplified tenant resolver for single-tenant instance deployments.

  This is a tenant instance UI - each instance serves ONE tenant. The tenant
  is implicit from the PostgreSQL search_path set by infrastructure.

  This module provides the default tenant schema configuration for Ash context.
  """

  @doc """
  Returns the configured default tenant schema name for this instance, if set.

  Used by Ash for setting tenant context. Returns nil if not configured,
  which means Ash will use the default schema (typically 'public' or the
  PostgreSQL search_path set by infrastructure).
  """
  def default_tenant_schema do
    Application.get_env(:serviceradar_web_ng, :default_tenant_schema)
  end
end
