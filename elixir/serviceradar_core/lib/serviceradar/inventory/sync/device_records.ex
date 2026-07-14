defmodule ServiceRadar.Inventory.Sync.DeviceRecords do
  @moduledoc "Builds ocsf_devices upsert records from resolved updates."

  alias ServiceRadar.Inventory.DeviceEnrichmentRules
  alias ServiceRadar.Inventory.Sync.Enrichment

  require Logger

  def build_device_upsert_records(resolved_updates, timestamp) do
    resolved_updates
    |> Enum.reduce(%{}, fn {update, device_id}, acc ->
      source = if update.source in [nil, ""], do: "unknown", else: update.source
      classification = DeviceEnrichmentRules.classify(update)
      vendor_name = Enrichment.infer_vendor_name(update, classification)
      model = Enrichment.infer_model(update, classification)
      {device_type, device_type_id} = Enrichment.infer_device_type(update, classification)
      metadata = Enrichment.merge_classification_metadata(update.metadata || %{}, classification)
      owner = Enrichment.infer_owner(update, metadata)
      persisted_metadata = persisted_metadata(metadata, source)

      record = %{
        uid: device_id,
        ip: update.ip,
        mac: update.mac,
        hostname: update.hostname,
        name: update.hostname || update.ip,
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
        is_managed: true,
        is_active: true,
        owner: owner,
        metadata: persisted_metadata,
        tags: update.tags || %{},
        discovery_sources: [source],
        first_seen_time: update.first_seen_time || timestamp,
        last_seen_time: update.last_seen_time || update.timestamp || timestamp,
        created_time: timestamp,
        modified_time: timestamp
      }

      Map.put(acc, device_id, record)
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

    %{
      existing
      | ip: prefer_non_empty(incoming.ip, existing.ip),
        mac: prefer_non_empty(incoming.mac, existing.mac),
        hostname: prefer_non_empty(incoming.hostname, existing.hostname),
        name: prefer_non_empty(incoming.name, existing.name),
        type: prefer_non_empty(incoming.type, existing.type),
        type_id: prefer_positive_int(incoming.type_id, existing.type_id),
        vendor_name: prefer_non_empty(incoming.vendor_name, existing.vendor_name),
        model: prefer_non_empty(incoming.model, existing.model),
        os: merged_os,
        hw_info: merged_hw_info,
        is_available: prefer_non_nil(incoming.is_available, existing.is_available),
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
  end

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

  defp prefer_positive_int(new_value, _old_value) when is_integer(new_value) and new_value > 0,
    do: new_value

  defp prefer_positive_int(_new_value, old_value), do: old_value

  # Complete plugin inventories keep source identity in typed identifiers and
  # source observations. They must not replace another source's canonical identity.
  defp persisted_metadata(%{"plugin_inventory_snapshot" => true} = metadata, _source) do
    Map.drop(metadata, ["integration_id", "integration_type", "plugin_inventory_snapshot"])
  end

  defp persisted_metadata(metadata, _source), do: metadata
end
