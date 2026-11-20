defmodule ServiceRadar.Inventory.Sync.DeviceRecords do
  @moduledoc "Builds ocsf_devices upsert records from resolved updates."

  alias ServiceRadar.Inventory.DeviceEnrichmentRules
  alias ServiceRadar.Inventory.Identity.Address
  alias ServiceRadar.Inventory.Sync.AttributeStrength
  alias ServiceRadar.Inventory.Sync.Enrichment
  alias ServiceRadar.Inventory.Sync.MacVendor
  alias ServiceRadar.Inventory.Sync.SourcePolicy

  require Logger

  @address_fallback_strength AttributeStrength.strength("name", :address_fallback)

  def build_device_upsert_records(resolved_updates, timestamp) do
    # One query for the whole batch rather than one per device: SyncIngestor
    # works in chunks of 500, so a per-device lookup would be 500 round trips
    # per chunk. Mirrors Lookups.bulk_lookup_by_ip/1.
    {oui_lookup, oui_snapshot_id} =
      resolved_updates
      |> Enum.map(fn {update, _device_id} -> update.mac end)
      |> MacVendor.bulk_lookup()

    primaries = batch_primaries(resolved_updates)

    resolved_updates
    |> Enum.reduce(%{}, fn {update, device_id}, acc ->
      source = if update.source in [nil, ""], do: "unknown", else: update.source
      classification = DeviceEnrichmentRules.classify(update)

      # Vendor evidence is ranked (AttributeStrength): a hardware vendor beats the
      # IEEE OUI registrant, which beats a name of SNMP agent software. The record
      # carries the strongest one, and the upsert decides it against the stored
      # vendor's recorded strength. The OUI is looked up only when no hardware
      # vendor is present.
      %{vendor: inferred_vendor, vendor_class: inferred_class, model: inferred_model} =
        Enrichment.infer_vendor_and_model(update, classification)

      oui_resolved =
        if inferred_class != :hardware, do: MacVendor.resolve(update.mac, oui_lookup)

      {vendor_name, vendor_class, oui_resolved} =
        case {inferred_class, oui_resolved} do
          {:hardware, _} -> {inferred_vendor, :hardware, nil}
          {_, {org, _prefix}} -> {org, :oui, oui_resolved}
          {class, nil} -> {inferred_vendor, class, nil}
        end

      model = if vendor_class, do: inferred_model

      {device_type, device_type_id, type_evidence} =
        Enrichment.infer_device_type(update, classification)

      metadata =
        (update.metadata || %{})
        |> Enrichment.merge_classification_metadata(classification)
        |> MacVendor.put_provenance(oui_resolved, oui_snapshot_id)

      owner = Enrichment.infer_owner(update, metadata)
      persisted_metadata = persisted_metadata(metadata, source)
      primary = Map.fetch!(primaries, device_id)

      # The address fallback names the device after the primary it keeps
      # (IPv4 preferred), never the record's raw address.
      {name, hostname, name_tag} = AttributeStrength.name_write(Map.put(update, :ip, primary.ip))

      provenance =
        %{
          "name" => name_tag,
          "vendor" => AttributeStrength.vendor_tag(vendor_class, update),
          "type" => AttributeStrength.type_tag(device_type, type_evidence, update),
          "integration_type" => AttributeStrength.integration_type_tag(persisted_metadata, update)
        }
        |> Enum.reject(fn {_group, tag} -> is_nil(tag) end)
        |> Map.new()

      record = %{
        uid: device_id,
        # Scoped to the same partition its identifiers are scoped to
        # (`Ids.identifier_partition/2`). Without this the row falls to the
        # column default and every source writes the "default" copy, so an
        # isolation sweep would overwrite the monitoring view of the same IP
        # rather than keeping its own.
        partition: update_partition(update),
        ip: primary.ip,
        ip_source: primary.source,
        ip_seen_at: primary.seen_at,
        ip_sightings: primary.sightings,
        mac: update.mac,
        hostname: hostname,
        name: name,
        type: device_type,
        type_id: device_type_id,
        vendor_name: vendor_name,
        model: model,
        os:
          Enrichment.merge_inferred_map(
            update.os,
            Enrichment.infer_os(metadata, vendor_name, classification)
          ),
        hw_info:
          Enrichment.merge_inferred_map(update.hw_info, Enrichment.infer_hw_info(metadata)),
        network_interfaces: update.network_interfaces || [],
        is_available: update.is_available,
        is_managed: prefer_non_nil(Map.get(update, :is_managed), true),
        is_active: true,
        owner: owner,
        metadata: persisted_metadata,
        attribute_provenance: provenance,
        tags: update.tags || %{},
        discovery_sources: [source],
        first_seen_time: update.first_seen_time || timestamp,
        last_seen_time: update.last_seen_time || update.timestamp || timestamp,
        created_time: timestamp,
        modified_time: timestamp
      }

      # A later update for the same device in this batch replaces the earlier
      # one, except for the ranked attributes, which resolve as they would in
      # two batches.
      Map.update(acc, device_id, record, &AttributeStrength.fold_ranked(&1, record, record))
    end)
    |> Map.values()
  end

  def merge_records_by_uid(records) do
    records
    |> Enum.reduce(%{}, fn record, acc ->
      uid = Map.fetch!(record, :uid)
      Map.update(acc, uid, record, &merge_device_records(&1, record))
    end)
    |> Map.values()
  end

  defp merge_device_records(existing, incoming) do
    merged_metadata =
      existing.metadata
      |> Enrichment.strip_classification_metadata()
      # Same reason the classification keys are stripped: two updates for one
      # uid in a batch must not leave the first update's derived attribution
      # sitting under the second update's vendor.
      |> MacVendor.strip_provenance()
      |> Map.merge(incoming.metadata || %{})

    merged_tags = Map.merge(existing.tags || %{}, incoming.tags || %{})
    merged_os = Map.merge(existing.os || %{}, incoming.os || %{})
    merged_hw_info = Map.merge(existing.hw_info || %{}, incoming.hw_info || %{})

    merged_network_interfaces =
      if incoming.network_interfaces in [nil, []],
        do: existing.network_interfaces || [],
        else: incoming.network_interfaces

    merged_discovery_sources =
      merge_discovery_sources(existing.discovery_sources, incoming.discovery_sources)

    # name / hostname, vendor_name / model, type / type_id / device_role and
    # integration_type are ranked: AttributeStrength.fold_ranked/3 below
    # resolves them the way the upsert would across two batches.
    merged = %{
      existing
      | mac: prefer_non_empty(incoming.mac, existing.mac),
        os: merged_os,
        hw_info: merged_hw_info,
        is_available: prefer_non_nil(incoming.is_available, existing.is_available),
        is_managed: prefer_non_nil(incoming.is_managed, existing.is_managed),
        network_interfaces: merged_network_interfaces,
        owner: prefer_non_nil(incoming.owner, existing.owner),
        metadata: merged_metadata,
        tags: merged_tags,
        discovery_sources: merged_discovery_sources,
        first_seen_time: prefer_non_nil(existing.first_seen_time, incoming.first_seen_time),
        last_seen_time: prefer_non_nil(incoming.last_seen_time, existing.last_seen_time),
        created_time: prefer_non_nil(existing.created_time, incoming.created_time),
        modified_time: prefer_non_nil(incoming.modified_time, existing.modified_time)
    }

    merged = merge_primary(merged, existing, incoming)

    merged =
      AttributeStrength.fold_ranked(
        fallback_to_primary(existing, merged.ip),
        fallback_to_primary(incoming, merged.ip),
        merged
      )

    # The later identity-bearing observation of the two
    # (DeviceWrites.observed_after?/2).
    case later(Map.get(existing, :identity_observed_at), Map.get(incoming, :identity_observed_at)) do
      nil -> merged
      at -> Map.put(merged, :identity_observed_at, at)
    end
  end

  # The batch's primary for a device: the strongest address the device's updates
  # submitted (`Address.best/1`), with the source that submitted it, and every
  # address each source reported for the device (`ip_sightings`), from which
  # `DeviceWrites` decides whether the stored primary is still sighted by the source
  # that recorded it. A device's updates are judged together, so the order of a
  # census snapshot's ARP and NDP sightings cannot decide its primary.
  defp batch_primaries(resolved_updates) do
    resolved_updates
    |> Enum.group_by(fn {_update, device_id} -> device_id end, fn {update, _} -> update end)
    |> Map.new(fn {device_id, updates} -> {device_id, primary_of(updates)} end)
  end

  defp primary_of(updates) do
    submitted = for update <- updates, present?(update.ip), do: update

    sightings =
      Enum.reduce(updates, %{}, fn update, acc ->
        Map.update(
          acc,
          update_source(update),
          sighting_entry(update),
          &merge_sighting_entry(&1, sighting_entry(update))
        )
      end)

    case Address.best(Enum.map(submitted, & &1.ip)) do
      nil ->
        # Nothing usable: the last submitted value applies as before (an explicit
        # blank clear, or an address the upsert's guard judges).
        case List.last(updates) do
          %{ip: ip} = update when is_binary(ip) ->
            %{
              ip: ip,
              source: update_source(update),
              seen_at: update_seen_at(update),
              sightings: sightings
            }

          _ ->
            %{ip: nil, source: nil, seen_at: nil, sightings: sightings}
        end

      ip ->
        update = Enum.find(submitted, &(&1.ip == ip))

        %{
          ip: ip,
          source: update_source(update),
          seen_at: update_seen_at(update),
          sightings: sightings
        }
    end
  end

  # Every address an update reports for its device: the submitted primary and every
  # address its alias metadata names, including addresses its chooser did not submit.
  # `complete?` is false for a single-sighting source (mapper, sweep), whose one
  # address says nothing about the device's other addresses.
  defp sighting_entry(update) do
    metadata = update.metadata || %{}

    alias_addresses =
      for {key, _value} <- metadata,
          is_binary(key),
          prefix <- ["ip_alias:", "interface_ip_alias:", "alt_ip:"],
          String.starts_with?(key, prefix),
          address = key |> String.replace_prefix(prefix, "") |> String.trim(),
          address != "",
          do: address

    last_seen = metadata["_alias_last_seen_ip"]

    addresses =
      [update.ip, last_seen | alias_addresses]
      |> Enum.filter(&present?/1)
      |> MapSet.new(&String.trim/1)

    %{addresses: addresses, complete?: not SourcePolicy.mapper_like_source?(update)}
  end

  defp merge_sighting_entry(a, b),
    do: %{
      addresses: MapSet.union(a.addresses, b.addresses),
      complete?: a.complete? or b.complete?
    }

  defp merge_sightings(a, b),
    do: Map.merge(a || %{}, b || %{}, fn _k, x, y -> merge_sighting_entry(x, y) end)

  # Two records for one uid (an active-IP remap folding a record onto its holder):
  # the stronger primary of the two, with its source; equal strength keeps the
  # earlier record's.
  defp merge_primary(merged, existing, incoming) do
    sightings =
      merge_sightings(Map.get(existing, :ip_sightings), Map.get(incoming, :ip_sightings))

    {ip, source, seen_at} =
      cond do
        not present?(incoming.ip) ->
          {existing.ip, Map.get(existing, :ip_source), Map.get(existing, :ip_seen_at)}

        not present?(existing.ip) or Address.better?(incoming.ip, existing.ip) ->
          {incoming.ip, Map.get(incoming, :ip_source), Map.get(incoming, :ip_seen_at)}

        true ->
          {existing.ip, Map.get(existing, :ip_source), Map.get(existing, :ip_seen_at)}
      end

    merged
    |> Map.put(:ip, ip)
    |> Map.put(:ip_source, source)
    |> Map.put(:ip_seen_at, seen_at)
    |> Map.put(:ip_sightings, sightings)
  end

  # Each record was built alone, so its address-fallback name is its own address. The
  # fallback names the device after the primary the merge keeps, as in one build.
  defp fallback_to_primary(record, primary_ip) do
    provenance = Map.get(record, :attribute_provenance) || %{}

    case Map.get(provenance, "name") do
      %{"strength" => strength, "source" => source} = tag
      when strength == @address_fallback_strength ->
        {name, _hostname, new_tag} =
          AttributeStrength.name_write(%{hostname: nil, ip: primary_ip, source: source})

        provenance =
          if new_tag, do: Map.put(provenance, "name", tag), else: Map.delete(provenance, "name")

        %{record | name: name, attribute_provenance: provenance}

      _ ->
        record
    end
  end

  defp update_source(update),
    do: if(update.source in [nil, ""], do: "unknown", else: update.source)

  defp update_seen_at(update) do
    case update.last_seen_time || update.timestamp do
      %DateTime{} = at -> at
      _ -> DateTime.utc_now()
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp merge_discovery_sources(existing_sources, incoming_sources) do
    (existing_sources || [])
    |> Kernel.++(incoming_sources || [])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp prefer_non_empty(new_value, old_value) when new_value in [nil, ""], do: old_value
  defp prefer_non_empty(new_value, _old_value), do: new_value
  defp prefer_non_nil(nil, old_value), do: old_value
  defp prefer_non_nil(new_value, _old_value), do: new_value

  defp later(nil, other), do: other
  defp later(at, nil), do: at
  defp later(at, other), do: if(DateTime.after?(other, at), do: other, else: at)

  # Complete plugin inventories keep source identity in typed identifiers and
  # source observations. They must not replace another source's canonical identity.

  # Mirrors `Ids.identifier_partition/2` so a device row and its identifiers are
  # scoped to the same partition. Duplicated deliberately rather than reaching
  # into Ids: this path builds the row from `update` and never constructs an
  # `Ids` struct, and a wrong default here silently collapses every partition
  # onto "default".
  defp update_partition(update) do
    case Map.get(update, :partition) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> "default"
          trimmed -> trimmed
        end

      _ ->
        "default"
    end
  end

  defp persisted_metadata(%{"plugin_inventory_snapshot" => true} = metadata, _source) do
    Map.drop(metadata, ["integration_id", "integration_type", "plugin_inventory_snapshot"])
  end

  defp persisted_metadata(metadata, _source), do: metadata
end
