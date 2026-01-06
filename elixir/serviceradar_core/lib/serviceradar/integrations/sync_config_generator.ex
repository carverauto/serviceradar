defmodule ServiceRadar.Integrations.SyncConfigGenerator do
  @moduledoc """
  Builds sync configuration payloads for agents from IntegrationSource data.
  """

  require Ash.Query

  alias ServiceRadar.Cluster.TenantRegistry
  alias ServiceRadar.Identity.Tenant
  alias ServiceRadar.Integrations.IntegrationSource

  @default_heartbeat_interval_sec 30
  @default_config_poll_interval_sec 300

  @spec get_config_if_changed(String.t(), String.t(), String.t()) ::
          :not_modified | {:ok, map()} | {:error, term()}
  def get_config_if_changed(agent_id, tenant_id, config_version) do
    case build_payload(agent_id, tenant_id) do
      {:ok, payload} ->
        encoded = Jason.encode!(payload)
        version = hash_config(payload)

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

  @spec build_payload(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def build_payload(agent_id, tenant_id) do
    with {:ok, sources} <- load_sources(agent_id, tenant_id) do
      {:ok,
       %{
         "agent_id" => agent_id,
         "tenant_id" => tenant_id,
         "sources" => build_sources_payload(sources)
       }}
    end
  end

  defp load_sources(agent_id, tenant_id) do
    query =
      IntegrationSource
      |> Ash.Query.for_read(:read, %{}, tenant: tenant_id, authorize?: false)
      |> Ash.Query.filter(enabled == true and agent_id == ^agent_id)
      |> Ash.Query.load(:credentials)
      |> Ash.Query.sort(name: :asc)

    case Ash.read(query, authorize?: false) do
      {:ok, sources} -> {:ok, sources}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_sources_payload(sources) do
    Enum.reduce(sources, %{}, fn source, acc ->
      tenant_slug = lookup_tenant_slug(to_string(source.tenant_id))
      source_key = source.name || to_string(source.id)
      Map.put(acc, source_key, source_payload(source, tenant_slug))
    end)
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
      "gateway_id" => source.gateway_id,
      "partition" => source.partition,
      "network_blacklist" => source.network_blacklist,
      "custom_field" => first_custom_field(source.custom_fields),
      "batch_size" => get_setting(source.settings, "batch_size"),
      "insecure_skip_verify" => get_setting(source.settings, "insecure_skip_verify"),
      "tenant_id" => to_string(source.tenant_id),
      "tenant_slug" => tenant_slug
    }
    |> compact_map()
  end

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
