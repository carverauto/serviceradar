defmodule ServiceRadar.Inventory.Identity.BatchResolver do
  @moduledoc """
  Batch device resolution sharing the single-update decision semantics of
  `Identity.Resolver`, fed by preloaded lookup maps for bulk ingest paths.

  Decision order per update (mirrors `Resolver.resolve_device_id/2`):

    1. service-component IDs pass through
    2. strong-identifier match from the preloaded identifier map
       (agent_id matches are trusted-checked; merged-away devices are
       followed to their canonical survivor). An update carrying a
       source-authoritative identifier never matches a record holding a
       different one: the source-authoritative identifier decides, the shared
       identifier is evidence only, and the override is recorded
       (`SourceAuthorityGuard.record_overrides/1`).
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
  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard
  alias ServiceRadar.Inventory.MergeAudit

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
    preloads = %{
      identifiers: lookups.identifiers,
      trusted: preload_agent_trust(updates_with_ids, lookups, actor),
      canonical_macs: preload_canonical_macs(updates_with_ids, lookups, actor),
      source_ids: preload_source_ids(updates_with_ids, lookups, actor)
    }

    # Phase 1: candidate decision per update (no per-update queries). Each
    # resolved update claims its source-authoritative identifier on the device
    # it resolved to, so a later update in the batch carrying a different one
    # is refused that device exactly as if the database already held the claim.
    {candidates_rev, _ip_map, source_ids} =
      Enum.reduce(updates_with_ids, {[], lookups.ip, preloads.source_ids}, fn
        {update, ids}, {acc, ip_map, claimed} ->
          device_id = resolve_one(update, ids, ip_map, %{preloads | source_ids: claimed})

          # Later weak updates in the same batch may adopt this device by IP;
          # strong-identified updates never consult the IP map.
          ip_map =
            case ids.ip do
              ip when is_binary(ip) and ip != "" -> Map.put(ip_map, ip, device_id)
              _ -> ip_map
            end

          {[{update, ids, device_id} | acc], ip_map, claim_source_id(claimed, ids, device_id)}
      end)

    preloads = %{preloads | source_ids: source_ids}

    candidates = Enum.reverse(candidates_rev)

    # Phase 2: bulk queries find tombstoned candidates and candidates whose row
    # is gone but that were merged away; only those are canonical-followed
    # (merged-away IDs must not be resurrected, purged or not).
    canonical = canonical_mapping(candidates, actor)

    # Phase 3: if this batch already owns both sides of a UAA/LAA NIC pair
    # on different devices, merge the LAA sibling into the UAA survivor
    # before upsert. Identifier ownership is never stolen by upsert.
    candidates =
      heal_hardware_mac_siblings(candidates, preloads, actor)

    {resolved_rev, strong, overrides_rev} =
      Enum.reduce(candidates, {[], MapSet.new(), []}, fn {update, ids, device_id},
                                                         {acc, strong, overrides} ->
        final_id = Map.get(canonical, device_id, device_id)

        strong =
          if Ids.has_strong_identifier?(ids), do: MapSet.put(strong, final_id), else: strong

        overrides =
          case source_overrides(ids, final_id, preloads) do
            [] ->
              overrides

            overridden ->
              [
                %{update: update, ids: ids, device_uid: final_id, overridden: overridden}
                | overrides
              ]
          end

        {[{update, final_id} | acc], strong, overrides}
      end)

    _ = SourceAuthorityGuard.record_overrides(Enum.reverse(overrides_rev))

    {Enum.reverse(resolved_rev), strong}
  end

  defp claim_source_id(source_ids, ids, device_id) do
    case Ids.ids_get(ids, :armis_id) do
      value when is_binary(value) and value != "" ->
        Map.update(
          source_ids,
          device_id,
          MapSet.new([{Ids.ids_get_partition(ids), value}]),
          &MapSet.put(&1, {Ids.ids_get_partition(ids), value})
        )

      _ ->
        source_ids
    end
  end

  defp resolve_one(update, ids, ip_map, preloads) do
    cond do
      Ids.service_device_id?(update.device_id) ->
        update.device_id

      device_id = strong_match(ids, preloads) ->
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

  # Maps tombstoned or purged-after-merge candidate IDs to their canonical
  # survivors. Live and never-seen IDs are absent from the map (callers keep
  # the candidate).
  defp canonical_mapping(candidates, actor) do
    candidate_ids =
      candidates
      |> Enum.map(fn {_u, _ids, device_id} -> device_id end)
      |> Enum.filter(&Ids.serviceradar_uuid?/1)
      |> Enum.uniq()

    followed = tombstoned_ids(candidate_ids, actor) ++ purged_merged_ids(candidate_ids, actor)

    Map.new(followed, fn device_id ->
      {device_id, Resolver.follow_canonical_device_id(device_id, actor)}
    end)
  end

  # Candidates with no device row at all that a merge_audit row names as merged
  # away: the tombstone was purged after retention (or the merge predates
  # tombstoning), and merge_audit outlived it. Resolver.follow_canonical_device_id/2
  # decides whether the merge still redirects (an unmerge may have reversed it).
  # Brand-new ids have no merge row, so they cost only the two bulk reads here.
  @doc false
  def purged_merged_ids([], _actor), do: []

  def purged_merged_ids(candidate_ids, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    existing =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid in ^candidate_ids)
      |> Ash.Query.select([:uid])
      |> Page.stream!(query_opts)
      |> MapSet.new(& &1.uid)

    case Enum.reject(candidate_ids, &MapSet.member?(existing, &1)) do
      [] ->
        []

      absent ->
        MergeAudit
        |> Ash.Query.filter(from_device_id in ^absent and (is_nil(reason) or reason != "unmerge"))
        |> Ash.Query.select([:from_device_id])
        |> Ash.read!(query_opts)
        |> Enum.map(& &1.from_device_id)
        |> Enum.uniq()
    end
  rescue
    e ->
      Logger.warning("BatchResolver: purged-merge check failed: #{inspect(e)}")
      reraise e, __STACKTRACE__
  end

  @doc false
  def tombstoned_ids([], _actor), do: []

  def tombstoned_ids(candidate_ids, actor) do
    query_opts = if actor, do: [actor: actor], else: []

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true})
    |> Ash.Query.filter(uid in ^candidate_ids and not is_nil(deleted_at))
    |> Ash.Query.select([:uid])
    |> Page.stream!(query_opts)
    |> Enum.map(& &1.uid)
  rescue
    e ->
      Logger.warning("BatchResolver: tombstone check failed: #{inspect(e)}")
      reraise e, __STACKTRACE__
  end

  defp strong_match(ids, preloads) do
    %{identifiers: identifier_map, trusted: trusted, canonical_macs: canonical_macs} = preloads
    incoming_macs = incoming_universal_macs(ids)

    Enum.find_value(Ids.identifier_priority(), fn id_type ->
      id_type
      |> Ids.get_identifier_values(ids)
      |> Enum.find_value(fn value ->
        case Map.get(identifier_map, {id_type, value, ids.partition}) do
          nil when id_type == :mac ->
            sibling = hardware_mac_sibling_match(value, ids, identifier_map)
            if is_binary(sibling) and not source_mismatch?(ids, sibling, preloads), do: sibling

          nil ->
            nil

          device_id ->
            cond do
              # The update's source-authoritative identifier decides: a record
              # holding a different one is not a match, whatever it shares.
              source_mismatch?(ids, device_id, preloads) ->
                nil

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

  defp source_mismatch?(ids, device_id, preloads),
    do: SourceAuthorityGuard.source_mismatch?(ids, device_id, preloads.source_ids)

  # The records this update's identifiers resolve to that hold a different
  # source-authoritative identifier: the matches the source-authoritative
  # identifier overrode. Checked over every identifier, not only the one that
  # decided, so a record keeps being reported while it shares identifiers with
  # the update.
  defp source_overrides(_ids, _final_id, preloads) when map_size(preloads.source_ids) == 0, do: []

  defp source_overrides(ids, final_id, preloads) do
    for id_type <- Ids.identifier_priority(),
        id_type != :armis_device_id,
        value <- Ids.get_identifier_values(id_type, ids),
        device_id <- identifier_owners(id_type, value, ids, preloads.identifiers),
        device_id != final_id,
        source_mismatch?(ids, device_id, preloads) do
      %{
        device_uid: device_id,
        identifier_type: id_type,
        identifier_value: value,
        source_ids:
          SourceAuthorityGuard.scoped_source_ids(
            preloads.source_ids,
            device_id,
            Ids.ids_get_partition(ids)
          )
      }
    end
  end

  # The devices an identifier value names, including a MAC's hardware sibling
  # owner, which the sibling merge can combine with the resolved device.
  defp identifier_owners(id_type, value, ids, identifier_map) do
    owners = [Map.get(identifier_map, {id_type, value, ids.partition})]

    owners =
      if id_type == :mac,
        do: [hardware_mac_sibling_match(value, ids, identifier_map) | owners],
        else: owners

    owners |> Enum.filter(&is_binary/1) |> Enum.uniq()
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

  defp heal_hardware_mac_siblings(candidates, preloads, actor) do
    Enum.map(candidates, fn {update, ids, device_id} ->
      {update, ids, maybe_merge_hardware_mac_sibling(device_id, ids, preloads, actor)}
    end)
  end

  defp maybe_merge_hardware_mac_sibling(device_id, ids, preloads, actor) do
    :mac
    |> Ids.get_identifier_values(ids)
    |> Enum.reduce(device_id, fn mac, acc ->
      merge_loaded_hardware_mac_sibling(acc, mac, ids, preloads, actor)
    end)
  end

  defp merge_loaded_hardware_mac_sibling(device_id, mac, ids, preloads, actor) do
    sibling = Mac.hardware_mac_sibling(mac)
    other_id = sibling && Map.get(preloads.identifiers, {:mac, sibling, ids.partition})

    if is_binary(other_id) and other_id != device_id and
         not source_mismatch?(ids, other_id, preloads) do
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
  @doc false
  def preload_agent_trust(updates_with_ids, lookups, actor) do
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
      |> Page.stream!(query_opts)
      |> Map.new(fn d ->
        {d.uid, %{agent_id: d.agent_id, deleted?: !is_nil(d.deleted_at)}}
      end)
    end
  rescue
    e ->
      Logger.warning("BatchResolver: agent trust preload failed: #{inspect(e)}")
      reraise e, __STACKTRACE__
  end

  # Bulk-load the universally-administered MAC set already held by each
  # candidate canonical reachable via a NON-MAC strong identifier
  # (armis_device_id / integration_id / netbox_device_id) in this batch.
  # Armis updates also preload the current primary MAC for devices reachable
  # through a MAC lookup. Armis carries historical MACs, so a newly-seen typed
  # Armis ID must not attach to a different device merely because one of its
  # historical MACs is present on that device.
  @doc false
  def preload_canonical_macs(updates_with_ids, lookups, actor) do
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
        |> Page.stream!(query_opts)
        |> Enum.group_by(& &1.device_id, & &1.identifier_value)
        |> Map.new(fn {device_id, macs} -> {device_id, universal_macs(macs)} end)

      # A soft delete leaves the identifier rows in place, and an empty primary
      # set disables `historical_mac_veto?/3`, so the read must include tombstones
      # like the other two preloads in this function.
      primary_macs =
        Device
        |> Ash.Query.for_read(:read, %{include_deleted: true})
        |> Ash.Query.filter(uid in ^candidate_ids)
        |> Ash.Query.select([:uid, :mac])
        |> Page.stream!(query_opts)
        |> Map.new(fn device ->
          {device.uid, universal_macs(List.wrap(device.mac))}
        end)

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
      reraise e, __STACKTRACE__
  end

  # Bulk-load the source-authoritative identifiers held by every device an
  # update carrying one could match, so `strong_match/2` can refuse a record
  # holding a different one without a per-update query.
  @doc false
  def preload_source_ids(updates_with_ids, lookups, actor) do
    updates_with_ids
    |> Enum.flat_map(fn {_update, ids} ->
      if Ids.ids_get(ids, :armis_id) in [nil, ""] do
        []
      else
        for id_type <- Ids.identifier_priority(),
            value <- Ids.get_identifier_values(id_type, ids),
            device_id <- identifier_owners(id_type, value, ids, lookups.identifiers),
            do: device_id
      end
    end)
    |> SourceAuthorityGuard.held_source_ids(actor)
  rescue
    e ->
      Logger.warning("BatchResolver: source identifier preload failed: #{inspect(e)}")
      reraise e, __STACKTRACE__
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
