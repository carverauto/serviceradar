defmodule ServiceRadar.Inventory.DeviceDiscoveryIngestor do
  @moduledoc """
  Ingests plugin-emitted device discovery/enrichment records into inventory.

  Plugins emit `serviceradar.device_discovery.v1` envelopes inside the normal
  `serviceradar.plugin_result.v1` payload. This module translates those records
  into the existing SyncIngestor update contract so discovered devices reconcile
  into `platform.ocsf_devices` and device identifiers.
  """

  alias ServiceRadar.Inventory.SyncIngestor

  require Logger

  @schema "serviceradar.device_discovery.v1"

  @spec ingest(map() | list(), map(), keyword()) :: :ok | {:error, term()}
  def ingest(payload, status, opts \\ [])

  def ingest(payload, status, opts) when is_list(payload) do
    payload
    |> Enum.find(&is_map/1)
    |> case do
      nil -> :ok
      entry -> ingest(entry, status, opts)
    end
  end

  def ingest(payload, status, opts) when is_map(payload) do
    actor = Keyword.fetch!(opts, :actor)
    device_sync = Keyword.get(opts, :device_sync, &sync_device_inventory/2)

    updates =
      payload
      |> discovery_envelopes()
      |> Enum.flat_map(&device_updates(&1, payload, status))

    case updates do
      [] -> :ok
      updates -> device_sync.(updates, %{actor: actor})
    end
  rescue
    e ->
      Logger.warning("Plugin device discovery ingest failed: #{Exception.message(e)}")
      {:error, e}
  end

  def ingest(_payload, _status, _opts), do: :ok

  defp sync_device_inventory(updates, context) when is_list(updates) do
    SyncIngestor.ingest_updates(updates, actor: context.actor)
  end

  defp discovery_envelopes(payload) do
    direct =
      if discovery_envelope?(payload) do
        [payload]
      else
        []
      end

    nested =
      payload
      |> list_value(["device_discovery", "deviceDiscovery", "discoveries"])
      |> Enum.filter(&discovery_envelope?/1)

    direct ++ nested
  end

  defp discovery_envelope?(value) when is_map(value) do
    string_value(value, ["schema"]) == @schema
  end

  defp discovery_envelope?(_value), do: false

  defp device_updates(envelope, payload, status) do
    envelope
    |> list_value(["devices", "assets"])
    |> Enum.map(&device_update(&1, envelope, payload, status))
    |> Enum.reject(&is_nil/1)
  end

  defp device_update(device, envelope, payload, status) when is_map(device) do
    metadata = device_metadata(device, envelope, payload)

    update = %{
      "device_id" => string_value(device, ["device_id", "deviceId", "uid"]),
      "ip" => string_value(device, ["ip", "ip_address", "ipAddress"]),
      "mac" => string_value(device, ["mac", "mac_address", "macAddress"]),
      "hostname" => string_value(device, ["hostname", "name", "host"]),
      "partition" => partition_value(status),
      "source" =>
        string_value(envelope, ["source"]) ||
          string_value(payload, ["source"]) ||
          "plugin_device_discovery",
      "is_available" => bool_value(device, ["is_available", "isAvailable"]),
      "metadata" => metadata,
      "tags" => device_tags(device)
    }

    if strong_enough?(update) do
      update
    end
  end

  defp device_update(_device, _envelope, _payload, _status), do: nil

  defp strong_enough?(update) do
    present?(update["device_id"]) or present?(update["ip"]) or present?(update["mac"]) or
      present?(get_in(update, ["metadata", "integration_id"]))
  end

  defp device_metadata(device, envelope, payload) do
    location = map_value(device, ["location"])
    base = stringify_map(map_value(device, ["metadata"]) || %{})

    base
    |> maybe_put_new("integration_type", "plugin_device_discovery")
    |> maybe_put_new("integration_id", integration_id(device, envelope))
    |> maybe_put("plugin_discovery_schema", @schema)
    |> maybe_put("plugin_discovery_source", string_value(envelope, ["source"]))
    |> maybe_put("collection_id", string_value(envelope, ["collection_id", "collectionId"]))
    |> maybe_put("reference_hash", string_value(envelope, ["reference_hash", "referenceHash"]))
    |> maybe_put("vendor_name", string_value(device, ["vendor_name", "vendorName", "vendor"]))
    |> maybe_put("model", string_value(device, ["model"]))
    |> maybe_put(
      "serial_number",
      string_value(device, ["serial", "serial_number", "serialNumber"])
    )
    |> maybe_put("device_type", string_value(device, ["type", "device_type", "deviceType"]))
    |> maybe_put("device_role", string_value(device, ["role", "device_role", "deviceRole"]))
    |> maybe_put("status", string_value(device, ["status"]))
    |> maybe_put("site_code", string_value(location, ["site_code", "siteCode", "iata"]))
    |> maybe_put("site_name", string_value(location, ["site_name", "siteName", "name"]))
    |> maybe_put("latitude", number_value(location, ["latitude", "lat"]))
    |> maybe_put("longitude", number_value(location, ["longitude", "lon", "lng"]))
    |> maybe_put("plugin_result_summary", string_value(payload, ["summary"]))
  end

  defp integration_id(device, envelope) do
    metadata = map_value(device, ["metadata"]) || %{}

    string_value(metadata, ["integration_id", "integrationId"]) ||
      string_value(device, ["integration_id", "integrationId"]) ||
      prefixed_identifier(envelope, device)
  end

  defp prefixed_identifier(envelope, device) do
    source = string_value(envelope, ["source"]) || "plugin"
    kind = string_value(device, ["type", "kind", "role"]) || "device"

    value =
      first_present([
        string_value(device, ["serial", "serial_number", "serialNumber"]),
        string_value(device, ["mac", "mac_address", "macAddress"]),
        string_value(device, ["hostname", "name", "host"])
      ])

    if present?(value), do: "#{source}:#{kind}:#{value}"
  end

  defp device_tags(device) do
    device
    |> map_value(["labels", "tags"])
    |> stringify_map()
  end

  defp partition_value(status) do
    case status[:partition] || status["partition"] do
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end

  defp list_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      value when is_list(value) -> Enum.filter(value, &is_map/1)
      _ -> []
    end
  end

  defp list_value(_map, _keys), do: []

  defp map_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp map_value(_map, _keys), do: nil

  defp string_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      nil ->
        nil

      value when is_binary(value) ->
        value |> String.trim() |> blank_to_nil()

      value when is_atom(value) ->
        value |> Atom.to_string() |> String.trim() |> blank_to_nil()

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        Float.to_string(value)

      _ ->
        nil
    end
  end

  defp string_value(_map, _keys), do: nil

  defp bool_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      value when is_boolean(value) ->
        value

      value when is_binary(value) ->
        String.downcase(String.trim(value)) in ["true", "up", "ok", "online"]

      _ ->
        nil
    end
  end

  defp bool_value(_map, _keys), do: nil

  defp number_value(map, keys) when is_map(map) do
    case value_for(map, keys) do
      value when is_integer(value) ->
        value / 1

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {parsed, _rest} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp number_value(_map, _keys), do: nil

  defp value_for(map, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || Map.get(map, to_string(key))
    end)
  end

  defp stringify_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp stringify_map(_map), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, _key, ""), do: map
  defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
