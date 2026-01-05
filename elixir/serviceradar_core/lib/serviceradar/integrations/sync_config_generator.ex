defmodule ServiceRadar.Integrations.SyncConfigGenerator do
  @moduledoc """
  Builds sync service configuration payloads from IntegrationSource data.
  """

  require Logger
  require Ash.Query

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Integrations.{IntegrationSource, SyncService}

  @default_heartbeat_interval_sec 30
  @default_config_poll_interval_sec 300

  @spec get_config_if_changed(String.t(), String.t(), String.t()) ::
          :not_modified | {:ok, map()} | {:error, term()}
  def get_config_if_changed(component_id, tenant_id, config_version) do
    case generate_config(component_id, tenant_id) do
      {:ok, config} ->
        encoded = Jason.encode!(config)
        version = hash_config(config)

        if version == config_version do
          :not_modified
        else
          {:ok,
           %{
             config_version: version,
             config_timestamp: System.os_time(:second),
             heartbeat_interval_sec: @default_heartbeat_interval_sec,
             config_poll_interval_sec: @default_config_poll_interval_sec,
             config_json: encoded
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_config(component_id, tenant_id) do
    with {:ok, sync_service} <- fetch_sync_service(component_id),
         :ok <- validate_sync_service_scope(sync_service, tenant_id),
         {:ok, sources} <- load_sources(sync_service, tenant_id) do
      {:ok,
       %{
         "sync_service_id" => to_string(sync_service.id),
         "component_id" => sync_service.component_id,
         "scope" => scope_for(sync_service),
         "sources" => build_sources_payload(sources, sync_service.is_platform_sync)
       }}
    end
  end

  defp fetch_sync_service(component_id) do
    query =
      SyncService
      |> Ash.Query.for_read(:read, %{}, tenant: nil, authorize?: false)
      |> Ash.Query.filter(component_id == ^component_id)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, service} -> {:ok, service}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_sync_service_scope(sync_service, tenant_id) do
    cond do
      sync_service.is_platform_sync and sync_service.tenant_id == tenant_id ->
        :ok

      not sync_service.is_platform_sync and sync_service.tenant_id == tenant_id ->
        :ok

      sync_service.is_platform_sync ->
        Logger.warning(
          "Platform sync service tenant mismatch",
          sync_service_id: sync_service.id,
          tenant_id: tenant_id
        )

        {:error, :tenant_mismatch}

      true ->
        Logger.warning(
          "Sync service tenant mismatch",
          sync_service_id: sync_service.id,
          tenant_id: tenant_id
        )

        {:error, :tenant_mismatch}
    end
  end

  defp load_sources(sync_service, tenant_id) do
    query =
      IntegrationSource
      |> Ash.Query.for_read(:read, %{}, tenant: nil, authorize?: false)
      |> Ash.Query.filter(enabled == true and sync_service_id == ^sync_service.id)
      |> Ash.Query.load(:credentials)
      |> Ash.Query.sort(name: :asc)

    query =
      if sync_service.is_platform_sync do
        query
      else
        Ash.Query.filter(query, tenant_id == ^tenant_id)
      end

    case Ash.read(query, authorize?: false) do
      {:ok, sources} -> {:ok, sources}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_sources_payload(sources, platform?) do
    Enum.reduce(sources, %{}, fn source, acc ->
      tenant_slug = lookup_tenant_slug(to_string(source.tenant_id))
      source_key = build_source_key(source, tenant_slug, platform?)
      Map.put(acc, source_key, source_payload(source, tenant_slug))
    end)
  end

  defp build_source_key(source, tenant_slug, true) do
    tenant_prefix = tenant_slug || to_string(source.tenant_id)
    source_name = source.name || to_string(source.id)
    "#{tenant_prefix}/#{source_name}"
  end

  defp build_source_key(source, _tenant_slug, false) do
    source.name || to_string(source.id)
  end

  defp source_payload(source, tenant_slug) do
    credentials = normalize_credentials(source.credentials || %{})
    credentials = put_optional(credentials, "page_size", source.page_size)
    source_type = source.source_type && Atom.to_string(source.source_type)
    prefix = if source_type, do: "#{source_type}/", else: nil

    %{
      "type" => source_type,
      "endpoint" => source.endpoint,
      "prefix" => prefix,
      "credentials" => credentials,
      "queries" => source.queries,
      "poll_interval" => format_duration(source.poll_interval_seconds),
      "sweep_interval" => format_duration(source.sweep_interval_seconds),
      "agent_id" => source.agent_id,
      "poller_id" => source.poller_id,
      "partition" => source.partition,
      "network_blacklist" => source.network_blacklist,
      "custom_field" => first_custom_field(source.custom_fields),
      "batch_size" => get_setting(source.settings, "batch_size"),
      "insecure_skip_verify" => get_setting(source.settings, "insecure_skip_verify"),
      "tenant_id" => to_string(source.tenant_id),
      "tenant_slug" => tenant_slug,
      "sync_service_id" => source.sync_service_id && to_string(source.sync_service_id)
    }
    |> compact_map()
  end

  defp scope_for(%{is_platform_sync: true}), do: "platform"
  defp scope_for(_), do: "tenant"

  defp first_custom_field(fields) when is_list(fields) do
    case fields do
      [value | _] -> value
      _ -> nil
    end
  end

  defp first_custom_field(_), do: nil

  defp normalize_credentials(credentials) when is_map(credentials) do
    credentials
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new(fn {key, value} ->
      {to_string(key), to_string(value)}
    end)
  end

  defp normalize_credentials(_), do: %{}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map

  defp put_optional(map, key, value) do
    Map.put(map, key, to_string(value))
  end

  defp format_duration(seconds) when is_integer(seconds) do
    cond do
      rem(seconds, 3600) == 0 -> "#{div(seconds, 3600)}h"
      rem(seconds, 60) == 0 -> "#{div(seconds, 60)}m"
      true -> "#{seconds}s"
    end
  end

  defp format_duration(_), do: ""

  defp hash_config(config) do
    canonical =
      config
      |> canonicalize_for_hash()
      |> Jason.encode!()

    :crypto.hash(:sha256, canonical)
    |> Base.encode16(case: :lower)
  end

  defp canonicalize_for_hash(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> [to_string(key), canonicalize_for_hash(value)] end)
    |> Enum.sort_by(fn [key, _value] -> key end)
  end

  defp canonicalize_for_hash(list) when is_list(list) do
    Enum.map(list, &canonicalize_for_hash/1)
  end

  defp canonicalize_for_hash(other), do: other

  defp compact_map(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, %{} = value} -> map_size(value) == 0
      _ -> false
    end)
    |> Map.new()
  end

  defp lookup_tenant_slug(tenant_id) do
    case TenantRegistry.slug_for_tenant_id(tenant_id) do
      {:ok, slug} -> slug
      :error -> lookup_tenant_slug_from_db(tenant_id)
    end
  end

  defp lookup_tenant_slug_from_db(nil), do: nil

  defp lookup_tenant_slug_from_db(tenant_id) do
    case Tenant
         |> Ash.Query.filter(id == ^tenant_id)
         |> Ash.Query.limit(1)
         |> Ash.read(authorize?: false) do
      {:ok, [tenant | _]} -> to_string(tenant.slug)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp get_setting(nil, _key), do: nil

  defp get_setting(settings, key) when is_map(settings) do
    Map.get(settings, key) || Map.get(settings, String.to_atom(key))
  end

  defp get_setting(_, _key), do: nil

end
