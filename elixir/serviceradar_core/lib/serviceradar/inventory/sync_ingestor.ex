defmodule ServiceRadar.Inventory.SyncIngestor do
  @moduledoc """
  Sync ingestion orchestrator.

  Coalesced sync batches (see SyncIngestorQueue) flow through:
  normalize -> resolve (bulk identity lookups + DIRE resolution) ->
  device upserts (with IP-conflict recovery) -> identifier/interface/risk
  writes -> alias processing. The heavy lifting lives in the
  ServiceRadar.Inventory.Sync.* submodules; identity decisions belong to
  ServiceRadar.Inventory.IdentityReconciler.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.DeviceRiskReducer
  alias ServiceRadar.Inventory.Identity.BatchResolver
  alias ServiceRadar.Inventory.Identity.Fence
  alias ServiceRadar.Inventory.SourceFacts.Reconciler, as: SourceFactReconciler
  alias ServiceRadar.Inventory.Sync.Aliases
  alias ServiceRadar.Inventory.Sync.DeviceRecords
  alias ServiceRadar.Inventory.Sync.DeviceWrites
  alias ServiceRadar.Inventory.Sync.IdentifierRecords
  alias ServiceRadar.Inventory.Sync.Interfaces
  alias ServiceRadar.Inventory.Sync.Lookups
  alias ServiceRadar.Inventory.Sync.Normalize
  alias ServiceRadar.Inventory.Sync.Risk
  alias ServiceRadar.Inventory.Sync.SourcePolicy
  alias ServiceRadar.Inventory.Sync.StateEvents

  require Logger

  @batch_size 500

  @spec ingest_updates([map()], keyword()) :: :ok | {:error, term()}
  def ingest_updates(updates, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = Keyword.get(opts, :actor, SystemActor.system(:sync_ingestor))

    updates = List.wrap(updates)
    total_count = length(updates)
    batch_concurrency = batch_concurrency()

    Logger.info("SyncIngestor: Processing #{total_count} updates in batches of #{@batch_size}")
    start_time = System.monotonic_time(:millisecond)

    batches =
      updates
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index(1)

    total_batches = ceil(total_count / @batch_size)

    result = process_batches(batches, actor, total_batches, batch_concurrency)

    elapsed = System.monotonic_time(:millisecond) - start_time
    rate = if elapsed > 0, do: Float.round(total_count / (elapsed / 1000), 1), else: 0

    Logger.info(
      "SyncIngestor: Completed #{total_count} updates in #{elapsed}ms (#{rate} devices/sec)"
    )

    DeviceWrites.maybe_refresh_inventory_rollups(result, total_count)
  end

  defp process_batches([{batch, batch_num}], actor, total_batches, _batch_concurrency) do
    process_batch(batch, batch_num, total_batches, actor)
  end

  defp process_batches(batches, actor, total_batches, batch_concurrency) do
    batches
    |> Task.async_stream(
      fn {batch, batch_num} ->
        process_batch(batch, batch_num, total_batches, actor)
      end,
      max_concurrency: batch_concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, _acc ->
        {:cont, :ok}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}

      {:exit, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp process_batch(batch, batch_num, total_batches, actor) do
    batch_start = System.monotonic_time(:millisecond)
    result = ingest_batch(batch, actor)
    batch_elapsed = System.monotonic_time(:millisecond) - batch_start

    Logger.debug(
      "SyncIngestor: Batch #{batch_num}/#{total_batches} (#{length(batch)} devices) completed in #{batch_elapsed}ms"
    )

    result
  end

  defp ingest_batch(updates, actor) do
    normalized_updates = normalize_updates(updates)

    {resolved_updates, strong_uids, device_records, identifier_records, interface_records} =
      resolve_updates(normalized_updates, actor)

    # Observe-only identity fence. Identity is resolved once above and then five
    # bulk writes follow, so a merge landing partway through leaves some of them
    # on the old device. One extra read per batch, not per device.
    pins = Fence.observe_pins(Enum.map(resolved_updates, fn {_update, uid} -> uid end))

    previous_device_states = StateEvents.previous_device_states(device_records)

    case upsert_devices(device_records, strong_uids, resolved_updates) do
      {:ok, remap} ->
        StateEvents.publish_device_state_transitions(
          device_records,
          previous_device_states,
          remap
        )

        StateEvents.invalidate_identity_cache_for_device_records(device_records)

        # An IP-conflict recovery may have rewritten device uids during the
        # device upsert. Apply the same mapping to identifier records and the
        # resolved-update tuples so downstream steps reference uids that
        # actually landed in `ocsf_devices` and don't trip the FK constraint.
        identifier_records = apply_uid_remap_to_identifier_records(identifier_records, remap)
        interface_records = apply_uid_remap_to_interface_records(interface_records, remap)
        resolved_updates = apply_uid_remap_to_resolved_updates(resolved_updates, remap)

        risk_result = upsert_source_risk_contributions(resolved_updates)
        identifier_result = upsert_identifiers(identifier_records)
        interface_result = upsert_interfaces(interface_records)
        StateEvents.invalidate_identity_cache_for_identifier_records(identifier_records)

        _ = maybe_process_alias_conflicts(:ok, resolved_updates, actor)
        alias_result = maybe_process_alias_updates(:ok, resolved_updates, actor)
        _ = SourceFactReconciler.ingest_resolved(resolved_updates)

        pins |> drop_remapped_pins(remap) |> Fence.observe_many(:sync_ingestor)

        finalize_ingest_results(
          :ok,
          risk_result,
          identifier_result,
          interface_result,
          alias_result
        )

      {:error, _} = error ->
        finalize_ingest_results(error, :ok, :ok, :ok, :ok)
    end
  end

  # An IP-conflict recovery rewrites a device uid deliberately, which is not the
  # drift this is measuring: the pinned uid genuinely stops naming the device, so
  # it would read as `observed_missing` and inflate the numbers the enforcement
  # decision is made from. Drop those rather than report them.
  defp drop_remapped_pins(pins, remap) when map_size(remap) == 0, do: pins

  defp drop_remapped_pins(pins, remap), do: Map.drop(pins, Map.keys(remap))

  defp apply_uid_remap_to_identifier_records(records, remap) when map_size(remap) == 0,
    do: records

  defp apply_uid_remap_to_identifier_records(records, remap) do
    records
    |> Enum.map(fn record ->
      case Map.get(remap, record.device_id) do
        nil -> record
        canonical_uid -> %{record | device_id: canonical_uid}
      end
    end)
    |> Enum.uniq_by(fn r -> {r.identifier_type, r.identifier_value, r.partition} end)
  end

  defp apply_uid_remap_to_interface_records(records, remap) when map_size(remap) == 0, do: records

  defp apply_uid_remap_to_interface_records(records, remap) do
    Enum.map(records, fn record ->
      case Map.get(remap, record.device_id) do
        nil -> record
        canonical_uid -> %{record | device_id: canonical_uid}
      end
    end)
  end

  defp apply_uid_remap_to_resolved_updates(resolved, remap) when map_size(remap) == 0,
    do: resolved

  defp apply_uid_remap_to_resolved_updates(resolved, remap) do
    Enum.map(resolved, fn {update, device_id} ->
      {update, Map.get(remap, device_id, device_id)}
    end)
  end

  defp normalize_updates(updates) do
    updates
    |> Enum.map(&Normalize.normalize_update/1)
    |> Enum.map(&Normalize.enrich_alias_metadata/1)
  end

  defp resolve_updates(normalized_updates, actor) do
    all_identifiers = Lookups.extract_all_identifiers(normalized_updates)
    existing_mappings = Lookups.bulk_lookup_identifiers(all_identifiers)
    # Resolved BEFORE the enrichment gate, not after. An enrichment-only source
    # whose only subject key is an IP -- a passive fingerprint -- has no strong
    # identifier at all, so an identifier-only gate discards 100% of its updates
    # and says so at debug level. The IP map is built from the unfiltered list,
    # which is a harmless superset for BatchResolver below.
    existing_ip_to_device = Lookups.bulk_lookup_by_ip(normalized_updates)

    normalized_updates =
      drop_unmatched_enrichment_updates(
        normalized_updates,
        existing_mappings,
        existing_ip_to_device
      )

    updates_with_ids =
      Enum.map(normalized_updates, fn update ->
        {update, SourcePolicy.effective_identifiers(update)}
      end)

    {resolved_updates, strong_uids} =
      BatchResolver.resolve_batch(
        updates_with_ids,
        %{identifiers: existing_mappings, ip: existing_ip_to_device},
        actor
      )

    timestamp = DateTime.truncate(DateTime.utc_now(), :second)
    device_records = DeviceRecords.build_device_upsert_records(resolved_updates, timestamp)
    identifier_records = IdentifierRecords.build_identifier_records(resolved_updates)
    interface_records = Interfaces.build_interface_upsert_records(resolved_updates, timestamp)

    {resolved_updates, strong_uids, device_records, identifier_records, interface_records}
  end

  # Updates that may not create a device are kept only when they already name
  # one. This runs AFTER the bulk identifier lookup and BEFORE anything that
  # writes, which is the only window where "does this device already exist" is
  # both answered and still actionable. Downstream, BatchResolver mints a uid
  # for any update that resolved to nothing -- that is its job for every other
  # source, and there is no flag on the resolved tuple that would let a later
  # step tell a minted device from a found one.
  #
  # See SourcePolicy.sufficient_to_create?/1: mDNS is enrichment-only, and an
  # addressless census ARP probe is the wrong kind of evidence to mint a row.
  defp drop_unmatched_enrichment_updates(updates, existing_mappings, existing_ip_to_device) do
    {kept, dropped} =
      Enum.split_with(updates, fn update ->
        SourcePolicy.sufficient_to_create?(update) or
          Lookups.matches_existing_device?(update, existing_mappings) or
          enrichment_ip_matches_existing_device?(update, existing_ip_to_device)
      end)

    if dropped != [] do
      # Said out loud rather than dropped quietly: a segment whose devices are
      # all unknown to inventory and a collector whose MACs never match look
      # identical from outside, and only one of them is working as intended.
      Logger.debug(
        "SyncIngestor: dropped #{length(dropped)} update(s) ineligible to create a device and matching no existing device"
      )
    end

    # Blank IP is an explicit clear in DeviceWrites (`btrim(EXCLUDED.ip) = ''
    # THEN NULL`). An ineligible observation kept as enrichment must not
    # vacate a stored address. Nil means omit.
    Enum.map(kept, &omit_blank_ip_unless_creating/1)
  end

  defp omit_blank_ip_unless_creating(update) do
    if SourcePolicy.sufficient_to_create?(update) do
      update
    else
      case update.ip do
        ip when is_binary(ip) ->
          if String.trim(ip) == "", do: %{update | ip: nil}, else: update

        _ ->
          update
      end
    end
  end

  # An address already claimed by a device is a legitimate anchor for enrichment,
  # and for an IP-only source it is the ONLY one. It still cannot create: an IP
  # that matches nothing leaves the update dropped, which is the whole point of
  # the gate.
  #
  # This does not weaken the mDNS rule it was written for. mDNS updates carry no
  # IP by design (the translator omits it deliberately), so for them this clause
  # is unreachable and MAC matching remains the only way through.
  defp enrichment_ip_matches_existing_device?(update, existing_ip_to_device) do
    case update.ip do
      ip when is_binary(ip) and ip != "" -> Map.has_key?(existing_ip_to_device, ip)
      _ -> false
    end
  end

  defp upsert_devices([], _strong_uids, _resolved_updates), do: {:ok, %{}}

  defp upsert_devices(records, strong_uids, resolved_updates),
    do: DeviceWrites.bulk_upsert_devices(records, strong_uids, resolved_updates)

  defp upsert_identifiers([]), do: :ok
  defp upsert_identifiers(records), do: IdentifierRecords.bulk_upsert_identifiers(records)

  defp upsert_interfaces([]), do: :ok
  defp upsert_interfaces(records), do: Interfaces.bulk_upsert_interfaces(records)

  defp upsert_source_risk_contributions(resolved_updates) do
    resolved_updates
    |> Risk.build_source_risk_contribution_records()
    |> DeviceRiskReducer.upsert_contributions()
  rescue
    e ->
      Logger.warning("SyncIngestor: Failed to update device risk contributions: #{inspect(e)}")
      {:error, e}
  end

  defp maybe_process_alias_conflicts(:ok, resolved_updates, actor) do
    Aliases.process_alias_conflicts(resolved_updates, actor)
  end

  defp maybe_process_alias_conflicts(_result, _resolved_updates, _actor), do: :ok

  defp maybe_process_alias_updates(:ok, resolved_updates, actor) do
    Aliases.process_alias_updates(resolved_updates, actor)
  end

  defp maybe_process_alias_updates(_result, _resolved_updates, _actor), do: :ok

  defp finalize_ingest_results(
         device_result,
         risk_result,
         identifier_result,
         interface_result,
         alias_result
       ) do
    case {device_result, risk_result, identifier_result, interface_result, alias_result} do
      {:ok, :ok, :ok, :ok, :ok} -> :ok
      {{:error, _} = error, _, _, _, _} -> error
      {_, {:error, _} = error, _, _, _} -> error
      {_, _, {:error, _} = error, _, _} -> error
      {_, _, _, {:error, _} = error, _} -> error
      {_, _, _, _, {:error, _} = error} -> error
    end
  end

  defp batch_concurrency do
    configured =
      Application.get_env(
        :serviceradar_core,
        :sync_ingestor_batch_concurrency,
        System.schedulers_online()
      )

    if is_integer(configured) and configured > 0 do
      configured
    else
      System.schedulers_online()
    end
  end
end
