defmodule ServiceRadarWebNGWeb.TenantResolver do
  @moduledoc false

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Identity.Tenant

  require Ash.Query

  @system_actor %{
    id: "00000000-0000-0000-0000-000000000000",
    email: "system@serviceradar.local",
    role: :super_admin
  }

  def system_actor, do: @system_actor

  def tenant_base_domain do
    Application.get_env(:serviceradar_web_ng, :tenant_base_domain)
  end

  def default_tenant_id do
    case Application.get_env(:serviceradar_core, :default_tenant_id) do
      nil -> platform_tenant_id()
      "" -> platform_tenant_id()
      "00000000-0000-0000-0000-000000000000" -> platform_tenant_id()
      tenant_id -> tenant_id
    end
  end

  def default_tenant_schema do
    default_tenant_id()
    |> schema_for_tenant_id()
  end

  def schema_for_tenant_id(nil), do: nil

  def schema_for_tenant_id(tenant_id) when is_binary(tenant_id) do
    schema =
      try do
        TenantSchemas.schema_for_id(tenant_id)
      rescue
        ArgumentError -> nil
      end

    schema ||
      case fetch_tenant_by_id(tenant_id) do
        {:ok, tenant} -> TenantSchemas.schema_for_tenant(tenant)
        :error -> nil
      end
  end

  def resolve_host_tenant(host) when is_binary(host) do
    with base_domain when is_binary(base_domain) <- normalize_domain(tenant_base_domain()),
         true <- host != base_domain,
         slug when is_binary(slug) <- slug_from_host(host, base_domain),
         {:ok, tenant} <- fetch_tenant_by_slug(slug) do
      {:ok, tenant}
    else
      _ -> :error
    end
  end

  def multi_tenant? do
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(2)
    |> Ash.read(actor: system_actor())
    |> case do
      {:ok, %Ash.Page.Keyset{results: tenants}} -> length(tenants) > 1
      {:ok, %Ash.Page.Offset{results: tenants}} -> length(tenants) > 1
      {:ok, tenants} when is_list(tenants) -> length(tenants) > 1
      {:error, _} -> false
    end
  end

  def fetch_tenant_by_slug(slug) when is_binary(slug) do
    Tenant
    |> Ash.Query.for_read(:by_slug, %{slug: slug})
    |> Ash.Query.select([:id, :slug, :is_platform_tenant])
    |> Ash.read_one(actor: system_actor())
    |> case do
      {:ok, %Tenant{} = tenant} -> {:ok, tenant}
      {:ok, nil} -> :error
      {:error, _} -> :error
    end
  end

  def fetch_tenant_by_id(tenant_id) when is_binary(tenant_id) do
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: tenant_id)
    |> Ash.Query.select([:id, :slug, :is_platform_tenant])
    |> Ash.read_one(actor: system_actor())
    |> case do
      {:ok, %Tenant{} = tenant} -> {:ok, tenant}
      {:ok, nil} -> :error
      {:error, _} -> :error
    end
  end

  defp platform_tenant_id do
    Tenant
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(is_platform_tenant: true)
    |> Ash.Query.select([:id])
    |> Ash.read_one(actor: system_actor())
    |> case do
      {:ok, %Tenant{id: id}} -> id
      _ -> nil
    end
  end

  defp normalize_domain(nil), do: nil

  defp normalize_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp slug_from_host(host, base_domain) do
    suffix = "." <> base_domain

    host = String.downcase(host)

    if String.ends_with?(host, suffix) do
      String.trim_trailing(host, suffix)
    else
      nil
    end
  end
end
