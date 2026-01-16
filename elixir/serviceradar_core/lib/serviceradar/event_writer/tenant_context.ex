defmodule ServiceRadar.EventWriter.TenantContext do
  @moduledoc """
  Provides tenant context for EventWriter processing.

  This module manages process-level tenant context for logging and telemetry.
  The DB connection's search_path determines the schema - no UUID resolution needed.

  The pipeline sets the tenant slug from NATS subject prefixes for observability,
  but all database operations rely on the connection's search_path for tenant isolation.
  """

  alias ServiceRadar.Cluster.TenantGuard

  @doc """
  Returns the current tenant slug from process context.

  Used for logging and telemetry metadata only.
  DB connection's search_path determines the schema for queries.
  """
  @spec current_tenant() :: String.t() | atom() | nil
  def current_tenant do
    TenantGuard.get_process_tenant()
  end

  @doc """
  Executes a function within a tenant context.

  Sets the tenant slug in the process dictionary for the duration of the function.
  This is used for logging and telemetry - the DB connection's search_path
  determines the actual schema for database operations.
  """
  @spec with_tenant(String.t() | nil, (() -> term())) :: {:ok, term()} | {:error, :missing_tenant}
  def with_tenant(nil, _fun), do: {:error, :missing_tenant}

  def with_tenant(tenant_slug, fun) when is_binary(tenant_slug) do
    previous = current_tenant()
    TenantGuard.set_process_tenant(tenant_slug)

    try do
      {:ok, fun.()}
    after
      restore_tenant(previous)
    end
  end

  defp restore_tenant(nil), do: Process.delete(:serviceradar_tenant)
  defp restore_tenant(tenant_slug), do: TenantGuard.set_process_tenant(tenant_slug)
end
