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
  alias ServiceRadar.Inventory.Sync.BatchExecutor
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

  @spec ingest_updates([map()], keyword()) :: :ok | {:ok, [map()]} | {:error, term()}
  def ingest_updates(updates, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = Keyword.get(opts, :actor, SystemActor.system(:sync_ingestor))

    updates = List.wrap(updates)
    total_count = length(updates)
    batch_concurrency = Keyword.get_lazy(opts, :batch_concurrency, &batch_concurrency/0)
    defer_state_events? = Keyword.get(opts, :defer_state_events?, false)

    Logger.info("SyncIngestor: Processing #{total_count} updates in batches of #{@batch_size}")
    start_time = System.monotonic_time(:millisecond)

    batches =
      updates
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index(1)

    total_batches = ceil(total_count / @batch_size)

    result =
      if defer_state_events? do
        BatchExecutor.collect(batches, fn {batch, batch_num} ->
          process_batch(batch, batch_num, total_batches, actor, true)
        end)
      else
        process_batches(batches, actor, total_batches, batch_concurrency)
      end

    elapsed = System.monotonic_time(:millisecond) - start_time
    rate = if elapsed > 0, do: Float.round(total_count / (elapsed / 1000), 1), else: 0

    Logger.info(
      "SyncIngestor: Completed #{total_count} updates in #{elapsed}ms (#{rate} devices/sec)"
    )

    case result do
      {:ok, effects} ->
        with :ok <- DeviceWrites.maybe_refresh_inventory_rollups(:ok, total_count) do
          {:ok, effects}
        end

      other ->
        DeviceWrites.maybe_refresh_inventory_rollups(other, total_count)
    end
  end

  @doc false
  def emit_committed_state_events(effects) do
    Enum.each(effects, fn effect ->
      StateEvents.publish_device_state_transitions(
        effect.device_records,
        effect.previous_device_states,
        effect.remap
      )

      StateEvents.invalidate_identity_cache_for_device_records(effect.device_records)
      StateEvents.invalidate_identity_cache_for_identifier_records(effect.identifier_records)
    end)

    :ok
  end

  defp process_batches(batches, actor, total_batches, batch_concurrency) do
    BatchExecutor.run(
      batches,
      fn {batch, batch_num} ->
        process_batch(batch, batch_num, total_batches, actor, false)
      end,
      batch_concurrency
    )
  end

  defp process_batch(batch, batch_num, total_batches, actor, defer_state_events?) do
    batch_start = System.monotonic_time(:millisecond)
    result = ingest_batch(batch, actor, defer_state_events?)
    batch_elapsed = System.monotonic_time(:millisecond) - batch_start

    Logger.debug(
      "SyncIngestor: Batch #{batch_num}/#{total_batches} (#{length(batch)} devices) completed in #{batch_elapsed}ms"
    )

    result
  end

  defp ingest_batch(updates, actor, defer_state_events?) do
    updates
    |> normalize_updates()
    |> ingest_normalized(actor, defer_state_events?, 1)
  end

  # One pass of resolve -> fenced write -> dependent writes. Identity is resolved
  # once and written later, so the write is fenced (Identity.Fence): the device
  # rows are pinned right after resolution and the device upsert plus identifier
  # registration run in one transaction that locks those rows and withholds every
  # write whose pin went stale (a merge, unmerge, delete, restore, reassignment or
  # purge landed in between). The withheld updates are resolved again and written
  # once more; a second stale pin abandons them with telemetry.
  defp ingest_normalized([], _actor, _defer_state_events?, _attempt), do: :ok

  defp ingest_normalized(normalized_updates, actor, defer_state_events?, attempt) do
    {resolved_updates, strong_uids, device_records, identifier_records, interface_records} =
      resolve_updates(normalized_updates, actor)

    pins = Fence.pin_batch(Enum.map(resolved_updates, fn {_update, uid} -> uid end))
    run_test_hook(:sync_ingestor_after_pin)

    case fenced_device_write(
           pins,
           device_records,
           identifier_records,
           strong_uids,
           resolved_updates
         ) do
      {:ok,
       {{remap, identifier_records, identifier_result, previous_device_states, remap_stale},
        pin_stale}} ->
        Enum.each(remap_stale, &Fence.report_stale_target(:sync_ingestor, &1, Map.get(pins, &1)))
        stale = MapSet.union(pin_stale, remap_stale)
        keep = &(not MapSet.member?(stale, &1))
        device_records = Enum.filter(device_records, &keep.(&1.uid))
        interface_records = Enum.filter(interface_records, &keep.(&1.device_id))
        {fresh_updates, stale_updates} = Enum.split_with(resolved_updates, &keep.(elem(&1, 1)))

        result =
          after_device_write(
            %{
              device_records: device_records,
              identifier_records: identifier_records,
              interface_records: interface_records,
              resolved_updates: fresh_updates,
              previous_device_states: previous_device_states,
              remap: remap,
              identifier_result: identifier_result
            },
            actor,
            defer_state_events?
          )

        retry_stale(result, stale_updates, pins, actor, defer_state_events?, attempt)

      {:error, _} = error ->
        finalize_ingest_results(error, :ok, :ok, :ok, :ok)
    end
  end

  # Transient conflicts abort the whole fenced transaction (Postgres cannot
  # continue one after an error), including the ones DeviceWrites recovers from
  # on its own outside a transaction: a concurrent active-IP insert and a
  # deadlock with a concurrent handoff or merge. Retry the fenced write; each
  # attempt re-pins nothing but re-locks and re-checks, and DeviceWrites' precheck
  # then sees the concurrent writer's committed row.
  @fenced_write_attempts 3

  defp fenced_device_write(
         pins,
         device_records,
         identifier_records,
         strong_uids,
         resolved_updates,
         attempt \\ 1
       ) do
    pins
    |> Fence.fenced_write(:sync_ingestor, fn stale ->
      keep = &(not MapSet.member?(stale, &1))
      device_records = Enum.filter(device_records, &keep.(&1.uid))
      identifier_records = Enum.filter(identifier_records, &keep.(&1.device_id))
      resolved_updates = Enum.filter(resolved_updates, &keep.(elem(&1, 1)))

      run_test_hook(:sync_ingestor_in_fenced_write)

      # Read under the locks, so the state a transition event reports is the one
      # this write replaces.
      previous_device_states = StateEvents.previous_device_states(device_records)

      case upsert_devices(device_records, strong_uids, resolved_updates) do
        {:ok, remap, remap_stale} ->
          # A record whose redirect target was no longer live was withheld; so are
          # its identifiers. An IP-conflict recovery may have rewritten device uids
          # during the device upsert. Apply the same mapping to identifier records
          # so they reference uids that actually landed in `ocsf_devices` and don't
          # trip the FK constraint.
          remap_stale = MapSet.new(remap_stale)

          identifier_records =
            identifier_records
            |> Enum.reject(&MapSet.member?(remap_stale, &1.device_id))
            |> apply_uid_remap_to_identifier_records(remap)

          case upsert_identifiers(identifier_records) do
            :ok -> {:ok, {remap, identifier_records, :ok, previous_device_states, remap_stale}}
            {:error, _} = error -> error
          end

        {:error, _} = error ->
          error
      end
    end)
    |> case do
      {:error, reason} = error ->
        if attempt < @fenced_write_attempts and transient_write_conflict?(reason) do
          Logger.info(
            "SyncIngestor: fenced write hit a transient conflict; retrying " <>
              "(attempt #{attempt + 1} of #{@fenced_write_attempts}): #{inspect(reason)}"
          )

          fenced_device_write(
            pins,
            device_records,
            identifier_records,
            strong_uids,
            resolved_updates,
            attempt + 1
          )
        else
          error
        end

      ok ->
        ok
    end
  end

  @transient_pg_codes ["40P01", "23505", "25P02", "40001"]

  defp transient_write_conflict?(%Postgrex.Error{postgres: %{} = postgres}) do
    postgres[:code] in [
      :deadlock_detected,
      :unique_violation,
      :in_failed_sql_transaction,
      :serialization_failure
    ] or postgres[:pg_code] in @transient_pg_codes
  end

  defp transient_write_conflict?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &transient_write_conflict?/1)

  # Ash reports a raised Postgrex error from inside an action as an UnknownError
  # carrying only the rendered message.
  defp transient_write_conflict?(%{error: message}) when is_binary(message),
    do: Enum.any?(@transient_pg_codes, &String.contains?(message, "ERROR #{&1} "))

  defp transient_write_conflict?(%{error: error}), do: transient_write_conflict?(error)
  defp transient_write_conflict?(_reason), do: false

  # Everything after the device and identifier rows: state events, risk,
  # interfaces, aliases and source facts, for the updates whose write landed.
  defp after_device_write(written, actor, defer_state_events?) do
    %{
      device_records: device_records,
      identifier_records: identifier_records,
      interface_records: interface_records,
      resolved_updates: resolved_updates,
      previous_device_states: previous_device_states,
      remap: remap,
      identifier_result: identifier_result
    } = written

    if !defer_state_events? do
      StateEvents.publish_device_state_transitions(device_records, previous_device_states, remap)
      StateEvents.invalidate_identity_cache_for_device_records(device_records)
    end

    interface_records = apply_uid_remap_to_interface_records(interface_records, remap)
    resolved_updates = apply_uid_remap_to_resolved_updates(resolved_updates, remap)

    risk_result = upsert_source_risk_contributions(resolved_updates)
    interface_result = upsert_interfaces(interface_records)

    if !defer_state_events?,
      do: StateEvents.invalidate_identity_cache_for_identifier_records(identifier_records)

    _ = maybe_process_alias_conflicts(:ok, resolved_updates, actor)
    alias_result = maybe_process_alias_updates(:ok, resolved_updates, actor)
    _ = SourceFactReconciler.ingest_resolved(resolved_updates)

    :ok
    |> finalize_ingest_results(risk_result, identifier_result, interface_result, alias_result)
    |> deferred_batch_result(defer_state_events?, %{
      device_records: device_records,
      previous_device_states: previous_device_states,
      remap: remap,
      identifier_records: identifier_records
    })
  end

  # Updates whose pin went stale are resolved again from scratch and written once
  # more; if their pin goes stale a second time, two identity transitions landed
  # inside one write, and they are abandoned with telemetry (Fence.abandon/2).
  defp retry_stale(result, [], _pins, _actor, _defer_state_events?, _attempt), do: result

  defp retry_stale(result, stale_updates, _pins, actor, defer_state_events?, 1) do
    retried =
      stale_updates
      |> Enum.map(&elem(&1, 0))
      |> ingest_normalized(actor, defer_state_events?, 2)

    combine_results(result, retried)
  end

  defp retry_stale(result, stale_updates, pins, _actor, _defer_state_events?, _attempt) do
    stale_updates
    |> Map.new(fn {_update, uid} -> {uid, Map.fetch!(pins, uid)} end)
    |> Fence.abandon(:sync_ingestor)

    result
  end

  defp combine_results({:error, _} = error, _second), do: error
  defp combine_results(_first, {:error, _} = error), do: error
  defp combine_results(:ok, :ok), do: :ok
  defp combine_results({:ok, effect}, :ok), do: {:ok, effect}
  defp combine_results(:ok, {:ok, effect}), do: {:ok, effect}

  defp combine_results({:ok, first}, {:ok, second}) do
    {:ok,
     %{
       device_records: first.device_records ++ second.device_records,
       previous_device_states:
         Map.merge(first.previous_device_states, second.previous_device_states),
       remap: Map.merge(first.remap, second.remap),
       identifier_records: first.identifier_records ++ second.identifier_records
     }}
  end

  defp deferred_batch_result(:ok, true, effect), do: {:ok, effect}
  defp deferred_batch_result(result, _defer_state_events?, _effect), do: result

  # Test-only barrier between pinning and the fenced write
  # (Application env :identity_fence_test_hooks). Production leaves it unset.
  defp run_test_hook(event) do
    case Application.get_env(:serviceradar_core, :identity_fence_test_hooks) do
      %{^event => fun} when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

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

  defp upsert_devices([], _strong_uids, _resolved_updates), do: {:ok, %{}, []}

  # Inside the fenced transaction: DeviceWrites locks every device it redirects a
  # record to and reports a record whose target is no longer live as stale.
  defp upsert_devices(records, strong_uids, resolved_updates),
    do:
      DeviceWrites.bulk_upsert_devices(records, strong_uids, resolved_updates,
        lock_remap_targets: true
      )

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
