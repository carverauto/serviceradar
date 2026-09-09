defmodule ServiceRadar.Inventory.Identity.Ids do
  @moduledoc """
  Strong-identifier extraction from device updates, identifier priority,
  and deterministic device-UID generation.

  This is the integration-agnostic identity vocabulary: any source
  (sync integrations, mapper, hypervisor enrichment, wifi, camera)
  produces a device update; this module turns it into the normalized
  identifier set DIRE resolves on.
  """

  import Bitwise

  alias ServiceRadar.Inventory.Identity.HardwareSerial
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.IntegrationIdentity

  require Logger

  @identifier_priority [
    :agent_id,
    :armis_device_id,
    :integration_id,
    :netbox_device_id,
    :hardware_serial,
    :mac
  ]

  # Every reader (`ids_get/2`, `ids_get_string/2`, `ids_get_partition/1`,
  # `generate_deterministic_device_id/1`) is `Map.get`-based with a default,
  # so callers routinely pass partial maps (e.g. `%{integration_id: id,
  # partition: partition}` in remediation decisions). All keys are therefore
  # optional in the type; `extract_strong_identifiers/1` still returns the
  # full shape.
  @type strong_identifiers :: %{
          optional(:agent_id) => String.t() | nil,
          optional(:armis_id) => String.t() | nil,
          optional(:integration_id) => String.t() | nil,
          optional(:netbox_id) => String.t() | nil,
          optional(:hardware_serial) => String.t() | nil,
          optional(:mac) => String.t() | nil,
          optional(:macs) => [String.t()],
          optional(:legacy_mac) => String.t() | nil,
          optional(:legacy_integration_ids) => [String.t()],
          optional(:ip) => String.t() | nil,
          optional(:partition) => String.t() | nil
        }

  @type device_update :: %{
          device_id: String.t() | nil,
          ip: String.t() | nil,
          mac: String.t() | nil,
          partition: String.t() | nil,
          metadata: map() | nil
        }

  @doc "Identifier types in priority order (lower index = higher priority)."
  def identifier_priority, do: @identifier_priority

  @doc """
  Extract strong identifiers from a device update.
  """
  @spec extract_strong_identifiers(device_update()) :: strong_identifiers()
  def extract_strong_identifiers(update) do
    metadata = update[:metadata] || %{}
    partition = identifier_partition(update, metadata)
    raw_mac = update[:mac]
    macs = extract_mac_values(update, metadata)
    integration_id = get_integration_id(metadata)
    legacy_integration_ids = get_legacy_integration_ids(metadata, integration_id)

    emit_rejected_mac_telemetry(raw_mac, macs, update)

    %{
      # agent_id is typically carried in metadata for inventory updates, but some
      # producers (ex: mapper results) may emit it at the top-level.
      agent_id: get_trimmed(metadata, "agent_id") || get_agent_id_from_update(update),
      armis_id: get_armis_id(metadata),
      integration_id: integration_id,
      netbox_id: get_trimmed(metadata, "netbox_device_id"),
      hardware_serial: HardwareSerial.from_update(update),
      mac: List.first(macs),
      macs: macs,
      legacy_mac: legacy_mac_blob(raw_mac),
      legacy_integration_ids: legacy_integration_ids,
      ip: String.trim(update[:ip] || ""),
      partition: partition
    }
  end

  # Gather atomic MAC values from the primary mac field plus any multi-value
  # list the producer supplied (top-level or metadata, list or delimited string).
  defp extract_mac_values(update, metadata) do
    extra =
      get_mac_list_field(update[:mac_addresses]) ||
        get_mac_list_field(update["mac_addresses"]) ||
        get_mac_list_field(metadata["mac_addresses"]) ||
        []

    Enum.uniq(Mac.normalize_mac_list(update[:mac]) ++ extra ++ alt_macs_from_metadata(metadata))
  end

  defp alt_macs_from_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.flat_map(fn {key, _value} ->
      key = to_string(key)

      if String.starts_with?(key, "alt_mac:") do
        Mac.normalize_mac_list(String.trim_leading(key, "alt_mac:"))
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  defp alt_macs_from_metadata(_), do: []

  defp get_mac_list_field(value) when is_list(value) do
    value
    |> Enum.flat_map(&Mac.normalize_mac_list/1)
    |> Enum.uniq()
  end

  defp get_mac_list_field(value) when is_binary(value), do: Mac.normalize_mac_list(value)
  defp get_mac_list_field(_), do: nil

  # Legacy identifier rows were written as the whole separator-stripped field
  # (including comma-joined multi-MAC blobs). Keep that value available as a
  # lookup-only bridge so existing devices resolve until remediation purges
  # the blob rows. Never registered as a new identifier.
  defp legacy_mac_blob(raw_mac) when is_binary(raw_mac) do
    blob =
      raw_mac
      |> String.trim()
      |> String.upcase()
      |> String.replace(":", "")
      |> String.replace("-", "")
      |> String.replace(".", "")

    case blob do
      "" -> nil
      blob -> if String.contains?(blob, ","), do: blob
    end
  end

  defp legacy_mac_blob(_), do: nil

  defp emit_rejected_mac_telemetry(raw_mac, macs, update) when is_binary(raw_mac) do
    if String.trim(raw_mac) != "" and macs == [] do
      :telemetry.execute(
        [:serviceradar, :identity_reconciler, :identifier, :rejected],
        %{count: 1},
        %{identifier_type: :mac, source: update[:source] || "unknown"}
      )
    end

    :ok
  end

  defp emit_rejected_mac_telemetry(_raw_mac, _macs, _update), do: :ok

  defp get_agent_id_from_update(update) when is_map(update) do
    case update do
      %{agent_id: value} when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      %{"agent_id" => value} when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      _ -> nil
    end
  end

  defp get_agent_id_from_update(_update), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Lookup-only bridge values for prior integration_id format generations
  # (e.g. proxmox name-keyed / MAC-keyed ids). Never registered as identifiers.
  defp get_legacy_integration_ids(metadata, canonical_integration_id) when is_map(metadata) do
    explicit =
      case metadata["legacy_integration_ids"] do
        list when is_list(list) ->
          list
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        _ ->
          []
      end

    Enum.uniq(explicit ++ raw_integration_bridge(metadata, canonical_integration_id))
  end

  defp get_legacy_integration_ids(_metadata, _canonical_integration_id), do: []

  defp raw_integration_bridge(metadata, canonical_integration_id) do
    raw = get_trimmed(metadata, "integration_id")

    if canonical_integration_id in [nil, raw] or raw in [nil, ""] do
      []
    else
      [raw]
    end
  end

  defp get_integration_id(metadata) when is_map(metadata) do
    raw = ids_get(%{integration_id: get_trimmed(metadata, "integration_id")}, :integration_id)
    candidate = source_scoped_integration_id(metadata, raw)

    if is_binary(candidate) and not Regex.match?(~r/\A[0-9]+\z/, candidate), do: candidate
  end

  defp get_integration_id(_metadata), do: nil

  defp source_scoped_integration_id(_metadata, nil), do: nil

  defp source_scoped_integration_id(metadata, raw) do
    integration_type = get_trimmed(metadata, "integration_type") || "integration"
    source_id = get_trimmed(metadata, "sync_service_id")

    cond do
      # These drivers own their persisted identity format. Synthesizing another
      # scope here would split driver-minted identities from existing rows.
      String.downcase(integration_type) in ["armis", "netbox"] ->
        raw

      source_id in [nil, ""] ->
        raw

      source_scoped?(raw, integration_type, source_id) ->
        raw

      self_scoped?(raw, integration_type) ->
        raw

      true ->
        "#{integration_type}:source:#{source_id}:#{raw}"
    end
  end

  defp source_scoped?(value, integration_type, source_id) do
    String.starts_with?(value, "#{integration_type}:source:#{source_id}:")
  end

  defp self_scoped?(value, integration_type) do
    String.starts_with?(value, "#{integration_type}:")
  end

  defp get_armis_id(metadata) when is_map(metadata), do: get_trimmed(metadata, "armis_device_id")

  defp get_armis_id(_metadata), do: nil

  defp identifier_partition(update, metadata) do
    partition = String.trim(update[:partition] || "default")
    integration_type = metadata["integration_type"] |> to_string() |> String.downcase()
    source_id = get_trimmed(metadata, "sync_service_id")

    if integration_type == "armis" and source_id not in [nil, ""] do
      "#{partition}:armis:#{source_id}"
    else
      partition
    end
  end

  defp get_trimmed(map, key) when is_map(map) do
    case map[key] do
      nil ->
        nil

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  @doc """
  Check if any strong identifier is present.
  """
  @spec has_strong_identifier?(strong_identifiers()) :: boolean()
  def has_strong_identifier?(ids) do
    ids_get(ids, :agent_id) != nil or
      ids_get(ids, :armis_id) != nil or
      ids_get(ids, :integration_id) != nil or
      ids_get(ids, :netbox_id) != nil or
      ids_get(ids, :hardware_serial) != nil or
      ids_get(ids, :mac) != nil
  end

  @doc """
  Get the highest priority identifier type and value.
  """
  @spec highest_priority_identifier(strong_identifiers()) :: {atom() | nil, String.t() | nil}
  def highest_priority_identifier(ids) do
    cond do
      ids_get(ids, :agent_id) != nil ->
        {:agent_id, ids_get(ids, :agent_id)}

      ids_get(ids, :armis_id) != nil ->
        {:armis_device_id, ids_get(ids, :armis_id)}

      ids_get(ids, :integration_id) != nil ->
        {:integration_id, ids_get(ids, :integration_id)}

      ids_get(ids, :netbox_id) != nil ->
        {:netbox_device_id, ids_get(ids, :netbox_id)}

      ids_get(ids, :hardware_serial) != nil ->
        {:hardware_serial, ids_get(ids, :hardware_serial)}

      ids_get(ids, :mac) != nil ->
        {:mac, ids_get(ids, :mac)}

      true ->
        {nil, nil}
    end
  end

  def get_identifier_value(ids, :agent_id), do: ids_get(ids, :agent_id)
  def get_identifier_value(ids, :armis_device_id), do: ids_get(ids, :armis_id)
  def get_identifier_value(ids, :integration_id), do: ids_get(ids, :integration_id)
  def get_identifier_value(ids, :netbox_device_id), do: ids_get(ids, :netbox_id)
  def get_identifier_value(ids, :hardware_serial), do: ids_get(ids, :hardware_serial)
  def get_identifier_value(ids, :mac), do: ids_get(ids, :mac)
  def get_identifier_value(_ids, _type), do: nil

  @doc """
  Generate a deterministic ServiceRadar device ID based on identifiers.

  Uses SHA-256 hash of identifiers to create a reproducible UUID.
  Format: `sr:<uuid>`
  """
  @spec generate_deterministic_device_id(strong_identifiers()) :: String.t()
  def generate_deterministic_device_id(ids) do
    partition = ids_get_partition(ids)

    # Build seeds from strong identifiers in priority order
    seeds =
      []
      |> maybe_add_seed("agent", ids_get(ids, :agent_id))
      |> maybe_add_seed("armis", ids_get(ids, :armis_id))
      |> maybe_add_seed("integration", ids_get(ids, :integration_id))
      |> maybe_add_seed("netbox", ids_get(ids, :netbox_id))
      |> maybe_add_seed("hardware_serial", ids_get(ids, :hardware_serial))
      |> maybe_add_seed("mac", ids_get(ids, :mac))

    hash_input =
      cond do
        not Enum.empty?(seeds) ->
          # Strong identifiers present - deterministic hash
          "serviceradar-device-v3:partition:#{partition}:" <> Enum.join(seeds, "")

        ids_get_string(ids, :ip) != "" ->
          # IP-only fallback
          ip = ids_get_string(ids, :ip)
          "serviceradar-device-v3:partition:#{partition}:ip:#{ip}"

        true ->
          # No identifiers - random UUID
          return_random_uuid()
      end

    if is_binary(hash_input) do
      hash_bytes = :crypto.hash(:sha256, hash_input)
      uuid_from_hash(hash_bytes)
    else
      # Already a UUID string from return_random_uuid()
      hash_input
    end
  end

  defp maybe_add_seed(acc, _prefix, nil), do: acc
  defp maybe_add_seed(acc, prefix, value), do: acc ++ ["#{prefix}:#{value}"]

  defp return_random_uuid do
    "sr:" <> Ecto.UUID.generate()
  end

  defp uuid_from_hash(hash_bytes) when byte_size(hash_bytes) >= 16 do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = hash_bytes

    # Set version (4) and variant (RFC 4122)
    c_versioned = (c &&& 0x0FFF) ||| 0x4000
    d_variant = (d &&& 0x3FFF) ||| 0x8000

    uuid =
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
      |> :io_lib.format([a, b, c_versioned, d_variant, e])
      |> IO.iodata_to_binary()
      |> String.downcase()

    "sr:" <> uuid
  end

  def ids_get(ids, :integration_id) when is_map(ids) do
    value = Map.get(ids, :integration_id)
    if IntegrationIdentity.ambiguous_name_keyed?(value), do: nil, else: value
  end

  def ids_get(ids, key) when is_map(ids), do: Map.get(ids, key)
  def ids_get(_ids, _key), do: nil

  def ids_get_string(ids, key) do
    case ids_get(ids, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  def ids_get_partition(ids) do
    case ids_get(ids, :partition) do
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end

  def present_id?(value) when is_binary(value), do: String.trim(value) != ""
  def present_id?(_), do: false

  def get_identifier_values(:mac, ids), do: mac_lookup_values(ids)

  def get_identifier_values(:integration_id, ids) do
    primary = List.wrap(ids_get(ids, :integration_id))

    values =
      case ids_get(ids, :legacy_integration_ids) do
        list when is_list(list) -> Enum.uniq(primary ++ list)
        _ -> primary
      end

    Enum.reject(values, &IntegrationIdentity.ambiguous_name_keyed?/1)
  end

  def get_identifier_values(id_type, ids) do
    case get_identifier_value(ids, id_type) do
      nil -> []
      value -> [value]
    end
  end

  @doc """
  All MAC values to use for identity lookups, in priority order.

  Atomic MACs first; the legacy comma-joined blob value is tried last as a
  lookup-only bridge to identifier rows written before validation existed
  (those rows are purged by the remediation migration). The blob must never
  be registered as a new identifier.
  """
  @spec mac_lookup_values(strong_identifiers()) :: [String.t()]
  def mac_lookup_values(ids) do
    macs =
      case ids_get(ids, :macs) do
        list when is_list(list) and list != [] -> list
        _ -> List.wrap(ids_get(ids, :mac))
      end

    case ids_get(ids, :legacy_mac) do
      blob when is_binary(blob) -> macs ++ [blob]
      _ -> macs
    end
  end

  # Utility functions

  @doc """
  Check if a device ID is a ServiceRadar-generated UUID.
  """
  @spec serviceradar_uuid?(String.t() | nil) :: boolean()
  def serviceradar_uuid?(nil), do: false
  def serviceradar_uuid?(device_id), do: String.starts_with?(device_id, "sr:")

  @doc """
  Check if a device ID is for a ServiceRadar service component.
  """
  @spec service_device_id?(String.t() | nil) :: boolean()
  def service_device_id?(nil), do: false
  def service_device_id?(device_id), do: String.starts_with?(device_id, "serviceradar:")

  @doc """
  Check if a device ID looks like a legacy partition:IP format.
  """
  @spec legacy_ip_based_id?(String.t() | nil) :: boolean()
  def legacy_ip_based_id?(nil), do: false

  def legacy_ip_based_id?(device_id) do
    if serviceradar_uuid?(device_id) or service_device_id?(device_id) do
      false
    else
      case String.split(device_id, ":", parts: 2) do
        [_partition, ip] ->
          # Check if second part looks like an IP
          String.contains?(ip, ".") or String.contains?(ip, ":")

        _ ->
          false
      end
    end
  end

  def partition_from_device_id(device_id) when is_binary(device_id) do
    case String.split(device_id, ":", parts: 2) do
      [partition, _rest] when partition != "sr" -> partition
      _ -> "default"
    end
  end

  def partition_from_device_id(_), do: "default"
end
