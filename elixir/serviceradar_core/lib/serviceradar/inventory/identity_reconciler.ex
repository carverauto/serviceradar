defmodule ServiceRadar.Inventory.IdentityReconciler do
  @moduledoc """
  Device Identity and Reconciliation Engine (DIRE) for Elixir.

  Port of the Go IdentityEngine that resolves device updates to canonical
  ServiceRadar device IDs. This module is the single source of truth for
  device identity resolution.

  ## Resolution Priority

  1. Strong identifiers (Armis ID > Integration ID > NetBox ID > MAC)
     - Hash to deterministic `sr:` UUID
  2. Existing `sr:` UUID in update
     - Preserve as-is
  3. IP-only (no strong identifier)
     - Lookup existing device by IP, or generate new `sr:` UUID

  ## Strong Identifier Priority

  Identifiers are processed in priority order:
  1. `armis_device_id` - Armis platform device ID
  2. `integration_id` - Generic integration ID
  3. `netbox_device_id` - NetBox device ID
  4. `mac` - MAC address (normalized)

  IP is a "weak" identifier only used when no strong identifiers are present.
  """

  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, MergeAudit}

  require Ash.Query
  require Logger
  import Bitwise

  # Identifier types in priority order (lower index = higher priority)
  @identifier_priority [:armis_device_id, :integration_id, :netbox_device_id, :mac]

  @type strong_identifiers :: %{
    armis_id: String.t() | nil,
    integration_id: String.t() | nil,
    netbox_id: String.t() | nil,
    mac: String.t() | nil,
    ip: String.t() | nil,
    partition: String.t()
  }

  @type device_update :: %{
    device_id: String.t() | nil,
    ip: String.t() | nil,
    mac: String.t() | nil,
    partition: String.t() | nil,
    metadata: map() | nil
  }

  @doc """
  Resolve a device update to a canonical ServiceRadar device ID.

  Returns the resolved device ID (either existing or newly generated).
  """
  @spec resolve_device_id(device_update(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_device_id(update, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    # Skip service component IDs
    if service_device_id?(update.device_id) do
      {:ok, update.device_id}
    else
      do_resolve_device_id(update, actor)
    end
  end

  defp do_resolve_device_id(update, actor) do
    ids = extract_strong_identifiers(update)

    # Step 1: Lookup by strong identifiers
    case lookup_by_strong_identifiers(ids, actor) do
      {:ok, device_id} when is_binary(device_id) and device_id != "" ->
        {:ok, device_id}

      _ ->
        # Step 2: Preserve existing ServiceRadar UUID
        if serviceradar_uuid?(update.device_id) do
          {:ok, update.device_id}
        else
          # Step 3: Try IP-based lookup for IP-only devices
          case lookup_by_ip(ids, actor) do
            {:ok, device_id} when is_binary(device_id) and device_id != "" ->
              {:ok, device_id}

            _ ->
              # Step 4: Generate new deterministic UUID
              {:ok, generate_deterministic_device_id(ids)}
          end
        end
    end
  end

  @doc """
  Extract strong identifiers from a device update.
  """
  @spec extract_strong_identifiers(device_update()) :: strong_identifiers()
  def extract_strong_identifiers(update) do
    metadata = update[:metadata] || %{}
    partition = (update[:partition] || "default") |> String.trim()

    %{
      armis_id: get_trimmed(metadata, "armis_device_id"),
      integration_id: get_integration_id(metadata),
      netbox_id: get_trimmed(metadata, "netbox_device_id"),
      mac: normalize_mac(update[:mac]),
      ip: (update[:ip] || "") |> String.trim(),
      partition: partition
    }
  end

  defp get_integration_id(metadata) do
    case metadata["integration_type"] do
      "netbox" ->
        get_trimmed(metadata, "integration_id")

      _ ->
        get_trimmed(metadata, "integration_id")
    end
  end

  defp get_trimmed(map, key) when is_map(map) do
    case map[key] do
      nil -> nil
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
      _ -> nil
    end
  end

  @doc """
  Check if any strong identifier is present.
  """
  @spec has_strong_identifier?(strong_identifiers()) :: boolean()
  def has_strong_identifier?(ids) do
    ids.armis_id != nil or
    ids.integration_id != nil or
    ids.netbox_id != nil or
    ids.mac != nil
  end

  @doc """
  Get the highest priority identifier type and value.
  """
  @spec highest_priority_identifier(strong_identifiers()) :: {atom() | nil, String.t() | nil}
  def highest_priority_identifier(ids) do
    cond do
      ids.armis_id != nil -> {:armis_device_id, ids.armis_id}
      ids.integration_id != nil -> {:integration_id, ids.integration_id}
      ids.netbox_id != nil -> {:netbox_device_id, ids.netbox_id}
      ids.mac != nil -> {:mac, ids.mac}
      true -> {nil, nil}
    end
  end

  @doc """
  Lookup device by strong identifiers in priority order.
  """
  @spec lookup_by_strong_identifiers(strong_identifiers(), term()) :: {:ok, String.t() | nil} | {:error, term()}
  def lookup_by_strong_identifiers(ids, actor) do
    if not has_strong_identifier?(ids) do
      {:ok, nil}
    else
      do_lookup_by_strong_identifiers(ids, actor)
    end
  end

  defp do_lookup_by_strong_identifiers(ids, actor) do
    # Try each identifier type in priority order
    Enum.reduce_while(@identifier_priority, {:ok, nil}, fn id_type, _acc ->
      id_value = get_identifier_value(ids, id_type)

      if id_value do
        case lookup_device_identifier(id_type, id_value, ids.partition, actor) do
          {:ok, device_id} when is_binary(device_id) and device_id != "" ->
            {:halt, {:ok, device_id}}

          _ ->
            {:cont, {:ok, nil}}
        end
      else
        {:cont, {:ok, nil}}
      end
    end)
  end

  defp get_identifier_value(ids, :armis_device_id), do: ids.armis_id
  defp get_identifier_value(ids, :integration_id), do: ids.integration_id
  defp get_identifier_value(ids, :netbox_device_id), do: ids.netbox_id
  defp get_identifier_value(ids, :mac), do: ids.mac

  defp lookup_device_identifier(id_type, id_value, partition, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    DeviceIdentifier
    |> Ash.Query.for_read(:lookup, %{
      identifier_type: id_type,
      identifier_value: id_value,
      partition: partition
    })
    |> Ash.read(query_opts)
    |> case do
      {:ok, [identifier | _]} -> {:ok, identifier.device_id}
      {:ok, []} -> {:ok, nil}
      {:error, _} = error -> error
    end
  rescue
    e ->
      Logger.warning("Failed to lookup device identifier: #{inspect(e)}")
      {:ok, nil}
  end

  @doc """
  Lookup device by IP address (weak identifier).
  """
  @spec lookup_by_ip(strong_identifiers(), term()) :: {:ok, String.t() | nil} | {:error, term()}
  def lookup_by_ip(ids, actor) do
    if not has_strong_identifier?(ids) and ids.ip != "" do
      do_lookup_by_ip(ids.ip, actor)
    else
      {:ok, nil}
    end
  end

  defp do_lookup_by_ip(ip, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    Device
    |> Ash.Query.for_read(:by_ip, %{ip: ip})
    |> Ash.read(query_opts)
    |> case do
      {:ok, [device | _]} ->
        # Only return devices with ServiceRadar UUIDs
        if serviceradar_uuid?(device.uid) do
          {:ok, device.uid}
        else
          {:ok, nil}
        end

      {:ok, []} ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  rescue
    e ->
      Logger.warning("Failed to lookup device by IP: #{inspect(e)}")
      {:ok, nil}
  end

  @doc """
  Generate a deterministic ServiceRadar device ID based on identifiers.

  Uses SHA-256 hash of identifiers to create a reproducible UUID.
  Format: `sr:<uuid>`
  """
  @spec generate_deterministic_device_id(strong_identifiers()) :: String.t()
  def generate_deterministic_device_id(ids) do
    partition = if ids.partition == "", do: "default", else: ids.partition

    # Build seeds from strong identifiers in priority order
    seeds =
      []
      |> maybe_add_seed("armis", ids.armis_id)
      |> maybe_add_seed("integration", ids.integration_id)
      |> maybe_add_seed("netbox", ids.netbox_id)
      |> maybe_add_seed("mac", ids.mac)

    hash_input = cond do
      length(seeds) > 0 ->
        # Strong identifiers present - deterministic hash
        "serviceradar-device-v3:partition:#{partition}:" <> Enum.join(seeds, "")

      ids.ip != "" ->
        # IP-only fallback
        "serviceradar-device-v3:partition:#{partition}:ip:#{ids.ip}"

      true ->
        # No identifiers - random UUID
        return_random_uuid()
    end

    if is_binary(hash_input) do
      hash_bytes = :crypto.hash(:sha256, hash_input)
      uuid_from_hash(hash_bytes)
    else
      hash_input  # Already a UUID string from return_random_uuid()
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

    uuid = :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c_versioned, d_variant, e]
    ) |> IO.iodata_to_binary() |> String.downcase()

    "sr:" <> uuid
  end

  @doc """
  Register device identifiers in the device_identifiers table.
  """
  @spec register_identifiers(String.t(), strong_identifiers(), keyword()) :: :ok | {:error, term()}
  def register_identifiers(device_id, ids, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    partition = if ids.partition == "", do: "default", else: ids.partition
    query_opts = if actor, do: [actor: actor], else: []

    identifiers_to_register =
      []
      |> maybe_add_identifier(device_id, :armis_device_id, ids.armis_id, partition)
      |> maybe_add_identifier(device_id, :integration_id, ids.integration_id, partition)
      |> maybe_add_identifier(device_id, :netbox_device_id, ids.netbox_id, partition)
      |> maybe_add_identifier(device_id, :mac, ids.mac, partition)

    results = Enum.map(identifiers_to_register, fn params ->
      DeviceIdentifier
      |> Ash.Changeset.for_create(:upsert, params)
      |> Ash.create(query_opts)
    end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      :ok
    else
      {:error, {:identifier_registration_failed, errors}}
    end
  end

  defp maybe_add_identifier(acc, _device_id, _id_type, nil, _partition), do: acc
  defp maybe_add_identifier(acc, device_id, id_type, id_value, partition) do
    [%{
      device_id: device_id,
      identifier_type: id_type,
      identifier_value: id_value,
      partition: partition,
      confidence: :strong,
      source: "identity_reconciler"
    } | acc]
  end

  @doc """
  Record a device merge in the audit trail.
  """
  @spec record_merge(String.t(), String.t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def record_merge(from_device_id, to_device_id, reason, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    confidence_score = Keyword.get(opts, :confidence_score)
    details = Keyword.get(opts, :details, %{})
    query_opts = if actor, do: [actor: actor], else: []

    MergeAudit
    |> Ash.Changeset.for_create(:record, %{
      from_device_id: from_device_id,
      to_device_id: to_device_id,
      reason: reason,
      confidence_score: confidence_score,
      source: "identity_reconciler",
      details: details
    })
    |> Ash.create(query_opts)
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
  Normalize a MAC address to uppercase without separators.
  """
  @spec normalize_mac(String.t() | nil) :: String.t() | nil
  def normalize_mac(nil), do: nil
  def normalize_mac(mac) do
    normalized =
      mac
      |> String.trim()
      |> String.upcase()
      |> String.replace(":", "")
      |> String.replace("-", "")
      |> String.replace(".", "")

    if normalized == "", do: nil, else: normalized
  end

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
end
