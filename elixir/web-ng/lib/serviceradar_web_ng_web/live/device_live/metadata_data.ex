defmodule ServiceRadarWebNGWeb.DeviceLive.MetadataData do
  @moduledoc false

  use ServiceRadarWebNGWeb, :verified_routes

  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadarWebNGWeb.DeviceLive.VisibilityComponents

  def row_metadata(row) when is_map(row) do
    case Map.get(row, "metadata") || Map.get(row, :metadata) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  def row_metadata(_row), do: %{}

  def enrich_integration_metadata(nil, _scope), do: nil

  def enrich_integration_metadata(row, scope) when is_map(row) do
    metadata = row_metadata(row)
    sync_service_id = Map.get(metadata, "sync_service_id")

    metadata =
      metadata
      |> maybe_put_sync_service_path(sync_service_id)
      |> maybe_put_armis_device_url(sync_service_id, scope)

    Map.put(row, "metadata", metadata)
  end

  def value(row, key) when is_map(row) and is_binary(key) do
    row
    |> row_metadata()
    |> Map.get(key)
  end

  def value(_row, _key), do: nil

  defp maybe_put_sync_service_path(metadata, sync_service_id)
       when is_map(metadata) and is_binary(sync_service_id) and sync_service_id != "" do
    Map.put(metadata, "sync_service_path", ~p"/settings/networks/integrations/#{sync_service_id}")
  end

  defp maybe_put_sync_service_path(metadata, _sync_service_id), do: metadata

  defp maybe_put_armis_device_url(metadata, sync_service_id, scope)
       when is_map(metadata) and is_binary(sync_service_id) and sync_service_id != "" do
    armis_id =
      first_metadata_value(metadata, ["armis_device_id", "source_device_id", "integration_id"])

    if VisibilityComponents.metadata_lookup(metadata, "integration_type") == "armis" and present?(armis_id) do
      case IntegrationSource.get_by_id(sync_service_id, scope: scope) do
        {:ok, %IntegrationSource{endpoint: endpoint}} ->
          Map.put(metadata, "armis_device_url", armis_device_url(endpoint, armis_id))

        _ ->
          metadata
      end
    else
      metadata
    end
  rescue
    _ -> metadata
  end

  defp maybe_put_armis_device_url(metadata, _sync_service_id, _scope), do: metadata

  defp armis_device_url(endpoint, armis_id) when is_binary(endpoint) do
    endpoint
    |> String.trim()
    |> String.trim_trailing("/")
    |> Kernel.<>("/inventory/devices/#{armis_id}/")
  end

  defp armis_device_url(_endpoint, _armis_id), do: nil

  defp first_metadata_value(metadata, keys) when is_map(metadata) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(metadata, key) do
        value when value in [nil, ""] -> nil
        value -> value
      end
    end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
