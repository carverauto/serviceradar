defmodule ServiceRadar.Inventory.Identity.Resolver do
  @moduledoc """
  Canonical device-ID resolution: strong-identifier lookups, IP/alias
  fallback, canonical selection among conflicting matches, and
  merge-audit canonical following (tombstone resurrection protection).
  """

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Identity.AliasPolicy
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.MergeAudit

  require Ash.Query
  require Logger

  @max_canonical_follow_depth 5

  @doc """
  Resolve a device update to a canonical ServiceRadar device ID.

  Returns the resolved device ID (either existing or newly generated).
  """
  @spec resolve_device_id(Ids.device_update(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_device_id(update, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    # Skip service component IDs
    if Ids.service_device_id?(update.device_id) do
      {:ok, update.device_id}
    else
      do_resolve_device_id(update, actor)
    end
  end

  @doc """
  Resolve a device update to a canonical device ID **and** the identity revision
  observed at resolution time.

  This is the read half of the identity fence. A consumer that resolves once and
  writes later pins the revision returned here and re-checks it at write time; if
  a merge, unmerge, split, alias invalidation or identifier reassignment happened
  in between, the revision has moved and the write is refused.

  Deliberately a separate function rather than a wider return type on
  `resolve_device_id/2`: that one has callers across ingest, sweep and the Ash
  action layer, and none of them wants a tuple.

  Returns `{:error, :identity_unresolved}` when the resolved id does not name a
  live device -- a service-component id, or a row tombstoned between the
  resolution and this read. A caller that cannot pin cannot fence, and should
  treat that as "re-resolve", never as "proceed unfenced".
  """
  @spec resolve_device_identity(Ids.device_update(), keyword()) ::
          {:ok, {String.t(), integer()}} | {:error, term()}
  def resolve_device_identity(update, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    with {:ok, device_id} <- resolve_device_id(update, opts),
         {:ok, %Device{identity_revision: revision}} when is_integer(revision) <-
           Device.get_by_uid(device_id, false, actor: actor) do
      {:ok, {device_id, revision}}
    else
      {:error, _} = error -> error
      _ -> {:error, :identity_unresolved}
    end
  end

  defp do_resolve_device_id(update, actor) do
    ids = Ids.extract_strong_identifiers(update)

    # Step 1: Lookup by strong identifiers (merge conflicts if multiple IDs found)
    case lookup_by_strong_identifiers(ids, actor, update.device_id) do
      {:ok, device_id} when is_binary(device_id) and device_id != "" ->
        _ = AliasGuard.maybe_merge_ip_alias_device(device_id, ids, actor)
        {:ok, maybe_merge_hardware_mac_siblings(device_id, ids, update, actor)}

      _ ->
        case lookup_hardware_mac_sibling_device(ids, update, actor) do
          {:ok, device_id} when is_binary(device_id) and device_id != "" ->
            _ = AliasGuard.maybe_merge_ip_alias_device(device_id, ids, actor)
            {:ok, device_id}

          _ ->
            resolve_fallback_device_id(update, ids, actor)
        end
    end
  end

  defp resolve_fallback_device_id(update, ids, actor) do
    cond do
      Ids.serviceradar_uuid?(update.device_id) ->
        {:ok, follow_canonical_device_id(update.device_id, actor)}

      Ids.has_strong_identifier?(ids) ->
        {:ok, follow_canonical_device_id(Ids.generate_deterministic_device_id(ids), actor)}

      true ->
        case lookup_by_ip(ids, actor) do
          {:ok, device_id} when is_binary(device_id) and device_id != "" ->
            {:ok, device_id}

          _ ->
            {:ok, follow_canonical_device_id(Ids.generate_deterministic_device_id(ids), actor)}
        end
    end
  end

  @max_canonical_follow_depth 5

  @doc """
  Follow the merge-audit canonical mapping for a device ID.

  A device that was merged away must never be resurrected by a later update
  that re-derives its deterministic UID (or still carries the old `sr:` ID).
  When the given device is tombstoned by a merge, resolution follows the
  audit trail to the live canonical device. Live (or never-seen) IDs are
  returned unchanged, so unmerged/recreated devices are respected.
  """
  @spec follow_canonical_device_id(String.t(), term()) :: String.t()
  def follow_canonical_device_id(device_id, actor),
    do: do_follow_canonical(device_id, actor, @max_canonical_follow_depth)

  defp do_follow_canonical(device_id, _actor, 0), do: device_id

  defp do_follow_canonical(device_id, actor, depth) do
    with true <- Ids.serviceradar_uuid?(device_id),
         {:ok, %Device{deleted_at: %_{}}} <- Device.get_by_uid(device_id, true, actor: actor),
         canonical_id when is_binary(canonical_id) and canonical_id != device_id <-
           latest_merge_target(device_id, actor) do
      do_follow_canonical(canonical_id, actor, depth - 1)
    else
      _ -> device_id
    end
  rescue
    e ->
      Logger.warning("Canonical follow failed for #{device_id}: #{inspect(e)}")
      device_id
  end

  defp latest_merge_target(device_id, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    MergeAudit
    # `unmerge` rows are symmetric cooldown/audit evidence, not canonical
    # redirects. Following one after the former survivor is later tombstoned
    # can otherwise redirect it to an arbitrary split/restored device.
    |> Ash.Query.filter(from_device_id == ^device_id and (is_nil(reason) or reason != "unmerge"))
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read(query_opts)
    |> case do
      {:ok, [%MergeAudit{to_device_id: to_device_id} | _]} -> to_device_id
      _ -> nil
    end
  end

  @doc """
  Lookup device by strong identifiers in priority order.
  """
  @spec lookup_by_strong_identifiers(Ids.strong_identifiers(), term(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def lookup_by_strong_identifiers(ids, actor, preferred_device_id \\ nil) do
    if Ids.has_strong_identifier?(ids) do
      matches = lookup_identifier_matches(ids, actor)
      device_ids = matches |> Map.values() |> Enum.map(& &1.device_id) |> Enum.uniq()

      case device_ids do
        [] ->
          {:ok, nil}

        [device_id] ->
          {:ok, device_id}

        _ ->
          canonical_id = select_canonical_device_id(preferred_device_id, matches, actor)
          _ = MergeEngine.merge_conflicting_devices(canonical_id, device_ids, matches, actor)
          {:ok, canonical_id}
      end
    else
      {:ok, nil}
    end
  end

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
  @spec lookup_by_ip(Ids.strong_identifiers(), term(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def lookup_by_ip(ids, actor, opts \\ []) do
    allow_strong = Keyword.get(opts, :allow_strong, false)
    ip = Ids.ids_get_string(ids, :ip)
    partition = Ids.ids_get_partition(ids)

    if (Ids.has_strong_identifier?(ids) and not allow_strong) or ip == "" do
      {:ok, nil}
    else
      case lookup_alias_device_id(ip, partition, actor) do
        {:ok, device_id} when is_binary(device_id) and device_id != "" ->
          {:ok, device_id}

        _ ->
          do_lookup_by_ip(ip, partition, actor)
      end
    end
  end

  defp do_lookup_by_ip(ip, partition, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    Device
    |> Ash.Query.for_read(:by_ip, %{ip: ip, partition: partition})
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
    if AliasPolicy.valid_alias_ip?(ip) do
      do_lookup_alias_device_id(ip, partition, actor, opts)
    else
      {:ok, nil}
    end
  end

  defp do_lookup_alias_device_id(ip, partition, actor, opts) do
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

  def maybe_filter_alias_partition(query, nil), do: query
  def maybe_filter_alias_partition(query, ""), do: query

  def maybe_filter_alias_partition(query, partition) do
    Ash.Query.filter(query, partition == ^partition)
  end

  def lookup_identifier_matches(ids, actor) do
    partition = Ids.ids_get_partition(ids)

    Enum.reduce(Ids.identifier_priority(), %{}, fn id_type, acc ->
      id_type
      |> Ids.get_identifier_values(ids)
      |> Enum.find_value(fn id_value ->
        with {:ok, device_id} when is_binary(device_id) and device_id != "" <-
               lookup_device_identifier(id_type, id_value, partition, actor),
             true <- trusted_identifier_match?(id_type, id_value, device_id, actor) do
          %{value: id_value, device_id: device_id}
        else
          _ -> nil
        end
      end)
      |> case do
        nil -> acc
        match -> Map.put(acc, id_type, match)
      end
    end)
  end

  defp trusted_identifier_match?(:agent_id, agent_id, device_id, actor) do
    case Device.get_by_uid(device_id, true, actor: actor) do
      {:ok, %Device{deleted_at: %_{} = _deleted_at}} ->
        false

      {:ok, %Device{agent_id: existing_agent_id}} ->
        existing_agent_id = existing_agent_id |> to_string() |> String.trim()
        existing_agent_id == "" or existing_agent_id == agent_id

      _ ->
        true
    end
  rescue
    _ -> true
  end

  defp trusted_identifier_match?(_id_type, _id_value, _device_id, _actor), do: true

  def select_canonical_device_id(preferred_device_id, matches, actor) do
    device_ids = matches |> Map.values() |> Enum.map(& &1.device_id) |> Enum.uniq()

    if Ids.serviceradar_uuid?(preferred_device_id) and preferred_device_id in device_ids do
      preferred_device_id
    else
      case highest_priority_match(matches) do
        nil -> most_recent_device_id(device_ids, actor)
        device_id -> device_id
      end
    end
  end

  defp highest_priority_match(matches) do
    Enum.find_value(Ids.identifier_priority(), fn id_type ->
      case Map.get(matches, id_type) do
        %{device_id: device_id} -> device_id
        _ -> nil
      end
    end)
  end

  defp lookup_hardware_mac_sibling_device(ids, update, actor) do
    partition = Ids.ids_get_partition(ids)

    ids
    |> sibling_mac_candidates(update)
    |> Enum.map(&Mac.hardware_mac_sibling/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn sibling ->
      case lookup_device_identifier(:mac, sibling, partition, actor) do
        {:ok, device_id} when is_binary(device_id) and device_id != "" -> device_id
        _ -> nil
      end
    end)
    |> case do
      device_id when is_binary(device_id) -> {:ok, device_id}
      _ -> {:ok, nil}
    end
  end

  # Prefer the universally-administered MAC as the survivor so a UniFi WAN
  # identity absorbs the SNMP LAN sibling, not the other way around.
  defp maybe_merge_hardware_mac_siblings(device_id, ids, update, actor) do
    partition = Ids.ids_get_partition(ids)

    ids
    |> sibling_mac_candidates(update)
    |> Enum.reduce(device_id, fn mac, acc ->
      merge_hardware_mac_sibling(acc, mac, partition, actor)
    end)
  end

  defp merge_hardware_mac_sibling(device_id, mac, partition, actor) do
    sibling = Mac.hardware_mac_sibling(mac)

    with true <- is_binary(sibling),
         {:ok, other_id} when is_binary(other_id) and other_id != device_id <-
           lookup_device_identifier(:mac, sibling, partition, actor) do
      {from_id, to_id} = hardware_mac_merge_direction(device_id, other_id, mac)

      case MergeEngine.merge_devices(from_id, to_id,
             actor: actor,
             reason: "hardware_mac_sibling",
             details: %{
               source: "identity_reconciler",
               mac: mac,
               sibling_mac: sibling
             }
           ) do
        :ok -> to_id
        _ -> device_id
      end
    else
      _ -> device_id
    end
  end

  defp hardware_mac_merge_direction(device_id, other_id, incoming_mac) do
    if Mac.locally_administered_mac?(incoming_mac) do
      {device_id, other_id}
    else
      {other_id, device_id}
    end
  end

  defp sibling_mac_candidates(ids, update) do
    metadata =
      case update do
        %{metadata: metadata} when is_map(metadata) -> metadata
        %{"metadata" => metadata} when is_map(metadata) -> metadata
        _ -> %{}
      end

    (Ids.mac_lookup_values(ids) ++ alt_macs_from_metadata(metadata))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp alt_macs_from_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.flat_map(fn {key, _} ->
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

  def most_recent_device_id([], _actor), do: nil

  def most_recent_device_id(device_ids, actor) do
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

  defp select_ip_device([]), do: nil

  defp select_ip_device(devices) do
    valid_devices =
      Enum.reject(devices, fn device ->
        metadata = device.metadata || %{}

        Map.has_key?(metadata, "_merged_into") or
          String.downcase(to_string(metadata["_deleted"] || "")) == "true" or
          not is_nil(device.deleted_at) or
          Ids.service_device_id?(device.uid)
      end)

    candidates = Enum.filter(valid_devices, &Ids.serviceradar_uuid?(&1.uid))
    candidates = if candidates == [], do: valid_devices, else: candidates

    Enum.max_by(candidates, &device_seen_score/1, fn -> nil end)
  end

  defp select_ip_device_id(devices) do
    case select_ip_device(devices) do
      %Device{uid: uid} ->
        if Ids.serviceradar_uuid?(uid), do: uid

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
end
