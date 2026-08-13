defmodule ServiceRadar.Inventory.Identity.BatchResolver do
  @moduledoc """
  Batch device resolution sharing the single-update decision semantics of
  `Identity.Resolver`, fed by preloaded lookup maps for bulk ingest paths.

  Decision order per update (mirrors `Resolver.resolve_device_id/2`):

    1. service-component IDs pass through
    2. strong-identifier match from the preloaded identifier map
       (agent_id matches are trusted-checked; merged-away devices are
       followed to their canonical survivor)
    3. pre-set `sr:` device_id — a hint only, canonical-followed
    4. deterministic UID when strong identifiers exist (canonical-followed)
    5. IP/alias map fallback ONLY when no strong identifier is present
    6. deterministic (IP-seeded) or random UID

  Step 5's gate is load-bearing: resolving strong-identified updates by
  IP collapsed distinct integration devices onto whichever device
  happened to hold the IP (the 500-per-batch integration_id pile-ups).
  """

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.Resolver

  require Ash.Query
  require Logger

  # Non-MAC strong identifiers that anchor an existing canonical. A shared
  # value of any of these (notably armis_device_id, which an Armis "device"
  # aggregates across a whole scanned subnet) must NOT collapse a record that
  # carries its own distinct hardware MAC onto that canonical — see
  # `distinct_mac_veto?/3`.
  @non_mac_strong_identifiers [
    :armis_device_id,
    :integration_id,
    :netbox_device_id,
    :hardware_serial
  ]

  @type lookup_key :: {atom(), String.t(), String.t()}
  @type lookups :: %{identifiers: %{lookup_key() => String.t()}, ip: %{String.t() => String.t()}}

  @doc """
  Resolve a batch of `{update, ids}` pairs.

  Returns `{resolved, strong_uids}` where `resolved` is `[{update, device_id}]`
  in input order and `strong_uids` is the set of device IDs that were claimed
  by updates carrying strong identifiers (such records must never be
  IP-remapped onto other devices by conflict recovery).
  """
  @spec resolve_batch([{map(), Ids.strong_identifiers()}], lookups(), term()) ::
          {[{map(), String.t()}], MapSet.t()}
  def resolve_batch(updates_with_ids, lookups, actor) do
    trusted = preload_agent_trust(updates_with_ids, lookups, actor)
    canonical_macs = preload_canonical_macs(updates_with_ids, lookups, actor)

    # Phase 1: candidate decision per update (no per-update queries).
    {candidates_rev, _ip_map} =
      Enum.reduce(updates_with_ids, {[], lookups.ip}, fn {update, ids}, {acc, ip_map} ->
        device_id = resolve_one(update, ids, lookups.identifiers, ip_map, trusted, canonical_macs)

        # Later weak updates in the same batch may adopt this device by IP;
        # strong-identified updates never consult the IP map.
        ip_map =
          case ids.ip do
            ip when is_binary(ip) and ip != "" -> Map.put(ip_map, ip, device_id)
            _ -> ip_map
          end

        {[{update, ids, device_id} | acc], ip_map}
      end)

    candidates = Enum.reverse(candidates_rev)

    # Phase 2: one bulk query finds tombstoned candidates; only those are
    # canonical-followed (merged-away IDs must not be resurrected).
    canonical = canonical_mapping(candidates, actor)

    # Phase 3: if this batch already owns both sides of a UAA/LAA NIC pair
    # on different devices, merge the LAA sibling into the UAA survivor
    # before upsert. Identifier ownership is never stolen by upsert.
    candidates =
      heal_hardware_mac_siblings(candidates, lookups.identifiers, actor)

    candidates
    |> Enum.reduce({[], MapSet.new()}, fn {update, ids, device_id}, {acc, strong} ->
      final_id = Map.get(canonical, device_id, device_id)

      strong =
        if Ids.has_strong_identifier?(ids), do: MapSet.put(strong, final_id), else: strong

      {[{update, final_id} | acc], strong}
    end)
    |> then(fn {resolved_rev, strong} -> {Enum.reverse(resolved_rev), strong} end)
  end

  defp resolve_one(update, ids, identifier_map, ip_map, trusted, canonical_macs) do
    cond do
      Ids.service_device_id?(update.device_id) ->
        update.device_id

      device_id = strong_match(ids, identifier_map, trusted, canonical_macs) ->
        device_id

      Ids.serviceradar_uuid?(update.device_id) ->
        update.device_id

      Ids.has_strong_identifier?(ids) ->
        Ids.generate_deterministic_device_id(ids)

      true ->
        case weak_ip_match(ids, ip_map) do
          nil -> Ids.generate_deterministic_device_id(ids)
          device_id -> device_id
        end
    end
  end

  # Maps tombstoned candidate IDs to their canonical survivors. Live and
  # never-seen IDs are absent from the map (callers keep the candidate).
  defp canonical_mapping(candidates, actor) do
    candidate_ids =
      candidates
      |> Enum.map(fn {_u, _ids, device_id} -> device_id end)
      |> Enum.filter(&Ids.serviceradar_uuid?/1)
      |> Enum.uniq()

    tombstoned = tombstoned_ids(candidate_ids, actor)

    Map.new(tombstoned, fn device_id ->
      {device_id, Resolver.follow_canonical_device_id(device_id, actor)}
    end)
  end

  defp tombstoned_ids([], _actor), do: []

  defp tombstoned_ids(candidate_ids, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid in ^candidate_ids and not is_nil(deleted_at))
    |> Ash.Query.select([:uid])
    |> Ash.read(query_opts)
    |> Page.unwrap()
    |> case do
      {:ok, devices} -> Enum.map(devices, & &1.uid)
      {:error, _} -> []
    end
  rescue
    e ->
      Logger.warning("BatchResolver: tombstone check failed: #{inspect(e)}")
      []
  end

  defp strong_match(ids, identifier_map, trusted, canonical_macs) do
    incoming_macs = incoming_universal_macs(ids)

    Enum.find_value(Ids.identifier_priority(), fn id_type ->
      id_type
      |> Ids.get_identifier_values(ids)
      |> Enum.find_value(fn value ->
        case Map.get(identifier_map, {id_type, value, ids.partition}) do
          nil ->
            if id_type == :mac do
              hardware_mac_sibling_match(value, ids, identifier_map)
            end

          device_id ->
            cond do
              # agent_id keeps its existing trusted-match gate.
              id_type == :agent_id ->
                if trusted_agent_match?(trusted, value, device_id), do: device_id

              # A direct MAC match is self-consistent when it is the canonical
              # device's current primary MAC. Armis also reports historical
              # MACs; if a typed ID is new and only a historical MAC matches,
              # the typed ID must win and resolve to its own deterministic UID.
              id_type == :mac ->
                if ids.armis_id not in [nil, ""] and
                     historical_mac_veto?(canonical_macs, device_id, incoming_macs) do
                  emit_distinct_mac_veto(:mac, value, device_id, incoming_macs, canonical_macs)
                  nil
                else
                  device_id
                end

              # Non-MAC strong identifiers (armis/integration/netbox) are the
              # over-merge vector: refuse to attach an incoming record carrying
              # its own distinct hardware MAC onto a canonical whose hardware
              # MAC set is disjoint. Returning nil here falls through to a NEW
              # deterministic per-device UID in resolve_one/6.
              distinct_mac_veto?(canonical_macs, device_id, incoming_macs) ->
                emit_distinct_mac_veto(id_type, value, device_id, incoming_macs, canonical_macs)
                nil

              true ->
                device_id
            end
        end
      end)
    end)
  end

  # The set of UNIVERSALLY-administered (globally-unique, hardware-anchor) MACs
  # carried by the incoming record. Locally-administered MACs (virtual NICs,
  # Docker, overlay networks) are excluded — they are not hardware anchors and
  # must never drive a device split, exactly as DuplicateSweep/MergePolicy
  # already treat them.
  defp incoming_universal_macs(ids) do
    :mac
    |> Ids.get_identifier_values(ids)
    |> universal_macs()
  end

  # Atomic, universally-administered (hardware-anchor) MACs from a list of raw
  # identifier values. The hardware-identity unit is defined once in
  # `Identity.Mac.universal_macs/1` (blob rows normalized to atomic MACs first so
  # the incoming and canonical sides compare on the same atomic basis, then
  # locally-administered NICs dropped) and reused by the un-merge remediation so
  # detection provably cannot drift from this veto.
  defp universal_macs(values), do: Mac.universal_macs(values)

  # Behavioral distinct-hardware veto. Fires ONLY when (a) the matched canonical
  # already holds >=1 universally-administered MAC, AND (b) the incoming record
  # carries >=1 universally-administered MAC, AND (c) the two sets are DISJOINT.
  # Same-device re-observation always shares >=1 MAC (or carries none / only
  # locally-administered) -> not disjoint or one side empty -> no veto.
  defp distinct_mac_veto?(canonical_macs, device_id, incoming_macs) do
    existing = canonical_mac_set(canonical_macs, device_id)
    Mac.distinct_hardware?(existing, incoming_macs)
  end

  defp historical_mac_veto?(canonical_macs, device_id, incoming_macs) do
    primary = canonical_primary_mac_set(canonical_macs, device_id)

    MapSet.size(primary) > 0 and
      MapSet.size(incoming_macs) > 0 and
      MapSet.disjoint?(primary, incoming_macs)
  end

  defp canonical_mac_set(canonical_macs, device_id) do
    canonical_macs
    |> Map.get(device_id, %{})
    |> Map.get(:all, MapSet.new())
  end

  defp canonical_primary_mac_set(canonical_macs, device_id) do
    canonical_macs
    |> Map.get(device_id, %{})
    |> Map.get(:primary, MapSet.new())
  end

  defp emit_distinct_mac_veto(id_type, value, device_id, incoming_macs, canonical_macs) do
    existing = canonical_mac_set(canonical_macs, device_id)

    Logger.info(
      "BatchResolver: distinct-MAC veto — refusing #{id_type}=#{value} attach onto " <>
        "#{device_id} (canonical universal MACs #{inspect(MapSet.to_list(existing))} disjoint " <>
        "from incoming #{inspect(MapSet.to_list(incoming_macs))}); splitting to a new device"
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :resolve, :distinct_mac_veto],
      %{count: 1},
      %{
        identifier_type: id_type,
        identifier_value: value,
        canonical_device_id: device_id,
        incoming_mac_count: MapSet.size(incoming_macs),
        canonical_mac_count: MapSet.size(existing)
      }
    )

    :ok
  end

  defp weak_ip_match(ids, ip_map) do
    case ids.ip do
      ip when is_binary(ip) and ip != "" -> Map.get(ip_map, ip)
      _ -> nil
    end
  end

  # First-sighting attach: the incoming MAC is new, but its IEEE LAA/UAA
  # sibling is already registered. Resolve onto that device so SNMP F6
  # never mints a second farm01 next to UniFi F4.
  defp hardware_mac_sibling_match(mac, ids, identifier_map) do
    case Mac.hardware_mac_sibling(mac) do
      nil ->
        nil

      sibling ->
        Map.get(identifier_map, {:mac, sibling, ids.partition})
    end
  end

  defp heal_hardware_mac_siblings(candidates, identifier_map, actor) do
    Enum.map(candidates, fn {update, ids, device_id} ->
      {update, ids, maybe_merge_hardware_mac_sibling(device_id, ids, identifier_map, actor)}
    end)
  end

  defp maybe_merge_hardware_mac_sibling(device_id, ids, identifier_map, actor) do
    :mac
    |> Ids.get_identifier_values(ids)
    |> Enum.reduce(device_id, fn mac, acc ->
      merge_loaded_hardware_mac_sibling(acc, mac, ids, identifier_map, actor)
    end)
  end

  defp merge_loaded_hardware_mac_sibling(device_id, mac, ids, identifier_map, actor) do
    sibling = Mac.hardware_mac_sibling(mac)
    other_id = sibling && Map.get(identifier_map, {:mac, sibling, ids.partition})

    if is_binary(other_id) and other_id != device_id do
      {from_id, to_id} =
        if Mac.locally_administered_mac?(mac) do
          {device_id, other_id}
        else
          {other_id, device_id}
        end

      case MergeEngine.merge_devices(from_id, to_id,
             actor: actor,
             reason: "hardware_mac_sibling",
             details: %{
               source: "batch_resolver",
               mac: mac,
               sibling_mac: sibling
             }
           ) do
        :ok -> to_id
        _ -> device_id
      end
    else
      device_id
    end
  end

  # Bulk-load device rows referenced by agent_id identifier matches so the
  # trusted-match check (device must be live and not bound to a different
  # agent) does not issue one query per update.
  defp preload_agent_trust(updates_with_ids, lookups, actor) do
    candidate_ids =
      updates_with_ids
      |> Enum.flat_map(fn {_update, ids} ->
        case Ids.get_identifier_values(:agent_id, ids) do
          [] ->
            []

          values ->
            Enum.flat_map(values, fn value ->
              case Map.get(lookups.identifiers, {:agent_id, value, ids.partition}) do
                nil -> []
                device_id -> [device_id]
              end
            end)
        end
      end)
      |> Enum.uniq()

    if candidate_ids == [] do
      %{}
    else
      query_opts = if actor, do: [actor: actor], else: []

      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid in ^candidate_ids)
      |> Ash.Query.select([:uid, :agent_id, :deleted_at])
      |> Ash.read(query_opts)
      |> Page.unwrap()
      |> case do
        {:ok, devices} ->
          Map.new(devices, fn d ->
            {d.uid, %{agent_id: d.agent_id, deleted?: !is_nil(d.deleted_at)}}
          end)

        {:error, error} ->
          Logger.warning("BatchResolver: agent trust preload failed: #{inspect(error)}")
          %{}
      end
    end
  rescue
    e ->
      Logger.warning("BatchResolver: agent trust preload failed: #{inspect(e)}")
      %{}
  end

  # Bulk-load the universally-administered MAC set already held by each
  # candidate canonical reachable via a NON-MAC strong identifier
  # (armis_device_id / integration_id / netbox_device_id) in this batch.
  # Armis updates also preload the current primary MAC for devices reachable
  # through a MAC lookup. Armis carries historical MACs, so a newly-seen typed
  # Armis ID must not attach to a different device merely because one of its
  # historical MACs is present on that device.
  defp preload_canonical_macs(updates_with_ids, lookups, actor) do
    candidate_ids =
      updates_with_ids
      |> Enum.flat_map(fn {_update, ids} ->
        non_mac_matches =
          for id_type <- @non_mac_strong_identifiers,
              value <- Ids.get_identifier_values(id_type, ids),
              device_id = Map.get(lookups.identifiers, {id_type, value, ids.partition}),
              not is_nil(device_id),
              do: device_id

        mac_matches =
          if ids.armis_id in [nil, ""] do
            []
          else
            for value <- Ids.get_identifier_values(:mac, ids),
                device_id = Map.get(lookups.identifiers, {:mac, value, ids.partition}),
                not is_nil(device_id),
                do: device_id
          end

        non_mac_matches ++ mac_matches
      end)
      |> Enum.uniq()

    if candidate_ids == [] do
      %{}
    else
      query_opts = if actor, do: [actor: actor], else: []

      identifier_macs =
        DeviceIdentifier
        |> Ash.Query.filter(device_id in ^candidate_ids and identifier_type == :mac)
        |> Ash.Query.select([:device_id, :identifier_value])
        |> Ash.read(query_opts)
        |> Page.unwrap()
        |> case do
          {:ok, identifiers} ->
            identifiers
            |> Enum.group_by(& &1.device_id, & &1.identifier_value)
            |> Map.new(fn {device_id, macs} -> {device_id, universal_macs(macs)} end)

          {:error, error} ->
            Logger.warning("BatchResolver: canonical MAC preload failed: #{inspect(error)}")
            %{}
        end

      primary_macs =
        Device
        |> Ash.Query.filter(uid in ^candidate_ids)
        |> Ash.Query.select([:uid, :mac])
        |> Ash.read(query_opts)
        |> Page.unwrap()
        |> case do
          {:ok, devices} ->
            Map.new(devices, fn device ->
              {device.uid, universal_macs(List.wrap(device.mac))}
            end)

          {:error, error} ->
            Logger.warning(
              "BatchResolver: canonical primary MAC preload failed: #{inspect(error)}"
            )

            %{}
        end

      Map.new(candidate_ids, fn device_id ->
        {device_id,
         %{
           all: Map.get(identifier_macs, device_id, MapSet.new()),
           primary: Map.get(primary_macs, device_id, MapSet.new())
         }}
      end)
    end
  rescue
    e ->
      Logger.warning("BatchResolver: canonical MAC preload failed: #{inspect(e)}")
      %{}
  end

  defp trusted_agent_match?(trusted, agent_id, device_id) do
    case Map.get(trusted, device_id) do
      nil ->
        true

      %{deleted?: true} ->
        false

      %{agent_id: existing} ->
        existing = existing |> to_string() |> String.trim()
        existing == "" or existing == agent_id
    end
  end
end
