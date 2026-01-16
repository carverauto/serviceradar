defmodule ServiceRadar.EventWriter.TenantContext do
  @moduledoc """
  Resolves tenant identity for EventWriter processing.

  Provides tenant slug and UUID resolution for event processing.
  The pipeline sets the tenant slug from NATS subject prefixes, and this
  module resolves it to the UUID for database operations.

  Note: Schema resolution is no longer needed since the database connection's
  search_path is set by CNPG credentials.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Cluster.TenantGuard
  alias ServiceRadar.Identity.Tenant

  require Ash.Query

  @doc """
  Returns the current tenant slug from process context.
  """
  @spec current_tenant() :: String.t() | atom() | nil
  def current_tenant do
    TenantGuard.get_process_tenant()
  end

  @doc """
  Returns the current tenant's UUID.

  Resolves the tenant slug to its UUID via database lookup.
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
    # In tenant-unaware architecture, look up tenant UUID from database
    actor = SystemActor.platform(:event_writer)

    case Tenant
         |> Ash.Query.filter(slug == ^slug)
         |> Ash.Query.limit(1)
         |> Ash.read(actor: actor) do
      {:ok, [tenant | _]} -> to_string(tenant.id)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
