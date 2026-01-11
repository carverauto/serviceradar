defmodule ServiceRadar.Oban.TenantOban do
  @moduledoc """
  Manages per-tenant Oban instances scoped to tenant schemas.
  """

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Oban.TenantSupervisor

  @registry ServiceRadar.LocalRegistry

  @spec ensure_tenant(term()) :: {:ok, Oban.name()} | {:error, term()}
  def ensure_tenant(tenant) do
    case TenantSchemas.schema_for_tenant(tenant) do
      nil -> {:error, :tenant_schema_not_found}
      schema -> ensure_schema(schema)
    end
  end

  @spec ensure_schema(String.t()) :: {:ok, Oban.name()} | {:error, term()}
  def ensure_schema(schema) when is_binary(schema) do
    name = name_for_schema(schema)

    case GenServer.whereis(name) do
      nil -> start_oban(schema, name)
      _pid -> {:ok, name}
    end
  end

  @spec name_for_schema(String.t()) :: Oban.name()
  def name_for_schema(schema) when is_binary(schema) do
    {:via, Registry, {@registry, {:tenant_oban, schema}}}
  end

  defp start_oban(schema, name) do
    case DynamicSupervisor.start_child(TenantSupervisor, {Oban, tenant_config(schema, name)}) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tenant_config(schema, name) do
    base = Application.get_env(:serviceradar_core, Oban, [])

    base
    |> Keyword.put(:name, name)
    |> Keyword.put(:prefix, schema)
    |> Keyword.update(:plugins, [], &filter_tenant_plugins/1)
  end

  defp filter_tenant_plugins(plugins) when is_list(plugins) do
    Enum.reject(plugins, fn
      Oban.Plugins.Cron -> true
      {Oban.Plugins.Cron, _opts} -> true
      Oban.Pro.Plugins.DynamicCron -> true
      {Oban.Pro.Plugins.DynamicCron, _opts} -> true
      _ -> false
    end)
  end
end
