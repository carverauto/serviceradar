defmodule ServiceRadar.Inventory.IdentityReconciler do
  @moduledoc """
  Device Identity and Reconciliation Engine (DIRE) for Elixir.

  Port of the Go IdentityEngine that resolves device updates to canonical
  ServiceRadar device IDs. This module is the single source of truth for
  device identity resolution.

  ## Resolution Priority

  1. Strong identifiers (Agent ID > Armis ID > Integration ID > NetBox ID > MAC)
     - Hash to deterministic `sr:` UUID
  2. Existing `sr:` UUID in update
     - Preserve as-is
  3. IP-only (no strong identifier)
     - Lookup existing device by IP, or generate new `sr:` UUID

  ## Strong Identifier Priority

  Identifiers are processed in priority order:
  1. `agent_id` - ServiceRadar agent ID (mTLS-validated, stable across pod restarts)
  2. `armis_device_id` - Armis platform device ID
  3. `integration_id` - Generic integration ID
  4. `netbox_device_id` - NetBox device ID
  5. `mac` - MAC address (normalized)

  IP is a "weak" identifier only used when no strong identifiers are present.
  """

  import Bitwise

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.ServiceCheck

  require Ash.Query
  require Logger

  # Identifier types in priority order (lower index = higher priority)
  @identifier_priority [:agent_id, :armis_device_id, :integration_id, :netbox_device_id, :mac]
  @strong_non_mac_identifier_types [
    :agent_id,
    :armis_device_id,
    :integration_id,
    :netbox_device_id
  ]
  @provisional_promotion_required_repeat_count 2

  @type strong_identifiers :: %{
          agent_id: String.t() | nil,
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

    # Step 1: Lookup by strong identifiers (merge conflicts if multiple IDs found)
    case lookup_by_strong_identifiers(ids, actor, update.device_id) do
      {:ok, device_id} when is_binary(device_id) and device_id != "" ->
        _ = maybe_merge_ip_alias_device(device_id, ids, actor)
        {:ok, device_id}

      _ ->
        resolve_fallback_device_id(update, ids, actor)
    end
  end

  defp resolve_fallback_device_id(update, ids, actor) do
    if serviceradar_uuid?(update.device_id) do
      {:ok, update.device_id}
    else
      case lookup_by_ip(ids, actor, allow_strong: true) do
        {:ok, device_id} when is_binary(device_id) and device_id != "" ->
          {:ok, device_id}

        _ ->
          {:ok, generate_deterministic_device_id(ids)}
      end
    end
  end

  @doc """
  Extract strong identifiers from a device update.
  """
  @spec extract_strong_identifiers(device_update()) :: strong_identifiers()
  def extract_strong_identifiers(update) do
    metadata = update[:metadata] || %{}
    partition = String.trim(update[:partition] || "default")

    %{
      # agent_id is typically carried in metadata for inventory updates, but some
      # producers (ex: mapper results) may emit it at the top-level.
      agent_id: get_trimmed(metadata, "agent_id") || get_agent_id_from_update(update),
      armis_id: get_trimmed(metadata, "armis_device_id"),
      integration_id: get_integration_id(metadata),
      netbox_id: get_trimmed(metadata, "netbox_device_id"),
      mac: normalize_mac(update[:mac]),
      ip: String.trim(update[:ip] || ""),
      partition: partition
    }
  end

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
      ids_get(ids, :mac) != nil
  end

  @doc """
  Get the highest priority identifier type and value.
  """
  @spec highest_priority_identifier(strong_identifiers()) :: {atom() | nil, String.t() | nil}
  def highest_priority_identifier(ids) do
    cond do
      ids_get(ids, :agent_id) != nil -> {:agent_id, ids_get(ids, :agent_id)}
      ids_get(ids, :armis_id) != nil -> {:armis_device_id, ids_get(ids, :armis_id)}
      ids_get(ids, :integration_id) != nil -> {:integration_id, ids_get(ids, :integration_id)}
      ids_get(ids, :netbox_id) != nil -> {:netbox_device_id, ids_get(ids, :netbox_id)}
      ids_get(ids, :mac) != nil -> {:mac, ids_get(ids, :mac)}
      true -> {nil, nil}
    end
  end

  @doc """
  Lookup device by strong identifiers in priority order.
  """
  @spec lookup_by_strong_identifiers(strong_identifiers(), term(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def lookup_by_strong_identifiers(ids, actor, preferred_device_id \\ nil) do
    if has_strong_identifier?(ids) do
      matches = lookup_identifier_matches(ids, actor)
      device_ids = matches |> Map.values() |> Enum.map(& &1.device_id) |> Enum.uniq()

      case device_ids do
        [] ->
          {:ok, nil}

        [device_id] ->
          {:ok, device_id}

        _ ->
          canonical_id = select_canonical_device_id(preferred_device_id, matches, actor)
          _ = merge_conflicting_devices(canonical_id, device_ids, matches, actor)
          {:ok, canonical_id}
      end
    else
      {:ok, nil}
    end
  end

  defp get_identifier_value(ids, :agent_id), do: ids_get(ids, :agent_id)
  defp get_identifier_value(ids, :armis_device_id), do: ids_get(ids, :armis_id)
  defp get_identifier_value(ids, :integration_id), do: ids_get(ids, :integration_id)
  defp get_identifier_value(ids, :netbox_device_id), do: ids_get(ids, :netbox_id)
  defp get_identifier_value(ids, :mac), do: ids_get(ids, :mac)
  defp get_identifier_value(_ids, _type), do: nil

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
  @spec lookup_by_ip(strong_identifiers(), term(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def lookup_by_ip(ids, actor, opts \\ []) do
    allow_strong = Keyword.get(opts, :allow_strong, false)
    ip = ids_get_string(ids, :ip)
    partition = ids_get_partition(ids)

    if (has_strong_identifier?(ids) and not allow_strong) or ip == "" do
      {:ok, nil}
    else
      case lookup_alias_device_id(ip, partition, actor) do
        {:ok, device_id} when is_binary(device_id) and device_id != "" ->
          {:ok, device_id}

        _ ->
          do_lookup_by_ip(ip, actor)
      end
    end
  end

  defp do_lookup_by_ip(ip, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    Device
    |> Ash.Query.for_read(:by_ip, %{ip: ip})
    |> Ash.read(query_opts)
    |> Page.unwrap()
    |> case do
      {:ok, devices} ->
        {:ok, select_ip_device_id(devices)}

      {:error, _} = error ->
        error
    end
  rescue
    e ->
      Logger.warning("Failed to lookup device by IP: #{inspect(e)}")
      {:ok, nil}
  end

  @doc """
  Lookup a confirmed/updated alias device ID for the given IP.

  If no confirmed/updated alias is found and `include_detected: true` is passed,
  also checks for detected aliases as a fallback.
  """
  @spec lookup_alias_device_id(String.t(), String.t() | nil, term(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def lookup_alias_device_id(ip, partition, actor, opts \\ []) do
    query_opts = if actor, do: [actor: actor], else: []
    include_detected = Keyword.get(opts, :include_detected, false)

    # First try confirmed/updated aliases
    query =
      DeviceAliasState
      |> Ash.Query.filter(
        alias_type == :ip and alias_value == ^ip and state in [:confirmed, :updated]
      )
      |> maybe_filter_alias_partition(partition)

    case Ash.read(query, query_opts) do
      {:ok, [%DeviceAliasState{device_id: device_id} | _]} ->
        {:ok, device_id}

      {:ok, []} ->
        # No confirmed alias - check detected aliases if requested
        if include_detected do
          lookup_detected_alias_device_id(ip, partition, query_opts)
        else
          {:ok, nil}
        end

      {:error, _} = error ->
        error
    end
  rescue
    e ->
      Logger.warning("Failed to lookup device by alias IP: #{inspect(e)}")
      {:ok, nil}
  end

  defp lookup_detected_alias_device_id(ip, partition, query_opts) do
    query =
      DeviceAliasState
      |> Ash.Query.filter(alias_type == :ip and alias_value == ^ip and state == :detected)
      |> maybe_filter_alias_partition(partition)
      # Prefer aliases with more sightings
      |> Ash.Query.sort(sighting_count: :desc, first_seen_at: :asc)

    case Ash.read(query, query_opts) do
      {:ok, [%DeviceAliasState{device_id: device_id} | _]} -> {:ok, device_id}
      {:ok, []} -> {:ok, nil}
      {:error, _} = error -> error
    end
  rescue
    e ->
      Logger.warning("Failed to lookup detected alias for IP: #{inspect(e)}")
      {:ok, nil}
  end

  defp maybe_merge_ip_alias_device(device_id, ids, actor) do
    ip = ids_get_string(ids, :ip)
    partition = ids_get_partition(ids)

    with true <- present_id?(ip),
         {:ok, alias_device_id} when is_binary(alias_device_id) and alias_device_id != "" <-
           lookup_alias_device_id(ip, partition, actor),
         true <- alias_device_id != device_id,
         false <- service_device_id?(alias_device_id) do
      _ =
        merge_devices(alias_device_id, device_id,
          actor: actor,
          reason: "ip_alias_conflict",
          details: %{
            source: "identity_reconciler",
            alias_ip: ip
          }
        )
    end

    :ok
  end

  defp maybe_filter_alias_partition(query, nil), do: query
  defp maybe_filter_alias_partition(query, ""), do: query

  defp maybe_filter_alias_partition(query, partition) do
    Ash.Query.filter(query, partition == ^partition)
  end

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

  @doc """
  Register device identifiers in the device_identifiers table.
  """
  @spec register_identifiers(String.t(), strong_identifiers(), keyword()) ::
          :ok | {:error, term()}
  def register_identifiers(device_id, ids, opts \\ []) do
    actor = Keyword.get(opts, :actor)
    partition = ids_get_partition(ids)
    query_opts = if actor, do: [actor: actor], else: []
    canonical_id = resolve_identifier_conflicts(device_id, ids, actor)

    maybe_merge_on_register(device_id, canonical_id, ids, actor)
    maybe_promote_provisional_identity(canonical_id, ids, actor, partition)

    identifiers_to_register =
      []
      |> maybe_add_identifier(canonical_id, :agent_id, ids_get(ids, :agent_id), partition)
      |> maybe_add_identifier(canonical_id, :armis_device_id, ids_get(ids, :armis_id), partition)
      |> maybe_add_identifier(
        canonical_id,
        :integration_id,
        ids_get(ids, :integration_id),
        partition
      )
      |> maybe_add_identifier(
        canonical_id,
        :netbox_device_id,
        ids_get(ids, :netbox_id),
        partition
      )
      |> maybe_add_identifier(canonical_id, :mac, ids_get(ids, :mac), partition)

    results =
      Enum.map(identifiers_to_register, fn params ->
        DeviceIdentifier
        |> Ash.Changeset.for_create(:upsert, params)
        |> Ash.create(query_opts)
      end)

    results
    |> Enum.filter(&match?({:error, _}, &1))
    |> handle_identifier_errors()
  end

  defp maybe_promote_provisional_identity(_device_id, ids, _actor, _partition)
       when not is_map(ids), do: :ok

  defp maybe_promote_provisional_identity(device_id, ids, actor, partition) do
    case Device.get_by_uid(device_id, false, actor: actor) do
      {:ok, %Device{} = device} ->
        metadata = Map.new(device.metadata || %{})

        if Map.get(metadata, "identity_state") == "provisional" do
          evaluate_and_maybe_promote_provisional_identity(device, metadata, ids, actor, partition)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp evaluate_and_maybe_promote_provisional_identity(device, metadata, ids, actor, partition) do
    current_non_mac_types = current_non_mac_strong_types(ids)
    existing_non_mac_types = existing_non_mac_identifier_types(device.uid, partition, actor)
    distinct_types = Enum.uniq(current_non_mac_types ++ existing_non_mac_types)
    distinct_type_names = Enum.map(distinct_types, &Atom.to_string/1)
    current_type_names = Enum.map(current_non_mac_types, &Atom.to_string/1)
    total_sightings = non_mac_sighting_total(metadata, current_non_mac_types)
    repeated? = total_sightings >= @provisional_promotion_required_repeat_count
    corroborated? = length(distinct_types) >= 2

    cond do
      current_non_mac_types == [] ->
        record_blocked_promotion(device, metadata, "no_non_mac_strong_identifier", actor, %{
          current_non_mac_types: current_type_names,
          distinct_types: distinct_type_names,
          non_mac_sighting_total: total_sightings
        })

      repeated? or corroborated? ->
        promote_device_identity_state(device, metadata, actor, %{
          "identity_promotion_policy" => "corroborated_strong_identifier",
          "identity_promotion_non_mac_sighting_count" => total_sightings,
          "identity_promotion_types_seen" => distinct_type_names
        })

      true ->
        record_blocked_promotion(device, metadata, "insufficient_corroboration", actor, %{
          current_non_mac_types: current_type_names,
          distinct_types: distinct_type_names,
          non_mac_sighting_total: total_sightings,
          required_repeat_count: @provisional_promotion_required_repeat_count
        })
    end
  end

  defp current_non_mac_strong_types(ids) do
    Enum.filter(@strong_non_mac_identifier_types, fn type ->
      present_id?(get_identifier_value(ids, type))
    end)
  end

  defp existing_non_mac_identifier_types(device_id, partition, actor) do
    query =
      DeviceIdentifier
      |> Ash.Query.for_read(:by_device, %{device_id: device_id})
      |> Ash.Query.filter(identifier_type in ^@strong_non_mac_identifier_types)
      |> maybe_filter_identifier_partition(partition)

    case Ash.read(query, actor: actor) do
      {:ok, identifiers} ->
        identifiers
        |> Enum.map(& &1.identifier_type)
        |> Enum.uniq()

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp maybe_filter_identifier_partition(query, ""), do: query

  defp maybe_filter_identifier_partition(query, partition) do
    Ash.Query.filter(query, partition == ^partition)
  end

  defp non_mac_sighting_total(metadata, current_non_mac_types) do
    previous = parse_positive_int(metadata["identity_promotion_non_mac_sighting_count"])
    increment = if current_non_mac_types == [], do: 0, else: 1
    previous + increment
  end

  defp parse_positive_int(value) when is_integer(value) and value >= 0, do: value

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  defp parse_positive_int(_), do: 0

  defp record_blocked_promotion(device, metadata, reason, actor, details) do
    blocked_metadata =
      metadata
      |> Map.put("identity_promotion_blocked_reason", reason)
      |> Map.put("identity_promotion_last_eval_at", now_iso8601())
      |> Map.put(
        "identity_promotion_non_mac_sighting_count",
        details[:non_mac_sighting_total] || metadata["identity_promotion_non_mac_sighting_count"] ||
          0
      )
      |> Map.put("identity_promotion_types_seen", details[:distinct_types] || [])

    _ =
      device
      |> Ash.Changeset.for_update(:update, %{metadata: blocked_metadata})
      |> Ash.update(actor: actor)

    Logger.info("Blocked provisional identity promotion",
      device_id: device.uid,
      reason: reason,
      current_non_mac_types: details[:current_non_mac_types] || [],
      distinct_types: details[:distinct_types] || [],
      non_mac_sighting_total: details[:non_mac_sighting_total] || 0,
      required_repeat_count:
        details[:required_repeat_count] || @provisional_promotion_required_repeat_count
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :provisional_promotion, :blocked],
      %{count: 1},
      %{reason: reason}
    )

    :ok
  rescue
    e ->
      Logger.warning(
        "Failed to record blocked provisional promotion for #{device.uid}: #{inspect(e)}"
      )

      :ok
  end

  defp promote_device_identity_state(%Device{} = device, metadata, actor, extra_metadata) do
    promoted_metadata =
      metadata
      |> Map.put("identity_state", "canonical")
      |> Map.put("identity_promoted_by", "dire")
      |> Map.put("identity_promoted_at", now_iso8601())
      |> Map.put("identity_promotion_blocked_reason", nil)
      |> Map.merge(extra_metadata)

    device
    |> Ash.Changeset.for_update(:update, %{metadata: promoted_metadata})
    |> Ash.update(actor: actor)

    Logger.info("Promoted provisional identity",
      device_id: device.uid,
      promotion_policy: promoted_metadata["identity_promotion_policy"],
      non_mac_sighting_total: promoted_metadata["identity_promotion_non_mac_sighting_count"],
      promotion_types_seen: promoted_metadata["identity_promotion_types_seen"] || []
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :provisional_promotion, :promoted],
      %{count: 1},
      %{policy: promoted_metadata["identity_promotion_policy"] || "unknown"}
    )

    :ok
  rescue
    e ->
      Logger.warning("Failed to promote provisional identity for #{device.uid}: #{inspect(e)}")
      :ok
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp handle_identifier_errors([]), do: :ok
  defp handle_identifier_errors(errors), do: {:error, {:identifier_registration_failed, errors}}

  defp maybe_merge_on_register(device_id, canonical_id, ids, actor) do
    if should_merge_on_register?(device_id, canonical_id) do
      matches = lookup_identifier_matches(ids, actor)

      if merge_allowed_for_matches?(matches) do
        _ =
          merge_devices(device_id, canonical_id,
            actor: actor,
            reason: "identifier_conflict",
            details: %{
              source: "identifier_registration",
              identifiers: %{
                agent_id: ids_get(ids, :agent_id),
                armis_id: ids_get(ids, :armis_id),
                integration_id: ids_get(ids, :integration_id),
                netbox_id: ids_get(ids, :netbox_id),
                mac: ids_get(ids, :mac)
              }
            }
          )
      else
        blocked_reason = blocked_merge_reason(matches)
        device_ids = Enum.uniq([device_id, canonical_id])

        Logger.warning(
          "Blocked register-time merge. " <>
            "Devices: #{inspect(device_ids)}, reason: #{blocked_reason}"
        )

        emit_blocked_merge_telemetry(blocked_reason, device_ids, matches)
      end

      :ok
    else
      :ok
    end
  end

  defp ids_get(ids, key) when is_map(ids), do: Map.get(ids, key)
  defp ids_get(_ids, _key), do: nil

  defp ids_get_string(ids, key) do
    case ids_get(ids, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp ids_get_partition(ids) do
    case ids_get(ids, :partition) do
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end

  defp should_merge_on_register?(device_id, canonical_id) do
    present_id?(device_id) and present_id?(canonical_id) and device_id != canonical_id and
      not service_device_id?(device_id)
  end

  defp present_id?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_id?(_), do: false

  @doc """
  Reconcile duplicate devices by shared strong identifiers.

  Returns stats for observability and logging.
  """
  @spec reconcile_duplicates(keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_duplicates(opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:identity_reconciliation))
    max_merges = Keyword.get(opts, :max_merges)
    started_at = System.monotonic_time(:millisecond)

    Logger.info("Device identity reconciliation started")

    {identifier_index, identifier_scanned} = build_identifier_index(actor)
    {ip_index, ip_scanned} = build_ip_index(actor)

    identifier_duplicates =
      Enum.filter(identifier_index, fn {_key, device_ids} -> MapSet.size(device_ids) > 1 end)

    ip_duplicates =
      Enum.filter(ip_index, fn {_key, device_ids} -> MapSet.size(device_ids) > 1 end)

    duplicate_entries = identifier_duplicates ++ ip_duplicates

    components =
      duplicate_entries
      |> build_duplicate_components()
      |> Enum.filter(&(length(&1) > 1))

    {merge_count, error_count} = merge_components(components, actor, max_merges)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    stats = %{
      identifiers_scanned: identifier_scanned,
      duplicate_identifier_count: length(identifier_duplicates),
      ip_addresses_scanned: ip_scanned,
      duplicate_ip_count: length(ip_duplicates),
      duplicate_components: length(components),
      merges: merge_count,
      errors: error_count,
      duration_ms: duration_ms
    }

    Logger.info("Device identity reconciliation completed: #{inspect(stats)}")

    {:ok, stats}
  rescue
    error ->
      Logger.warning("Device identity reconciliation failed: #{inspect(error)}")
      {:error, error}
  end

  defp lookup_identifier_matches(ids, actor) do
    partition = ids_get_partition(ids)

    Enum.reduce(@identifier_priority, %{}, fn id_type, acc ->
      with id_value when not is_nil(id_value) <- get_identifier_value(ids, id_type),
           {:ok, device_id} when is_binary(device_id) and device_id != "" <-
             lookup_device_identifier(id_type, id_value, partition, actor) do
        Map.put(acc, id_type, %{value: id_value, device_id: device_id})
      else
        _ -> acc
      end
    end)
  end

  defp select_canonical_device_id(preferred_device_id, matches, actor) do
    device_ids = matches |> Map.values() |> Enum.map(& &1.device_id) |> Enum.uniq()

    if serviceradar_uuid?(preferred_device_id) and preferred_device_id in device_ids do
      preferred_device_id
    else
      case highest_priority_match(matches) do
        nil -> most_recent_device_id(device_ids, actor)
        device_id -> device_id
      end
    end
  end

  defp highest_priority_match(matches) do
    Enum.find_value(@identifier_priority, fn id_type ->
      case Map.get(matches, id_type) do
        %{device_id: device_id} -> device_id
        _ -> nil
      end
    end)
  end

  defp most_recent_device_id([], _actor), do: nil

  defp most_recent_device_id(device_ids, actor) do
    query =
      Device
      |> Ash.Query.filter(uid in ^device_ids)
      |> Ash.Query.for_read(:read, %{}, actor: actor)

    case Page.unwrap(Ash.read(query, actor: actor)) do
      {:ok, devices} when devices != [] ->
        devices
        |> Enum.max_by(fn device -> device.last_seen_time || ~U[1970-01-01 00:00:00Z] end)
        |> Map.get(:uid)

      {:ok, _} ->
        List.first(device_ids)

      {:error, _} ->
        List.first(device_ids)
    end
  end

  defp merge_conflicting_devices(canonical_id, device_ids, matches, actor) do
    details = %{
      identifiers:
        Enum.map(matches, fn {id_type, %{value: value, device_id: device_id}} ->
          %{type: id_type, value: value, device_id: device_id}
        end)
    }

    if merge_allowed_for_matches?(matches) do
      device_ids
      |> Enum.reject(&(&1 == canonical_id))
      |> Enum.each(fn from_id ->
        _ =
          merge_devices(from_id, canonical_id,
            actor: actor,
            reason: "identifier_conflict",
            details: details
          )
      end)
    else
      blocked_reason = blocked_merge_reason(matches)

      Logger.warning(
        "Blocked merge: shared identifiers are not eligible for auto-merge. " <>
          "Devices: #{inspect(device_ids)}, " <>
          "identifiers: #{inspect(details.identifiers)}"
      )

      emit_blocked_merge_telemetry(blocked_reason, device_ids, details.identifiers)
    end
  end

  # Merge only when there is at least one non-MAC strong identifier involved,
  # and the match set is not entirely medium-confidence MACs.
  defp merge_allowed_for_matches?(matches) do
    not mac_only_matches?(matches) and not medium_confidence_only?(matches)
  end

  # MAC-only matches are too noisy (especially interface MACs observed by mapper)
  # and can collapse unrelated devices.
  defp mac_only_matches?(matches) do
    Enum.any?(matches) and
      Enum.all?(matches, fn
        {:mac, _} -> true
        _ -> false
      end)
  end

  # Returns true if the only shared identifiers that caused the conflict are
  # MAC addresses that are locally-administered (medium confidence).
  # Strong identifiers (agent_id, armis_id, etc.) are never medium-confidence.
  defp medium_confidence_only?(matches) do
    Enum.all?(matches, fn
      {:mac, %{value: value}} -> locally_administered_mac?(value)
      _ -> false
    end)
  end

  defp resolve_identifier_conflicts(device_id, ids, actor) do
    matches = lookup_identifier_matches(ids, actor)
    device_ids = matches |> Map.values() |> Enum.map(& &1.device_id) |> Enum.uniq()

    case device_ids do
      [] ->
        device_id

      [only_id] ->
        only_id

      _ ->
        canonical_id = select_canonical_device_id(device_id, matches, actor)
        resolve_conflicts_for_canonical(device_id, canonical_id, device_ids, matches, actor)
    end
  end

  defp resolve_conflicts_for_canonical(device_id, canonical_id, device_ids, matches, actor) do
    if merge_allowed_for_matches?(matches) do
      _ = merge_conflicting_devices(canonical_id, device_ids, matches, actor)
      canonical_id
    else
      blocked_reason = blocked_merge_reason(matches)

      Logger.warning(
        "Blocked merge during identifier conflict resolution. " <>
          "Devices: #{inspect(device_ids)}, reason: #{blocked_reason}"
      )

      emit_blocked_merge_telemetry(blocked_reason, device_ids, matches)

      # Preserve current device_id on blocked merge paths to avoid
      # destructive rebinds from ambiguous MAC-only conflicts.
      if present_id?(device_id), do: device_id, else: canonical_id
    end
  end

  defp blocked_merge_reason(matches) do
    cond do
      mac_only_matches?(matches) -> "mac_only_conflict"
      medium_confidence_only?(matches) -> "medium_confidence_only"
      true -> "policy_blocked"
    end
  end

  defp emit_blocked_merge_telemetry(blocked_reason, device_ids, identifiers) do
    identifier_count =
      cond do
        is_list(identifiers) -> length(identifiers)
        is_map(identifiers) -> map_size(identifiers)
        true -> 0
      end

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :merge, :blocked],
      %{count: 1},
      %{
        reason: blocked_reason,
        device_count: length(device_ids),
        identifier_count: identifier_count
      }
    )
  end

  defp build_identifier_index(actor) do
    query =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type in ^@identifier_priority)
      |> Ash.Query.select([:device_id, :identifier_type, :identifier_value, :partition])

    query
    |> Ash.stream!(actor: actor, batch_size: 2000)
    |> Enum.reduce({%{}, 0}, &accumulate_identifier_index/2)
  end

  defp build_ip_index(actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(not is_nil(ip) and ip != "")

    query
    |> Ash.stream!(actor: actor, batch_size: 2000)
    |> Enum.reduce({%{}, 0}, &accumulate_ip_index/2)
  end

  defp accumulate_identifier_index(record, {acc, count}) do
    device_id = normalize_identifier_value(record.device_id)
    identifier_value = normalize_identifier_value(record.identifier_value)

    if skip_identifier_record?(device_id, identifier_value) do
      {acc, count + 1}
    else
      partition = normalize_identifier_value(record.partition) || "default"
      key = {partition, record.identifier_type, identifier_value}

      updated =
        Map.update(acc, key, MapSet.new([device_id]), fn set ->
          MapSet.put(set, device_id)
        end)

      {updated, count + 1}
    end
  end

  defp accumulate_ip_index(device, {acc, count}) do
    device_id = normalize_identifier_value(device.uid)
    ip = normalize_identifier_value(device.ip)

    if skip_ip_record?(device_id, ip) do
      {acc, count + 1}
    else
      partition = partition_from_device_id(device_id)
      key = {partition, ip}

      updated =
        Map.update(acc, key, MapSet.new([device_id]), fn set ->
          MapSet.put(set, device_id)
        end)

      {updated, count + 1}
    end
  end

  defp skip_identifier_record?(device_id, identifier_value) do
    is_nil(device_id) or is_nil(identifier_value) or service_device_id?(device_id)
  end

  defp skip_ip_record?(device_id, ip) do
    is_nil(device_id) or is_nil(ip) or service_device_id?(device_id)
  end

  defp normalize_identifier_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_identifier_value(_), do: nil

  defp select_ip_device([]), do: nil

  defp select_ip_device(devices) do
    valid_devices =
      Enum.reject(devices, fn device ->
        metadata = device.metadata || %{}

        Map.has_key?(metadata, "_merged_into") or
          String.downcase(to_string(metadata["_deleted"] || "")) == "true" or
          not is_nil(device.deleted_at) or
          service_device_id?(device.uid)
      end)

    candidates = Enum.filter(valid_devices, &serviceradar_uuid?(&1.uid))
    candidates = if candidates == [], do: valid_devices, else: candidates

    Enum.max_by(candidates, &device_seen_score/1, fn -> nil end)
  end

  defp select_ip_device_id(devices) do
    case select_ip_device(devices) do
      %Device{uid: uid} ->
        if serviceradar_uuid?(uid), do: uid

      _ ->
        nil
    end
  end

  defp device_seen_score(device) do
    case device.last_seen_time do
      %DateTime{} = dt -> DateTime.to_unix(dt, :second)
      _ -> 0
    end
  end

  defp build_duplicate_components(duplicate_entries) do
    duplicate_entries
    |> build_duplicate_parents()
    |> build_duplicate_groups()
  end

  defp build_duplicate_parents(duplicate_entries) do
    Enum.reduce(duplicate_entries, %{}, fn {_key, device_ids}, acc ->
      ids = device_ids |> MapSet.to_list() |> Enum.uniq()
      acc = Enum.reduce(ids, acc, &Map.put_new(&2, &1, &1))
      union_device_group(ids, acc)
    end)
  end

  defp union_device_group([first | rest], acc) do
    Enum.reduce(rest, acc, fn id, parents -> union_devices(parents, first, id) end)
  end

  defp union_device_group(_ids, acc), do: acc

  defp build_duplicate_groups(parents) do
    parents
    |> Map.keys()
    |> Enum.reduce(%{}, fn device_id, acc ->
      root = find_device_root(parents, device_id)
      Map.update(acc, root, [device_id], &[device_id | &1])
    end)
    |> Map.values()
  end

  defp find_device_root(parents, device_id) do
    parent = Map.get(parents, device_id, device_id)

    if parent == device_id do
      device_id
    else
      find_device_root(parents, parent)
    end
  end

  defp union_devices(parents, device_a, device_b) do
    root_a = find_device_root(parents, device_a)
    root_b = find_device_root(parents, device_b)

    if root_a == root_b do
      parents
    else
      Map.put(parents, root_b, root_a)
    end
  end

  defp merge_components(components, actor, max_merges) do
    Enum.reduce_while(components, {0, 0}, fn device_ids, {merged, errors} ->
      {merged_count, error_count, halted?} =
        merge_component_devices(device_ids, actor, max_merges, merged)

      total_merged = merged + merged_count
      total_errors = errors + error_count

      if halted? or (max_merges && total_merged >= max_merges) do
        {:halt, {total_merged, total_errors}}
      else
        {:cont, {total_merged, total_errors}}
      end
    end)
  end

  defp merge_component_devices(device_ids, actor, max_merges, merged_so_far) do
    canonical_id = choose_canonical_device_id(device_ids, actor)

    {local_merged, local_errors} =
      device_ids
      |> Enum.reject(&(&1 == canonical_id))
      |> Enum.reduce_while({0, 0}, fn from_id, acc ->
        merge_component_step(from_id, canonical_id, actor, max_merges, merged_so_far, acc)
      end)

    halted? = max_merges && merged_so_far + local_merged >= max_merges
    {local_merged, local_errors, halted?}
  end

  defp merge_component_step(from_id, canonical_id, actor, max_merges, merged_so_far, acc) do
    {local_merged, local_errors} = acc

    if max_merges && merged_so_far + local_merged >= max_merges do
      {:halt, {local_merged, local_errors}}
    else
      case merge_component_device(from_id, canonical_id, actor) do
        :ok -> {:cont, {local_merged + 1, local_errors}}
        {:error, _reason} -> {:cont, {local_merged, local_errors + 1}}
      end
    end
  end

  defp merge_component_device(from_id, canonical_id, actor) do
    case merge_devices(from_id, canonical_id,
           actor: actor,
           reason: "identifier_backfill",
           details: %{source: "scheduled_reconciliation"}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to merge device #{from_id} into #{canonical_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp choose_canonical_device_id(device_ids, actor) do
    candidates = Enum.filter(device_ids, &serviceradar_uuid?/1)
    candidates = if candidates == [], do: device_ids, else: candidates

    most_recent_device_id(candidates, actor) || List.first(candidates)
  end

  @doc """
  Merge a duplicate device into a canonical device and reassign related records.
  """
  @spec merge_devices(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def merge_devices(from_device_id, to_device_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:device_merge))
    reason = Keyword.get(opts, :reason, "identity_resolution")
    details = Keyword.get(opts, :details, %{})

    if from_device_id == to_device_id do
      :ok
    else
      resources = [
        Device,
        DeviceIdentifier,
        Interface,
        MergeAudit,
        ServiceCheck,
        Alert,
        Agent,
        DeviceAliasState
      ]

      resources
      |> Ash.transaction(fn ->
        with {:ok, %Device{} = from_device} <-
               Device.get_by_uid(from_device_id, false, actor: actor),
             {:ok, %Device{}} <- Device.get_by_uid(to_device_id, false, actor: actor),
             :ok <- reassign_device_identifiers(from_device_id, to_device_id, actor),
             :ok <- reassign_service_checks(from_device_id, to_device_id, actor),
             :ok <- reassign_alerts(from_device_id, to_device_id, actor),
             :ok <- reassign_agents(from_device_id, to_device_id, actor),
             :ok <- reassign_alias_states(from_device_id, to_device_id, actor),
             :ok <- reassign_interfaces(from_device_id, to_device_id, actor),
             {:ok, _merge} <-
               MergeAudit.record(
                 %{
                   from_device_id: from_device_id,
                   to_device_id: to_device_id,
                   reason: reason,
                   source: "identity_reconciler",
                   details: details
                 },
                 actor: actor
               ),
             {:ok, _} <- Ash.destroy(from_device, actor: actor, action: :destroy) do
          :ok
        end
      end)
      |> case do
        {:ok, :ok} ->
          emit_merge_executed_telemetry(reason, from_device_id, to_device_id)
          :ok

        {:ok, other} ->
          emit_merge_failed_telemetry(reason, from_device_id, to_device_id, other)
          other

        {:error, _} = error ->
          emit_merge_failed_telemetry(reason, from_device_id, to_device_id, error)
          error
      end
    end
  end

  defp emit_merge_executed_telemetry(reason, from_device_id, to_device_id) do
    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :merge, :executed],
      %{count: 1},
      %{
        reason: reason,
        manual_override: manual_override_merge_reason?(reason),
        from_device_id: from_device_id,
        to_device_id: to_device_id
      }
    )
  end

  defp emit_merge_failed_telemetry(reason, from_device_id, to_device_id, error) do
    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :merge, :failed],
      %{count: 1},
      %{
        reason: reason,
        manual_override: manual_override_merge_reason?(reason),
        from_device_id: from_device_id,
        to_device_id: to_device_id,
        error: inspect(error)
      }
    )
  end

  defp manual_override_merge_reason?(reason) when is_binary(reason) do
    String.starts_with?(reason, "manual")
  end

  defp manual_override_merge_reason?(_), do: false

  @doc """
  Reverse an incorrect merge by recreating the from-device and reassigning
  its original identifiers back.

  Uses the `merge_audit` trail to identify what was merged.
  Records an unmerge audit entry for traceability.
  """
  @spec unmerge_device(String.t(), keyword()) :: :ok | {:error, term()}
  def unmerge_device(from_device_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:device_unmerge))

    # Find the merge audit entry for this from_device_id
    case MergeAudit.get_merged_to(from_device_id, actor: actor) do
      {:ok, [audit | _]} ->
        do_unmerge(from_device_id, audit.to_device_id, audit, actor)

      {:ok, []} ->
        {:error, :no_merge_audit_found}

      {:error, _} = error ->
        error
    end
  end

  defp do_unmerge(from_device_id, to_device_id, audit, actor) do
    resources = [Device, DeviceIdentifier, MergeAudit]

    resources
    |> Ash.transaction(fn ->
      # Recreate the from-device
      with {:ok, _device} <- recreate_device(from_device_id, audit, actor),
           :ok <- reassign_original_identifiers(from_device_id, to_device_id, audit, actor),
           {:ok, _} <-
             MergeAudit.record(
               %{
                 from_device_id: to_device_id,
                 to_device_id: from_device_id,
                 reason: "unmerge",
                 source: "identity_reconciler",
                 details: %{
                   original_merge_event_id: audit.event_id,
                   original_merge_reason: audit.reason,
                   unmerged_by: "admin"
                 }
               },
               actor: actor
             ) do
        Logger.info(
          "Unmerged device #{from_device_id} from #{to_device_id} " <>
            "(original merge: #{audit.event_id})"
        )

        :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:ok, other} -> other
      {:error, _} = error -> error
    end
  end

  defp recreate_device(from_device_id, audit, actor) do
    # Extract any metadata from the merge audit that can help reconstruct the device
    details = audit.details || %{}
    ip = details["from_device_ip"] || details[:from_device_ip]
    hostname = details["from_device_hostname"] || details[:from_device_hostname]

    attrs = %{uid: from_device_id}
    attrs = if ip, do: Map.put(attrs, :ip, ip), else: attrs
    attrs = if hostname, do: Map.put(attrs, :hostname, hostname), else: attrs

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  # Reassign identifiers that were originally on the from-device back to it.
  # Uses the merge audit details to identify which identifiers to reassign.
  defp reassign_original_identifiers(from_device_id, to_device_id, audit, actor) do
    details = audit.details || %{}
    original_identifiers = details["identifiers"] || details[:identifiers] || []
    original_identifier_keys = original_identifier_keys(original_identifiers)

    # Find identifiers on the to-device that match the original merge's identifiers
    case DeviceIdentifier
         |> Ash.Query.for_read(:by_device, %{device_id: to_device_id})
         |> Ash.read(actor: actor) do
      {:ok, current_identifiers} ->
        identifiers_to_reassign =
          Enum.filter(
            current_identifiers,
            &identifier_in_original_set?(&1, original_identifier_keys)
          )

        Enum.each(identifiers_to_reassign, fn identifier ->
          identifier
          |> Ash.Changeset.for_update(:reassign_device, %{device_id: from_device_id})
          |> Ash.update(actor: actor)
        end)

        :ok

      {:error, _} = error ->
        error
    end
  end

  defp original_identifier_keys(original_identifiers) do
    original_identifiers
    |> Enum.map(&extract_original_identifier_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp extract_original_identifier_key(original) when is_map(original) do
    orig_type =
      original["type"] || original[:type] || original["identifier_type"] ||
        original[:identifier_type]

    orig_value =
      original["value"] || original[:value] || original["identifier_value"] ||
        original[:identifier_value]

    if is_nil(orig_type) or is_nil(orig_value) do
      nil
    else
      {to_string(orig_type), orig_value}
    end
  end

  defp extract_original_identifier_key(_original), do: nil

  defp identifier_in_original_set?(identifier, original_identifier_keys) do
    key = {to_string(identifier.identifier_type), identifier.identifier_value}
    MapSet.member?(original_identifier_keys, key)
  end

  defp reassign_device_identifiers(from_id, to_id, actor) do
    bulk_reassign(
      DeviceIdentifier,
      :reassign_device,
      :device_id,
      from_id,
      %{device_id: to_id},
      actor
    )
  end

  defp reassign_service_checks(from_id, to_id, actor) do
    bulk_reassign(
      ServiceCheck,
      :reassign_device,
      :device_uid,
      from_id,
      %{device_uid: to_id},
      actor
    )
  end

  defp reassign_alerts(from_id, to_id, actor) do
    bulk_reassign(Alert, :reassign_device, :device_uid, from_id, %{device_uid: to_id}, actor)
  end

  defp reassign_agents(from_id, to_id, actor) do
    bulk_reassign(Agent, :reassign_device, :device_uid, from_id, %{device_uid: to_id}, actor)
  end

  defp reassign_alias_states(from_id, to_id, actor) do
    bulk_reassign(
      DeviceAliasState,
      :reassign_device,
      :device_id,
      from_id,
      %{device_id: to_id},
      actor
    )
  end

  defp reassign_interfaces(from_id, to_id, actor) do
    query =
      Interface
      |> Ash.Query.filter(device_id == ^from_id)
      |> Ash.Query.for_read(:read, %{}, actor: actor)

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        :ok

      {:ok, records} ->
        interface_uids = records |> Enum.map(& &1.interface_uid) |> Enum.uniq()
        timestamps = records |> Enum.map(& &1.timestamp) |> Enum.uniq()

        with {:ok, existing_keys} <-
               fetch_existing_interface_keys(to_id, interface_uids, timestamps, actor) do
          {to_update, to_delete} =
            Enum.split_with(records, fn record ->
              not existing_interface_key?(existing_keys, record)
            end)

          with :ok <- bulk_update_interfaces(to_update, to_id, actor) do
            bulk_delete_interfaces(to_delete, actor)
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp fetch_existing_interface_keys(_to_id, [], _timestamps, _actor), do: {:ok, []}
  defp fetch_existing_interface_keys(_to_id, _uids, [], _actor), do: {:ok, []}

  defp fetch_existing_interface_keys(to_id, interface_uids, timestamps, actor) do
    existing_query =
      Interface
      |> Ash.Query.filter(
        device_id == ^to_id and interface_uid in ^interface_uids and timestamp in ^timestamps
      )
      |> Ash.Query.for_read(:read, %{}, actor: actor)

    case Ash.read(existing_query, actor: actor) do
      {:ok, existing} ->
        existing
        |> Enum.map(&{&1.timestamp, &1.interface_uid})
        |> then(&{:ok, &1})

      {:error, _} = error ->
        error
    end
  end

  defp bulk_update_interfaces([], _to_id, _actor), do: :ok

  defp bulk_update_interfaces(records, to_id, actor) do
    records
    |> Ash.bulk_update(:reassign_device, %{device_id: to_id}, actor: actor)
    |> normalize_bulk_result()
  end

  defp bulk_delete_interfaces([], _actor), do: :ok

  defp bulk_delete_interfaces(records, actor) do
    records
    |> Ash.bulk_destroy(:destroy, %{}, actor: actor)
    |> normalize_bulk_result()
  end

  defp bulk_reassign(resource, action, filter_field, filter_value, attrs, actor) do
    base_query = Ash.Query.for_read(resource, :read, %{}, actor: actor)

    query =
      case filter_field do
        :device_id -> Ash.Query.filter(base_query, device_id == ^filter_value)
        :device_uid -> Ash.Query.filter(base_query, device_uid == ^filter_value)
      end

    case Ash.read(query, actor: actor) do
      {:ok, []} ->
        :ok

      {:ok, records} ->
        records
        |> Ash.bulk_update(action, attrs, actor: actor)
        |> normalize_bulk_result()

      {:error, _} = error ->
        error
    end
  end

  defp normalize_bulk_result(result) do
    case result do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{} = bulk_result -> {:error, bulk_result}
    end
  end

  defp existing_interface_key?(existing_keys, record) when is_list(existing_keys) do
    Enum.member?(existing_keys, {record.timestamp, record.interface_uid})
  end

  defp maybe_add_identifier(acc, _device_id, _id_type, nil, _partition), do: acc

  defp maybe_add_identifier(acc, device_id, :mac, id_value, partition) do
    [
      %{
        device_id: device_id,
        identifier_type: :mac,
        identifier_value: id_value,
        partition: partition,
        confidence: mac_confidence(id_value),
        source: "identity_reconciler"
      }
      | acc
    ]
  end

  defp maybe_add_identifier(acc, device_id, id_type, id_value, partition) do
    [
      %{
        device_id: device_id,
        identifier_type: id_type,
        identifier_value: id_value,
        partition: partition,
        confidence: :strong,
        source: "identity_reconciler"
      }
      | acc
    ]
  end

  @doc """
  Record a device merge in the audit trail.
  """
  @spec record_merge(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
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
  Check if a MAC address is locally administered (IEEE bit 1 of the first octet).

  Locally-administered MACs are generated by virtualization, Docker, overlay networks,
  etc. and are not globally unique. They should be registered with medium confidence.

  ## Examples

      iex> IdentityReconciler.locally_administered_mac?("0EEA1432D278")
      true

      iex> IdentityReconciler.locally_administered_mac?("0CEA1432D278")
      false

      iex> IdentityReconciler.locally_administered_mac?("F692BF75C722")
      true

      iex> IdentityReconciler.locally_administered_mac?("F492BF75C722")
      true
  """
  @spec locally_administered_mac?(String.t() | nil) :: boolean()
  def locally_administered_mac?(nil), do: false

  def locally_administered_mac?(mac) do
    normalized = normalize_mac(mac)

    case normalized do
      nil ->
        false

      normalized when byte_size(normalized) >= 2 ->
        {first_byte, _} = Integer.parse(String.slice(normalized, 0, 2), 16)
        band(first_byte, 0x02) != 0

      _ ->
        false
    end
  end

  @doc """
  Return the appropriate confidence level for a MAC address.
  Locally-administered MACs get :medium, globally-unique MACs get :strong.
  """
  @spec mac_confidence(String.t() | nil) :: :strong | :medium
  def mac_confidence(mac) do
    if locally_administered_mac?(mac), do: :medium, else: :strong
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

  defp partition_from_device_id(device_id) when is_binary(device_id) do
    case String.split(device_id, ":", parts: 2) do
      [partition, _rest] when partition != "sr" -> partition
      _ -> "default"
    end
  end

  defp partition_from_device_id(_), do: "default"
end
