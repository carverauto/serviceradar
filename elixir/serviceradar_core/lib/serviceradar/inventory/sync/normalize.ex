defmodule ServiceRadar.Inventory.Sync.Normalize do
  @moduledoc """
  Update payload normalization: key access helpers, timestamps, metadata
  merging (inventory, sync_meta, SNMP fingerprints, boundary names, alias
  IP enrichment).
  """

  alias ServiceRadar.Identity.AliasPolicy
  alias ServiceRadar.Inventory.ActiveFingerprintPayload
  alias ServiceRadar.Inventory.DpiPayload
  alias ServiceRadar.Inventory.PassiveFingerprintPayload
  alias ServiceRadar.Inventory.Sync.FieldAliases

  require Logger

  @unknown_inventory_values ~w(unknown n/a na none null unspecified)

  def normalize_update(update) when is_map(update) do
    sync_meta = get_map(update, ["sync_meta", :sync_meta])

    metadata =
      update
      |> get_map(["metadata", :metadata])
      |> merge_top_level_inventory_metadata(update)
      |> merge_canonical_inventory_metadata()
      |> merge_sync_meta_metadata(sync_meta)
      |> merge_snmp_fingerprint_metadata(get_map(update, ["snmp_fingerprint", :snmp_fingerprint]))
      |> merge_boundary_names_metadata()
      |> PassiveFingerprintPayload.enrich_metadata()
      |> ActiveFingerprintPayload.enrich_metadata()
      |> DpiPayload.enrich_metadata()

    os =
      update
      |> get_map(["os", :os])
      |> PassiveFingerprintPayload.enrich_os(metadata)
      |> ActiveFingerprintPayload.enrich_os(metadata)

    %{
      device_id: get_string(update, ["device_id", :device_id]),
      agent_id: get_string(update, ["agent_id", :agent_id]),
      gateway_id: get_string(update, ["gateway_id", :gateway_id]),
      ip: get_string(update, ["ip", :ip]),
      mac: get_string(update, ["mac", :mac]),
      hostname: get_string(update, ["hostname", :hostname]),
      partition: get_string(update, ["partition", :partition]) || "default",
      metadata: metadata,
      tags: get_map(update, ["tags", :tags]),
      os: os,
      hw_info: get_map(update, ["hw_info", :hw_info]),
      network_interfaces: get_list(update, ["network_interfaces", :network_interfaces]),
      first_seen_time: parse_timestamp(get_value(update, ["first_seen_time", :first_seen_time])),
      last_seen_time: parse_timestamp(get_value(update, ["last_seen_time", :last_seen_time])),
      timestamp: parse_timestamp(get_value(update, ["timestamp", :timestamp])),
      is_available: get_bool(update, ["is_available", :is_available]),
      is_managed: get_bool(update, ["is_managed", :is_managed]),
      source: get_string(update, ["source", :source]) || "unknown",
      source_instance: get_string(update, ["source_instance", :source_instance]),
      facts: get_map(update, ["facts", :facts])
    }
  end

  def normalize_update(_update) do
    %{
      device_id: nil,
      agent_id: nil,
      gateway_id: nil,
      ip: nil,
      mac: nil,
      hostname: nil,
      partition: "default",
      metadata: %{},
      tags: %{},
      os: %{},
      hw_info: %{},
      network_interfaces: [],
      first_seen_time: nil,
      last_seen_time: nil,
      timestamp: nil,
      is_available: nil,
      is_managed: nil,
      source: "unknown",
      source_instance: nil,
      facts: %{}
    }
  end

  def parse_timestamp(nil), do: nil

  def parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.truncate(parsed, :second)
      _ -> nil
    end
  end

  def parse_timestamp(%DateTime{} = timestamp), do: DateTime.truncate(timestamp, :second)

  def parse_timestamp(_timestamp), do: nil

  def get_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} -> value
        _ -> nil
      end
    end)
  end

  def get_string(map, keys) do
    case get_value(map, keys) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  def get_map(map, keys) do
    case get_value(map, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  def get_list(map, keys) do
    case get_value(map, keys) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp merge_top_level_inventory_metadata(metadata, update) when is_map(metadata) do
    metadata
    |> maybe_put("type", get_string(update, ["type", :type, "device_type", :device_type]))
    |> maybe_put("device_type", get_string(update, ["type", :type, "device_type", :device_type]))
    |> maybe_put(
      "vendor_name",
      get_string(update, ["vendor_name", :vendor_name, "vendor", :vendor])
    )
    |> maybe_put("model", get_string(update, ["model", :model]))
    |> maybe_put("risk_score", get_int_string(update, ["risk_score", :risk_score]))
  end

  defp merge_top_level_inventory_metadata(_metadata, _update), do: %{}

  defp merge_canonical_inventory_metadata(metadata) when is_map(metadata) do
    device_type = first_meaningful_string(metadata, FieldAliases.device_type_aliases())
    vendor_name = first_meaningful_string(metadata, FieldAliases.vendor_aliases())
    model = first_meaningful_string(metadata, FieldAliases.model_aliases())

    metadata
    |> maybe_put_preferred("type", device_type)
    |> maybe_put_preferred("device_type", device_type)
    |> maybe_put_preferred("vendor_name", vendor_name)
    |> maybe_put_preferred("model", model)
  end

  defp merge_canonical_inventory_metadata(_metadata), do: %{}

  defp merge_boundary_names_metadata(metadata) when is_map(metadata) do
    cond do
      get_string(metadata, ["boundary_names"]) not in [nil, ""] ->
        metadata

      (names = boundary_names_from_metadata(metadata)) != [] ->
        Map.put(metadata, "boundary_names", Enum.join(names, ","))

      true ->
        metadata
    end
  end

  defp merge_boundary_names_metadata(_metadata), do: %{}

  defp boundary_names_from_metadata(metadata) do
    metadata
    |> get_value(["boundaries", :boundaries])
    |> decode_json_metadata()
    |> extract_boundary_names()
    |> Enum.uniq()
  end

  defp decode_json_metadata(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decode_json_metadata(value), do: value

  defp extract_boundary_names(values) when is_list(values) do
    Enum.flat_map(values, &extract_boundary_names/1)
  end

  defp extract_boundary_names(%{"name" => name}) when is_binary(name) do
    name = String.trim(name)
    if name == "", do: [], else: [name]
  end

  defp extract_boundary_names(%{name: name}) when is_binary(name) do
    name = String.trim(name)
    if name == "", do: [], else: [name]
  end

  defp extract_boundary_names(_value), do: []

  defp get_int_string(map, keys) do
    case get_value(map, keys) do
      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        value |> trunc() |> Integer.to_string()

      value when is_binary(value) ->
        if(String.trim(value) == "", do: nil, else: String.trim(value))

      _ ->
        nil
    end
  end

  defp merge_sync_meta_metadata(metadata, sync_meta)
       when is_map(metadata) and is_map(sync_meta) and map_size(sync_meta) > 0 do
    metadata
    |> maybe_put_sync_meta(
      "sync_service_id",
      sync_meta["sync_service_id"] || sync_meta[:sync_service_id]
    )
    |> maybe_put_sync_meta("sync_run_id", sync_meta["sync_run_id"] || sync_meta[:sync_run_id])
    |> maybe_put_sync_meta(
      "sync_total_devices",
      sync_meta["total_devices"] || sync_meta[:total_devices]
    )
  end

  defp merge_sync_meta_metadata(metadata, _sync_meta) when is_map(metadata), do: metadata

  defp merge_snmp_fingerprint_metadata(metadata, snmp_fingerprint)
       when is_map(metadata) and map_size(snmp_fingerprint) == 0, do: metadata

  defp merge_snmp_fingerprint_metadata(metadata, snmp_fingerprint) when is_map(metadata) do
    system = map_get_any(snmp_fingerprint, ["system", :system])
    bridge = map_get_any(snmp_fingerprint, ["bridge", :bridge])

    metadata
    |> maybe_put("sys_name", map_get_string_any(system, ["sys_name", :sys_name]))
    |> maybe_put("snmp_name", map_get_string_any(system, ["sys_name", :sys_name]))
    |> maybe_put("sys_descr", map_get_string_any(system, ["sys_descr", :sys_descr]))
    |> maybe_put("snmp_description", map_get_string_any(system, ["sys_descr", :sys_descr]))
    |> maybe_put("sys_object_id", map_get_string_any(system, ["sys_object_id", :sys_object_id]))
    |> maybe_put("sys_contact", map_get_string_any(system, ["sys_contact", :sys_contact]))
    |> maybe_put("sys_owner", map_get_string_any(system, ["sys_contact", :sys_contact]))
    |> maybe_put("snmp_owner", map_get_string_any(system, ["sys_contact", :sys_contact]))
    |> maybe_put("sys_location", map_get_string_any(system, ["sys_location", :sys_location]))
    |> maybe_put("snmp_location", map_get_string_any(system, ["sys_location", :sys_location]))
    |> maybe_put(
      "ip_forwarding",
      map_get_int_string_any(system, ["ip_forwarding", :ip_forwarding])
    )
    |> maybe_put(
      "bridge_base_mac",
      map_get_string_any(bridge, ["bridge_base_mac", :bridge_base_mac])
    )
    |> maybe_put(
      "bridge_port_count",
      map_get_int_string_any(bridge, ["bridge_port_count", :bridge_port_count])
    )
    |> maybe_put(
      "stp_forwarding_port_count",
      map_get_int_string_any(bridge, ["stp_forwarding_port_count", :stp_forwarding_port_count])
    )
    |> maybe_put("snmp_fingerprint", snmp_fingerprint)
  end

  def map_get_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case map do
        %{^key => value} -> value
        _ -> nil
      end
    end)
  end

  def map_get_any(_map, _keys), do: nil

  def map_get_string_any(map, keys) do
    case map_get_any(map, keys) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  def first_meaningful_string(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      map
      |> map_get_any([key])
      |> meaningful_string()
    end)
  end

  def first_meaningful_string(_map, _keys), do: nil

  defp meaningful_string(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.downcase(value) in @unknown_inventory_values -> nil
      true -> value
    end
  end

  defp meaningful_string(nil), do: nil

  defp meaningful_string(value) when is_atom(value) and not is_boolean(value),
    do: value |> Atom.to_string() |> meaningful_string()

  defp meaningful_string(value) when is_integer(value),
    do: value |> Integer.to_string() |> meaningful_string()

  defp meaningful_string(value) when is_float(value),
    do: value |> Float.to_string() |> meaningful_string()

  defp meaningful_string(_value), do: nil

  defp maybe_put_preferred(metadata, _key, nil), do: metadata

  defp maybe_put_preferred(metadata, key, value) do
    case metadata |> Map.get(key) |> meaningful_string() do
      nil -> Map.put(metadata, key, value)
      _existing -> metadata
    end
  end

  def map_get_int_string_any(map, keys) do
    case map_get_any(map, keys) do
      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_binary(value) ->
        if(String.trim(value) == "", do: nil, else: String.trim(value))

      _ ->
        nil
    end
  end

  def enrich_alias_metadata(update) do
    metadata = update.metadata || %{}
    alias_ips = alias_ips_from_metadata(metadata)

    if alias_ips == [] do
      update
    else
      timestamp = update.timestamp || DateTime.utc_now()
      timestamp = DateTime.truncate(timestamp, :second)
      ts_string = DateTime.to_iso8601(timestamp)

      alias_ips =
        alias_ips
        |> maybe_add_alias_ip(update.ip)
        |> Enum.filter(&AliasPolicy.valid_alias_ip?/1)
        |> Enum.uniq()

      if alias_ips == [] do
        update
      else
        last_seen_ip =
          if AliasPolicy.valid_alias_ip?(update.ip), do: update.ip

        metadata =
          metadata
          |> Map.put("_alias_last_seen_at", ts_string)
          |> maybe_put("_alias_last_seen_ip", last_seen_ip)
          |> add_alias_ip_keys(alias_ips, ts_string)

        %{update | metadata: metadata, timestamp: timestamp}
      end
    end
  end

  def alias_ips_from_metadata(metadata) do
    metadata
    |> Map.keys()
    |> Enum.flat_map(fn key ->
      cond do
        String.starts_with?(key, "ip_alias:") ->
          [String.trim(String.replace_prefix(key, "ip_alias:", ""))]

        String.starts_with?(key, "alt_ip:") ->
          [String.trim(String.replace_prefix(key, "alt_ip:", ""))]

        true ->
          []
      end
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_add_alias_ip(ips, nil), do: ips
  defp maybe_add_alias_ip(ips, ""), do: ips
  defp maybe_add_alias_ip(ips, ip), do: ips ++ [ip]

  defp add_alias_ip_keys(metadata, ips, ts_string) do
    Enum.reduce(ips, metadata, fn ip, acc ->
      Map.put(acc, "ip_alias:#{ip}", ts_string)
    end)
  end

  def maybe_put(metadata, _key, nil), do: metadata
  def maybe_put(metadata, _key, ""), do: metadata
  def maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  def get_bool(map, keys) do
    # Map.get/find_value treat `false` as missing. Look up the key explicitly
    # so unmanaged inventory (`is_managed: false`) is not coerced to nil.
    case Enum.find(keys, &Map.has_key?(map, &1)) do
      nil ->
        nil

      key ->
        case Map.get(map, key) do
          nil -> nil
          "" -> nil
          true -> true
          false -> false
          value when is_integer(value) -> value != 0
          value when is_binary(value) -> parse_bool_string(value)
          _ -> nil
        end
    end
  end

  defp parse_bool_string(value) do
    case String.downcase(String.trim(value)) do
      value when value in ["true", "t", "1", "yes", "y"] -> true
      value when value in ["false", "f", "0", "no", "n"] -> false
      _ -> nil
    end
  end

  defp maybe_put_sync_meta(metadata, _key, nil), do: metadata
  defp maybe_put_sync_meta(metadata, key, value), do: Map.put_new(metadata, key, value)
end
