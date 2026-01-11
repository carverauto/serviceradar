defmodule ServiceRadar.EventWriter.TenantContext do
  @moduledoc """
  Resolves tenant identity for EventWriter processing.

  Provides tenant slug, UUID, and schema resolution for event processing.
  The pipeline sets the tenant slug from NATS subject prefixes, and this
  module resolves it to the appropriate schema and UUID for database operations.
  """

  alias ServiceRadar.Cluster.TenantGuard
  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Cluster.TenantSchemas

  @doc """
  Returns the current tenant slug from process context.
  """
  @spec current_tenant() :: String.t() | atom() | nil
  def current_tenant do
    TenantGuard.get_process_tenant()
  end

  @doc """
  Returns the current tenant's database schema name.

  Resolves the tenant slug to its PostgreSQL schema (e.g., "tenant_acme_corp").
  """
  @spec current_schema() :: String.t() | nil
  def current_schema do
    case current_tenant() do
      nil -> nil
      slug when is_binary(slug) -> TenantSchemas.schema_for(slug)
      _ -> nil
    end
  end

  @doc """
  Returns the current tenant's UUID.

  Resolves the tenant slug to its UUID via TenantRegistry.
  """
  @spec current_tenant_id() :: String.t() | nil
  def current_tenant_id do
    case current_tenant() do
      nil -> nil
      slug when is_binary(slug) -> resolve_slug_to_uuid(slug)
      _ -> nil
    end
  end

  @doc """
  Resolves tenant_id (UUID) from message context.

  Returns the tenant UUID for storing in event records.
  """
  @spec resolve_tenant_id(map()) :: String.t() | nil
  def resolve_tenant_id(_message), do: current_tenant_id()

  @doc """
  Executes a function within a tenant context.

  Sets the tenant slug in the process dictionary for the duration of the function.
  """
  @spec with_tenant(String.t() | nil, (() -> term())) :: {:ok, term()} | {:error, :missing_tenant_id}
  def with_tenant(nil, _fun), do: {:error, :missing_tenant_id}

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

  defp resolve_slug_to_uuid(slug) do
    case TenantRegistry.tenant_id_for_slug(slug) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
