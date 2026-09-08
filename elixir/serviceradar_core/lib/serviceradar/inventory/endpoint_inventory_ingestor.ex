defmodule ServiceRadar.Inventory.EndpointInventoryIngestor do
  @moduledoc """
  Ingests endpoint package/SBOM inventory reports from agent result payloads.
  """

  import Bitwise
  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.EndpointInventoryArtifactPersistence
  alias ServiceRadar.Inventory.EndpointInventoryFleetOrdinal
  alias ServiceRadar.Inventory.EndpointInventoryHistory
  alias ServiceRadar.Inventory.EndpointInventoryPackageSet
  alias ServiceRadar.Inventory.EndpointInventoryPayload, as: Payload
  alias ServiceRadar.Inventory.EndpointInventoryTelemetry
  alias ServiceRadar.Inventory.EndpointInventoryVulnerabilityRisk
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @collector_name "serviceradar-endpoint-inventory"
  @hash_algorithm "sha256-v1"
  @upload_reason_changed "changed"
  @upload_reason_unchanged "unchanged"
  @metadata_reason_full_scan_hash_unchanged "full_scan_hash_unchanged"
  @metadata_reason_upload_already_acknowledged "upload_already_acknowledged"
  @state_not_scanned "not_scanned"
  @coverage_state_unchanged "unchanged"
  @default_reconcile_floor_scan_count 24
  @default_reconcile_floor_max_age_days 7

  @spec ingest_report(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_report(payload, opts \\ [])

  def ingest_report(payload, opts) when is_map(payload) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:endpoint_inventory_ingestor))

    with_result =
      with {:ok, agent_id} <- Payload.required_string(payload, :agent_id),
           {:ok, scan_id} <- Payload.required_string(payload, :scan_id),
           :continue <- maybe_short_circuit_noop(payload, agent_id, scan_id),
           {:ok, context} <- build_context(payload, agent_id, scan_id, actor, opts),
           :continue <- maybe_short_circuit_hash_noop(context),
           {:ok, context} <- allocate_device_fleet_ordinal(context, opts),
           {:ok, artifact} <-
             EndpointInventoryArtifactPersistence.maybe_upload(payload, context, opts) do
        context = EndpointInventoryArtifactPersistence.apply_metadata(context, artifact)

        case Repo.transaction(fn ->
               current = current_scan_snapshot(context.agent_id)
               current_row_count = current_package_row_count(context.agent_id)
               previous_packages = current_package_rows(context)
               context = maybe_apply_package_delta(context, current, previous_packages)
               context = apply_hash_freshness(context, current, current_row_count)
               scan_ref = upsert_scan(context, artifact)
               insert_scan_activity_event(scan_ref, context)
               EndpointInventoryArtifactPersistence.replace(scan_ref, context, artifact)
               package_count = maybe_replace_packages(scan_ref, context)

               history =
                 EndpointInventoryHistory.record_changed(
                   scan_ref,
                   current,
                   previous_packages,
                   Map.put(context, :successful_scan?, successful_scan?(context))
                 )

               maybe_promote_current(scan_ref, context)

               %{
                 agent_id: context.agent_id,
                 device_uid: context.device_uid,
                 scan_id: context.scan_id,
                 scan_ref: scan_ref,
                 package_count: package_count,
                 artifact_uploaded?: not is_nil(artifact),
                 package_rows_replaced?: not context.package_replacement_noop?,
                 scan_history_recorded?: history.scan_history_recorded?,
                 package_event_count: history.package_event_count,
                 package_set_hash_mismatch?: context.package_set_hash_mismatch?,
                 reconcile_floor?: context.reconcile_floor_due?,
                 upload_reason: context.upload_reason,
                 directives: scan_ack_directives(context),
                 current?: successful_scan?(context),
                 package_change_signals: history.package_change_signals
               }
             end) do
          {:ok, result} ->
            published_count =
              result
              |> Map.get(:package_change_signals, [])
              |> EndpointInventoryHistory.publish_package_change_signals(opts)

            {:ok,
             result
             |> Map.delete(:package_change_signals)
             |> Map.put(:package_change_signal_publish_count, published_count)
             |> tap(&EndpointInventoryTelemetry.emit_ingest_result/1)}

          error ->
            error
        end
      end

    normalize_short_circuit_result(with_result)
  end

  def ingest_report(_payload, _opts), do: {:error, :invalid_endpoint_inventory_payload}

  defp maybe_short_circuit_hash_noop(context) do
    if hash_noop_candidate?(context) do
      current = current_scan_snapshot(context.agent_id)

      cond do
        is_nil(current) ->
          :continue

        not package_hash_matches_current?(context, current) ->
          {:ok, emit_hash_noop_result(force_reconcile(context), current)}

        not artifact_hash_matches_current?(context, current) ->
          {:ok, emit_hash_noop_result(force_reconcile(context), current)}

        true ->
          current_row_count = current_package_row_count(context.agent_id)
          freshness_context = apply_hash_freshness(context, current, current_row_count)

          cond do
            full_scan_hash_unchanged?(freshness_context, current) ->
              touch_hash_noop_freshness(freshness_context, current)

            freshness_context.reconcile_floor_due? ->
              touch_hash_noop_freshness(freshness_context, current)

            hash_freshness_short_circuit?(freshness_context, current) ->
              {:ok, emit_hash_noop_result(freshness_context, current)}

            true ->
              {:ok, emit_hash_noop_result(force_reconcile(freshness_context), current)}
          end
      end
    else
      :continue
    end
  end

  defp package_hash_matches_current?(context, current) do
    current_package_set_hash(current) == reported_package_set_hash(context)
  end

  defp artifact_hash_matches_current?(context, current) do
    context.artifact_hash not in [nil, ""] and
      context.artifact_hash == Map.get(current || %{}, :artifact_hash)
  end

  defp force_reconcile(context), do: %{context | reconcile_floor_due?: true}

  defp hash_noop_candidate?(context) do
    successful_scan?(context) and context.upload_reason == @upload_reason_unchanged and
      reported_package_set_hash(context) not in [nil, ""]
  end

  defp hash_freshness_short_circuit?(context, current) do
    hash_matched_unchanged_noop?(context, current) and
      context.package_replacement_noop? and
      not context.degraded_empty_upload? and
      not context.reconcile_floor_due?
  end

  defp emit_hash_noop_result(context, current) do
    current
    |> hash_noop_result(context)
    |> tap(&EndpointInventoryTelemetry.emit_ingest_result/1)
  end

  defp touch_hash_noop_freshness(context, current) do
    invoke_before_hash_freshness_touch(context)

    case Repo.transaction(fn ->
           {updated_count, _} = update_current_scan_freshness(context, current)
           insert_scan_activity_event(current.id, context)

           latest = current_scan_snapshot(context.agent_id)
           result_context = freshness_result_context(context, latest, updated_count)
           hash_noop_result(latest, result_context)
         end) do
      {:ok, result} ->
        {:ok, tap(result, &EndpointInventoryTelemetry.emit_ingest_result/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp invoke_before_hash_freshness_touch(%{before_hash_freshness_touch: hook} = context)
       when is_function(hook, 1),
       do: hook.(context)

  defp invoke_before_hash_freshness_touch(_context), do: :ok

  defp update_current_scan_freshness(context, current) do
    metadata = freshness_observation_metadata(context)
    scan_count_floor = context.reconcile_floor_scan_count

    Repo.update_all(
      from(s in "endpoint_inventory_scans",
        where:
          s.id == ^current.id and s.current == true and
            s.package_set_hash == ^context.package_set_hash and
            s.artifact_hash == ^context.artifact_hash and
            (is_nil(s.last_scan_at) or s.last_scan_at < ^context.last_scan_at),
        update: [
          set: [
            last_scan_at: ^context.last_scan_at,
            last_successful_scan_at:
              fragment(
                "GREATEST(?, ?)",
                s.last_successful_scan_at,
                ^context.last_successful_scan_at
              ),
            ingested_at: ^context.ingested_at,
            reconcile_floor_due:
              fragment(
                "? OR ? OR (? > 0 AND ? + 1 >= ?)",
                s.reconcile_floor_due,
                ^context.reconcile_floor_due?,
                ^scan_count_floor,
                s.unchanged_scan_count,
                ^scan_count_floor
              ),
            metadata: fragment("COALESCE(?, '{}'::jsonb) || ?::jsonb", s.metadata, ^metadata),
            updated_at: ^context.now
          ],
          inc: [unchanged_scan_count: 1]
        ]
      ),
      [],
      prefix: "platform"
    )
  end

  defp freshness_result_context(context, _latest, 1), do: context

  defp freshness_result_context(context, latest, 0) do
    if package_hash_matches_current?(context, latest) and
         artifact_hash_matches_current?(context, latest) do
      %{context | reconcile_floor_due?: false}
    else
      force_reconcile(context)
    end
  end

  defp freshness_observation_metadata(context) do
    %{
      "latest_freshness_observation" =>
        Payload.compact_map(%{
          "scan_id" => context.scan_id,
          "last_scan_at" => Payload.iso8601(context.last_scan_at),
          "last_successful_scan_at" => Payload.iso8601(context.last_successful_scan_at),
          "collector_version" => context.collector_version
        })
    }
  end

  defp hash_noop_result(current, context) do
    %{
      agent_id: context.agent_id,
      device_uid: Map.get(current || %{}, :device_uid) || context.device_uid,
      scan_id: Map.get(current || %{}, :scan_id) || context.scan_id,
      scan_ref: Map.get(current || %{}, :id),
      package_count: Map.get(current || %{}, :package_count, context.package_count),
      artifact_uploaded?: false,
      package_rows_replaced?: false,
      scan_history_recorded?: false,
      package_event_count: 0,
      package_set_hash_mismatch?: context.package_set_hash_mismatch?,
      reconcile_floor?:
        context.reconcile_floor_due? or Map.get(current || %{}, :reconcile_floor_due, false),
      upload_reason: @upload_reason_unchanged,
      directives:
        scan_ack_directives(%{
          reconcile_floor_due?:
            context.reconcile_floor_due? or
              Map.get(current || %{}, :reconcile_floor_due, false)
        }),
      current?: Map.get(current || %{}, :current, false),
      package_change_signal_publish_count: 0,
      short_circuited?: true
    }
  end

  defp full_scan_hash_unchanged?(context, current) do
    reason =
      context.payload
      |> Payload.map_value(:metadata)
      |> Payload.string_value(:reason)

    reason == @metadata_reason_full_scan_hash_unchanged and
      context.artifact_hash not in [nil, ""] and
      context.artifact_hash == Map.get(current || %{}, :artifact_hash)
  end

  defp maybe_short_circuit_noop(payload, agent_id, scan_id) do
    cond do
      scan = existing_scan_snapshot(agent_id, scan_id) ->
        {:ok, emit_short_circuit_result(scan, agent_id, scan_id, short_circuit_reason(payload))}

      upload_already_acknowledged?(payload) ->
        short_circuit_acknowledged_unchanged(payload, agent_id, scan_id)

      empty_not_scanned_payload?(payload) ->
        short_circuit_repeated_not_scanned(payload, agent_id, scan_id)

      true ->
        :continue
    end
  end

  defp short_circuit_acknowledged_unchanged(payload, agent_id, scan_id) do
    reported_hash = Payload.string_value(payload, :package_set_hash)

    case current_scan_snapshot(agent_id) do
      %{package_set_hash: ^reported_hash} = scan when reported_hash not in [nil, ""] ->
        {:ok,
         emit_short_circuit_result(
           scan,
           agent_id,
           scan_id,
           @metadata_reason_upload_already_acknowledged
         )}

      _ ->
        :continue
    end
  end

  defp short_circuit_repeated_not_scanned(payload, agent_id, scan_id) do
    coverage_state = Payload.string_value(payload, :coverage_state) || @state_not_scanned

    case latest_scan_snapshot(agent_id) do
      %{state: @state_not_scanned, coverage_state: ^coverage_state, package_count: 0} = scan ->
        {:ok, emit_short_circuit_result(scan, agent_id, scan_id, "repeated_not_scanned")}

      _ ->
        :continue
    end
  end

  defp normalize_short_circuit_result({:ok, %{short_circuited?: true} = result}) do
    {:ok, Map.delete(result, :short_circuited?)}
  end

  defp normalize_short_circuit_result(other), do: other

  defp emit_short_circuit_result(scan, agent_id, scan_id, reason) do
    scan
    |> short_circuit_result(agent_id, scan_id, reason)
    |> tap(&EndpointInventoryTelemetry.emit_ingest_result/1)
  end

  defp short_circuit_result(scan, agent_id, scan_id, reason) do
    %{
      agent_id: agent_id,
      device_uid: Map.get(scan, :device_uid),
      scan_id: Map.get(scan, :scan_id) || scan_id,
      scan_ref: Map.get(scan, :id),
      package_count: Map.get(scan, :package_count, 0),
      artifact_uploaded?: false,
      package_rows_replaced?: false,
      scan_history_recorded?: false,
      package_event_count: 0,
      package_set_hash_mismatch?: false,
      reconcile_floor?: Map.get(scan, :reconcile_floor_due, false),
      upload_reason: short_circuit_upload_reason(scan, reason),
      directives:
        scan_ack_directives(%{reconcile_floor_due?: Map.get(scan, :reconcile_floor_due, false)}),
      current?: Map.get(scan, :current, false),
      package_change_signal_publish_count: 0,
      short_circuited?: true
    }
  end

  defp short_circuit_upload_reason(_scan, @metadata_reason_upload_already_acknowledged),
    do: @upload_reason_unchanged

  defp short_circuit_upload_reason(scan, _reason),
    do: Map.get(scan, :upload_reason) || @upload_reason_unchanged

  defp upload_already_acknowledged?(payload) do
    payload
    |> Payload.map_value(:metadata)
    |> Payload.string_value(:reason) == @metadata_reason_upload_already_acknowledged
  end

  defp empty_not_scanned_payload?(payload) do
    EndpointInventoryPackageSet.scan_state(payload) == @state_not_scanned and
      Payload.integer_value(payload, :package_count, 0) == 0 and
      Payload.list_value(payload, :packages) == [] and
      map_size(Payload.map_value(payload, :sbom)) == 0
  end

  defp short_circuit_reason(payload) do
    cond do
      upload_already_acknowledged?(payload) -> @metadata_reason_upload_already_acknowledged
      empty_not_scanned_payload?(payload) -> "duplicate_not_scanned"
      true -> "duplicate_scan"
    end
  end

  @spec ingest_vulnerability_match(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest_vulnerability_match(payload, opts \\ []) do
    EndpointInventoryVulnerabilityRisk.ingest(payload, opts)
  end

  defp build_context(payload, agent_id, scan_id, actor, opts) do
    now = DateTime.utc_now()

    device_uid =
      Enum.find_value(
        [
          Payload.string_value(payload, :device_uid),
          resolve_agent_device_uid(agent_id, actor),
          existing_scan_device_uid(agent_id)
        ],
        &canonical_device_uid/1
      )

    packages = EndpointInventoryPackageSet.normalize_packages(payload)

    diagnostics =
      payload
      |> Payload.list_value(:diagnostics)
      |> EndpointInventoryPackageSet.normalize_diagnostics()

    reported_hash = Payload.string_value(payload, :package_set_hash)
    server_hash = EndpointInventoryPackageSet.server_package_set_hash(packages)

    {:ok,
     %{
       payload: payload,
       agent_id: agent_id,
       scan_id: scan_id,
       device_uid: device_uid,
       collector_name: Payload.string_value(payload, :collector_name) || @collector_name,
       collector_version: Payload.string_value(payload, :collector_version),
       state: EndpointInventoryPackageSet.scan_state(payload),
       coverage_state: EndpointInventoryPackageSet.coverage_state(payload, packages, diagnostics),
       reported_coverage_state: Payload.string_value(payload, :coverage_state),
       authoritative_anchor?: authoritative_anchor?(payload, packages),
       package_count: Payload.integer_value(payload, :package_count, length(packages)),
       enabled_sources: EndpointInventoryPackageSet.enabled_diagnostics(payload, diagnostics),
       manager_counts: EndpointInventoryPackageSet.manager_counts(packages),
       source_summaries: diagnostics,
       packages: packages,
       reported_package_set_hash: reported_hash,
       package_set_hash: reported_hash || server_hash,
       artifact_hash: Payload.string_value(payload, :artifact_hash),
       hash_algorithm: Payload.string_value(payload, :hash_algorithm) || @hash_algorithm,
       upload_reason:
         Payload.string_value(payload, :upload_reason) ||
           EndpointInventoryPackageSet.inferred_upload_reason(payload),
       server_package_set_hash: server_hash,
       package_set_hash_mismatch?: false,
       package_replacement_noop?: false,
       package_set_applied_via: "full",
       degraded_empty_upload?: false,
       reported_package_count: Payload.integer_value(payload, :package_count, length(packages)),
       unchanged_scan_count: 0,
       last_changed_scan_at: nil,
       reconcile_floor_due?: false,
       reconcile_floor_scan_count:
         Keyword.get(opts, :reconcile_floor_scan_count, @default_reconcile_floor_scan_count),
       reconcile_floor_max_age_days:
         Keyword.get(opts, :reconcile_floor_max_age_days, @default_reconcile_floor_max_age_days),
       before_hash_freshness_touch: Keyword.get(opts, :before_hash_freshness_touch),
       last_scan_at:
         Payload.datetime_value(payload, :last_scan_at) ||
           Payload.datetime_value(payload, :scanned_at) ||
           now,
       last_successful_scan_at: EndpointInventoryPackageSet.successful_scan_time(payload, now),
       ingested_at: now,
       now: now,
       metadata: Payload.metadata(payload)
     }}
  end

  defp authoritative_anchor?(payload, _packages) do
    map_size(Payload.map_value(payload, :sbom)) > 0 or
      Map.has_key?(payload, :packages) or Map.has_key?(payload, "packages")
  end

  # Applies a change-only package delta to the device's current package set when
  # the agent supplied one AND it is safe to do so. "Safe" means: the scan is a
  # changed upload, the device already has a current package set, the delta's
  # declared base hash matches core's current package_set_hash (the delta is
  # against the exact state core holds), and reconstructing the target set from
  # current_rows + delta yields a server hash equal to the delta's declared
  # target hash. Any mismatch falls back to the full anchor (the payload already
  # carries the full SBOM/package set), so a missed or stale delta can never
  # corrupt the package set — it just costs a full replace.
  defp maybe_apply_package_delta(context, current, current_packages) do
    with true <- changed_upload?(context),
         delta when is_map(delta) <- extract_package_delta(context.payload),
         base_hash when is_binary(base_hash) and base_hash != "" <-
           Payload.string_value(delta, :base_package_set_hash),
         target_hash when is_binary(target_hash) and target_hash != "" <-
           Payload.string_value(delta, :target_package_set_hash),
         current_hash when current_hash == base_hash <-
           current_package_set_hash(current),
         reconstructed = reconstruct_packages_from_delta(current_packages, delta),
         ^target_hash <- EndpointInventoryPackageSet.server_package_set_hash(reconstructed) do
      apply_reconstructed_packages(context, reconstructed, target_hash)
    else
      _ -> context
    end
  end

  defp extract_package_delta(payload) do
    case Payload.map_value(payload, :package_delta) do
      delta when is_map(delta) and map_size(delta) > 0 -> delta
      _ -> nil
    end
  end

  defp current_package_set_hash(nil), do: nil

  defp current_package_set_hash(current) do
    Map.get(current, :server_package_set_hash) || Map.get(current, :package_set_hash)
  end

  defp reconstruct_packages_from_delta(current_packages, delta) do
    EndpointInventoryPackageSet.apply_delta(current_packages, %{
      added:
        EndpointInventoryPackageSet.normalize_delta_packages(Payload.list_value(delta, :added)),
      removed:
        EndpointInventoryPackageSet.normalize_delta_packages(Payload.list_value(delta, :removed)),
      changed:
        EndpointInventoryPackageSet.normalize_delta_packages(Payload.list_value(delta, :changed))
    })
  end

  defp apply_reconstructed_packages(context, packages, target_hash) do
    %{
      context
      | packages: packages,
        package_count: length(packages),
        manager_counts: EndpointInventoryPackageSet.manager_counts(packages),
        server_package_set_hash: target_hash,
        package_set_applied_via: "delta"
    }
  end

  defp allocate_device_fleet_ordinal(context, opts) do
    case invoke_device_fleet_ordinal_allocator(context.device_uid, opts) do
      {:ok, ordinal} ->
        {:ok, Map.put(context, :device_fleet_ordinal, ordinal)}

      {:error, reason} ->
        {:error, {:device_fleet_ordinal_allocation_failed, reason}}
    end
  end

  defp invoke_device_fleet_ordinal_allocator(device_uid, opts) do
    allocator =
      Keyword.get(
        opts,
        :device_fleet_ordinal_allocator,
        {EndpointInventoryFleetOrdinal, :ensure_allocated, []}
      )

    case call_device_fleet_ordinal_allocator(allocator, device_uid) do
      {:ok, _ordinal} = result -> result
      :ok -> {:ok, nil}
      nil -> {:ok, nil}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_device_fleet_ordinal_allocator_result, other}}
    end
  end

  defp call_device_fleet_ordinal_allocator(allocator, device_uid) when is_function(allocator, 1),
    do: allocator.(device_uid)

  defp call_device_fleet_ordinal_allocator({module, function, extra_args}, device_uid)
       when is_atom(module) and is_atom(function) and is_list(extra_args),
       do: apply(module, function, [device_uid | extra_args])

  defp call_device_fleet_ordinal_allocator(_allocator, _device_uid), do: {:ok, nil}

  defp upsert_scan(context, artifact) do
    row = %{
      device_uid: context.device_uid,
      agent_id: context.agent_id,
      scan_id: context.scan_id,
      collector_name: context.collector_name,
      collector_version: context.collector_version,
      state: context.state,
      coverage_state: context.coverage_state,
      package_count: context.package_count,
      enabled_sources: context.enabled_sources,
      manager_counts: context.manager_counts,
      source_summaries: context.source_summaries,
      artifact_count: if(is_nil(artifact), do: 0, else: 1),
      current: false,
      last_successful_scan_at: context.last_successful_scan_at,
      last_scan_at: context.last_scan_at,
      last_changed_scan_at: context.last_changed_scan_at,
      ingested_at: context.ingested_at,
      package_set_hash: context.package_set_hash,
      artifact_hash: context.artifact_hash,
      hash_algorithm: context.hash_algorithm,
      upload_reason: context.upload_reason,
      server_package_set_hash: context.server_package_set_hash,
      package_set_hash_mismatch: context.package_set_hash_mismatch?,
      unchanged_scan_count: context.unchanged_scan_count,
      reconcile_floor_due: context.reconcile_floor_due?,
      metadata: scan_metadata(context),
      inserted_at: context.now,
      updated_at: context.now
    }

    {_, [%{id: id}]} =
      Repo.insert_all(
        "endpoint_inventory_scans",
        [row],
        prefix: "platform",
        on_conflict:
          {:replace,
           [
             :device_uid,
             :collector_name,
             :collector_version,
             :state,
             :coverage_state,
             :package_count,
             :enabled_sources,
             :manager_counts,
             :source_summaries,
             :artifact_count,
             :current,
             :last_successful_scan_at,
             :last_scan_at,
             :last_changed_scan_at,
             :ingested_at,
             :package_set_hash,
             :artifact_hash,
             :hash_algorithm,
             :upload_reason,
             :server_package_set_hash,
             :package_set_hash_mismatch,
             :unchanged_scan_count,
             :reconcile_floor_due,
             :metadata,
             :updated_at
           ]},
        conflict_target: [:agent_id, :scan_id],
        returning: [:id]
      )

    id
  end

  defp replace_packages(scan_ref, context) do
    delete_scan_rows("endpoint_inventory_packages", scan_ref)
    endpoint_package_refs = ensure_endpoint_packages(context.packages, context.now)

    rows =
      Enum.map(context.packages, fn package ->
        Map.merge(package, %{
          scan_ref: scan_ref,
          endpoint_package_ref:
            Map.fetch!(endpoint_package_refs, EndpointInventoryPackageSet.coordinate_key(package)),
          device_uid: context.device_uid,
          agent_id: context.agent_id,
          current: false,
          inserted_at: context.now,
          updated_at: context.now
        })
      end)

    if rows != [] do
      Repo.insert_all("endpoint_inventory_packages", rows, prefix: "platform")
    end

    length(rows)
  end

  defp maybe_replace_packages(_scan_ref, %{package_replacement_noop?: true} = context) do
    context.package_count
  end

  defp maybe_replace_packages(scan_ref, context), do: replace_packages(scan_ref, context)

  defp insert_scan_activity_event(scan_ref, context) do
    event_time = context.last_scan_at || context.ingested_at || context.now
    event_uuid = endpoint_inventory_scan_event_uuid(context)
    activity_id = endpoint_inventory_scan_activity_id(context)
    status_id = endpoint_inventory_scan_status_id(context)
    severity_id = endpoint_inventory_scan_severity_id(context)
    class_uid = OCSF.class_scan_activity()

    row = %{
      id: Ecto.UUID.dump!(event_uuid),
      time: event_time,
      class_uid: class_uid,
      category_uid: OCSF.category_application_activity(),
      type_uid: OCSF.type_uid(class_uid, activity_id),
      activity_id: activity_id,
      activity_name: OCSF.scan_activity_name(activity_id),
      severity_id: severity_id,
      severity: OCSF.severity_name(severity_id),
      message: endpoint_inventory_scan_message(context),
      status_id: status_id,
      status: OCSF.status_name(status_id),
      status_code: context.state,
      status_detail: context.coverage_state,
      metadata: endpoint_inventory_scan_activity_metadata(scan_ref, context),
      observables: [],
      trace_id: nil,
      span_id: nil,
      actor:
        OCSF.build_actor(app_name: context.collector_name, app_ver: context.collector_version),
      device: OCSF.build_device(uid: context.device_uid, name: context.agent_id),
      src_endpoint: %{},
      dst_endpoint: %{},
      log_name: "endpoint_inventory.scan",
      log_provider: "endpoint_inventory",
      log_level: if(successful_scan?(context), do: "INFO", else: "WARN"),
      log_version: Payload.string_value(context.payload, :schema_version),
      unmapped: %{
        "agent_id" => context.agent_id,
        "device_uid" => context.device_uid,
        "scan_id" => context.scan_id,
        "state" => context.state,
        "coverage_state" => context.coverage_state,
        "package_count" => context.package_count
      },
      raw_data: normalize_scan_activity_raw_payload(context.payload)
    }

    Repo.insert_all("ocsf_events", [row],
      prefix: "platform",
      on_conflict: :nothing,
      conflict_target: [:time, :id],
      returning: false
    )

    :ok
  end

  defp uuid_string(<<_::128>> = id) do
    case Ecto.UUID.load(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid_string(id) when is_binary(id), do: id
  defp uuid_string(_id), do: nil

  defp endpoint_inventory_scan_activity_id(context) do
    if successful_scan?(context),
      do: OCSF.activity_scan_completed(),
      else: OCSF.activity_scan_error()
  end

  defp endpoint_inventory_scan_status_id(context) do
    if successful_scan?(context), do: OCSF.status_success(), else: OCSF.status_failure()
  end

  defp endpoint_inventory_scan_severity_id(context) do
    if successful_scan?(context), do: OCSF.severity_informational(), else: OCSF.severity_medium()
  end

  defp endpoint_inventory_scan_message(context) do
    "Endpoint inventory scan #{context.state} on #{context.agent_id}: #{context.package_count} packages"
  end

  defp endpoint_inventory_scan_activity_metadata(scan_ref, context) do
    %{
      "version" => "1.9.0-dev",
      "product" => %{
        "name" => context.collector_name,
        "vendor_name" => "Carver Automation",
        "version" => context.collector_version
      },
      "source" => "endpoint_inventory",
      "scan" => %{
        "uid" => context.scan_id,
        "name" => "Endpoint package inventory",
        "total" => context.package_count,
        "num_detections" => 0,
        "num_skipped_items" => 0,
        "start_time" => Payload.iso8601(context.last_scan_at),
        "end_time" => Payload.iso8601(context.last_successful_scan_at || context.last_scan_at)
      },
      "service_radar" => %{
        "source_type" => "endpoint_inventory",
        "addon_id" => "endpoint-inventory",
        "agent_id" => context.agent_id,
        "device_uid" => context.device_uid,
        "scan_id" => context.scan_id,
        "scan_ref" => uuid_string(scan_ref),
        "package_count" => context.package_count,
        "coverage_state" => context.coverage_state,
        "upload_reason" => context.upload_reason,
        "ocsf_class" => "scan_activity"
      }
    }
  end

  defp endpoint_inventory_scan_event_uuid(context) do
    [
      "endpoint_inventory",
      context.agent_id,
      context.scan_id,
      Payload.iso8601(context.last_scan_at)
    ]
    |> Enum.join(":")
    |> deterministic_uuid()
  end

  defp ensure_endpoint_packages([], _now), do: %{}

  defp ensure_endpoint_packages(packages, now) do
    rows =
      packages
      |> Enum.map(&EndpointInventoryPackageSet.endpoint_package_row(&1, now))
      |> Enum.uniq_by(& &1.coordinate_key)

    {_count, returned} =
      Repo.insert_all("endpoint_packages", rows,
        prefix: "platform",
        on_conflict:
          {:replace,
           [
             :purl_canonical,
             :primary_cpe,
             :cpes,
             :package_manager,
             :name,
             :version,
             :architecture,
             :ecosystem,
             :source_scope,
             :metadata,
             :updated_at
           ]},
        conflict_target: [:coordinate_key],
        returning: [:id, :coordinate_key]
      )

    Map.new(returned, fn row -> {row.coordinate_key, row.id} end)
  end

  defp maybe_promote_current(scan_ref, context) do
    if successful_scan?(context) do
      promote_current(scan_ref, context)
    else
      :ok
    end
  end

  defp promote_current(scan_ref, context) do
    now = context.now

    if context.package_replacement_noop? do
      Repo.update_all(
        from(p in "endpoint_inventory_packages",
          where: p.agent_id == ^context.agent_id and p.current == true
        ),
        [set: [scan_ref: scan_ref, updated_at: now]],
        prefix: "platform"
      )
    end

    Repo.update_all(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^context.agent_id and s.current == true
      ),
      [set: [current: false, updated_at: now]],
      prefix: "platform"
    )

    if not context.package_replacement_noop? do
      Repo.update_all(
        from(p in "endpoint_inventory_packages",
          where: p.agent_id == ^context.agent_id and p.current == true
        ),
        [set: [current: false, updated_at: now]],
        prefix: "platform"
      )
    end

    Repo.update_all(
      from(s in "endpoint_inventory_scans", where: s.id == ^scan_ref),
      [set: [current: true, updated_at: now]],
      prefix: "platform"
    )

    if not context.package_replacement_noop? do
      Repo.update_all(
        from(p in "endpoint_inventory_packages", where: p.scan_ref == ^scan_ref),
        [set: [current: true, updated_at: now]],
        prefix: "platform"
      )
    end
  end

  defp successful_scan?(%{state: "unchanged", coverage_state: coverage})
       when coverage in [@coverage_state_unchanged, "complete"], do: true

  defp successful_scan?(%{state: state, reported_coverage_state: "complete"})
       when state in ["scanned", "complete", "success"], do: true

  defp successful_scan?(%{
         state: state,
         reported_coverage_state: nil,
         coverage_state: "complete",
         authoritative_anchor?: true
       })
       when state in ["scanned", "complete", "success"], do: true

  defp successful_scan?(_context), do: false

  defp existing_scan_snapshot(agent_id, scan_id) do
    Repo.one(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and s.scan_id == ^scan_id,
        select: %{
          id: s.id,
          device_uid: s.device_uid,
          scan_id: s.scan_id,
          state: s.state,
          coverage_state: s.coverage_state,
          package_count: s.package_count,
          package_set_hash: s.package_set_hash,
          upload_reason: s.upload_reason,
          reconcile_floor_due: s.reconcile_floor_due,
          current: s.current
        },
        limit: 1
      ),
      prefix: "platform"
    )
  end

  defp latest_scan_snapshot(agent_id) do
    Repo.one(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id,
        select: %{
          id: s.id,
          device_uid: s.device_uid,
          scan_id: s.scan_id,
          state: s.state,
          coverage_state: s.coverage_state,
          package_count: s.package_count,
          package_set_hash: s.package_set_hash,
          upload_reason: s.upload_reason,
          reconcile_floor_due: s.reconcile_floor_due,
          current: s.current
        },
        order_by: [desc: s.last_scan_at, desc: s.inserted_at],
        limit: 1
      ),
      prefix: "platform"
    )
  end

  defp current_scan_snapshot(agent_id) do
    Repo.one(
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and s.current == true,
        select: %{
          id: s.id,
          device_uid: s.device_uid,
          package_count: s.package_count,
          scan_id: s.scan_id,
          state: s.state,
          coverage_state: s.coverage_state,
          package_set_hash: s.package_set_hash,
          artifact_hash: s.artifact_hash,
          upload_reason: s.upload_reason,
          server_package_set_hash: s.server_package_set_hash,
          last_successful_scan_at: s.last_successful_scan_at,
          last_scan_at: s.last_scan_at,
          last_changed_scan_at: s.last_changed_scan_at,
          unchanged_scan_count: s.unchanged_scan_count,
          reconcile_floor_due: s.reconcile_floor_due,
          metadata: s.metadata,
          current: s.current
        },
        limit: 1
      ),
      prefix: "platform"
    )
  end

  defp current_package_row_count(agent_id) do
    Repo.one(
      from(p in "endpoint_inventory_packages",
        where: p.agent_id == ^agent_id and p.current == true,
        select: count(p.id)
      ),
      prefix: "platform"
    ) || 0
  end

  defp current_package_rows(%{package_replacement_noop?: true}), do: []

  defp current_package_rows(context) do
    if successful_scan?(context) do
      Repo.all(
        from(p in "endpoint_inventory_packages",
          where: p.agent_id == ^context.agent_id and p.current == true,
          select: %{
            name: p.name,
            version: p.version,
            architecture: p.architecture,
            package_manager: p.package_manager,
            ecosystem: p.ecosystem,
            purl: p.purl,
            purl_canonical: p.purl_canonical,
            cpes: p.cpes,
            supplier: p.supplier,
            license: p.license,
            source: p.source,
            evidence: p.evidence,
            metadata: p.metadata
          }
        ),
        prefix: "platform"
      )
    else
      []
    end
  end

  defp apply_hash_freshness(context, current, current_row_count) do
    hash_matched_noop? = hash_matched_unchanged_noop?(context, current)

    # A degraded/empty upload carries no packages and is *not* a hash-matched
    # unchanged noop. Replacing or promoting on it would wipe a non-empty current
    # inventory (e.g. an `unchanged` upload that omits the SBOM, a partial scan, or
    # a hash drift). When there is something to protect, treat it like the noop path
    # so the existing current rows are preserved and re-stamped to the new scan.
    degraded_empty? = degraded_empty_upload?(context, hash_matched_noop?, current_row_count)
    package_replacement_noop? = hash_matched_noop? or degraded_empty?

    server_hash = effective_server_package_set_hash(context, current, package_replacement_noop?)
    mismatch? = package_set_hash_mismatch?(context.reported_package_set_hash, server_hash)

    package_set_hash =
      effective_package_set_hash(context, current, package_replacement_noop?, server_hash)

    unchanged_count = unchanged_scan_count(context, current, package_replacement_noop?)
    last_changed_at = last_changed_scan_at(context, current, package_replacement_noop?)
    reconcile_floor_due? = reconcile_floor_due?(context, last_changed_at, unchanged_count)

    package_count =
      reconciled_package_count(context, package_replacement_noop?, current_row_count)

    if mismatch? do
      Logger.warning(
        "Endpoint inventory package_set_hash mismatch: agent_id=#{context.agent_id} scan_id=#{context.scan_id} reported=#{context.reported_package_set_hash} server=#{server_hash}"
      )
    end

    if degraded_empty? do
      Logger.warning(
        "Endpoint inventory empty/SBOM-less upload would have wiped #{current_row_count} current packages; preserving inventory: agent_id=#{context.agent_id} scan_id=#{context.scan_id} upload_reason=#{context.upload_reason} reported_package_count=#{context.reported_package_count}"
      )
    end

    %{
      context
      | package_set_hash: package_set_hash,
        server_package_set_hash: server_hash,
        package_set_hash_mismatch?: mismatch?,
        package_replacement_noop?: package_replacement_noop?,
        degraded_empty_upload?: degraded_empty?,
        package_count: package_count,
        coverage_state: effective_coverage_state(context, degraded_empty?),
        unchanged_scan_count: unchanged_count,
        last_changed_scan_at: last_changed_at,
        reconcile_floor_due?: reconcile_floor_due?
    }
  end

  defp hash_matched_unchanged_noop?(context, current) do
    successful_scan?(context) and not is_nil(current) and
      reported_package_set_hash(context) not in [nil, ""] and
      reported_package_set_hash(context) == current.package_set_hash and
      context.upload_reason == @upload_reason_unchanged
  end

  # True when the upload carries no packages, isn't a hash-matched unchanged noop,
  # and there is a non-empty current inventory that a wholesale replace would destroy.
  defp degraded_empty_upload?(context, hash_matched_noop?, current_row_count) do
    not hash_matched_noop? and context.packages == [] and current_row_count > 0
  end

  # Make the scan's surfaced package_count reflect the rows it can actually back:
  # for replacing scans that's the exploded package list. For a noop/degraded upload
  # the count is the preserved current inventory *only when this scan becomes current*
  # (promotion re-stamps those rows to it); an unsuccessful degraded upload backs no
  # rows of its own, so it reports 0. The reported (collector) count is preserved
  # separately under metadata `raw_package_count`/`reported_package_count`.
  defp reconciled_package_count(context, true, current_row_count) do
    if successful_scan?(context), do: current_row_count, else: 0
  end

  defp reconciled_package_count(context, false, _current_row_count), do: length(context.packages)

  defp effective_coverage_state(_context, true), do: @coverage_state_unchanged
  defp effective_coverage_state(context, false), do: context.coverage_state

  defp reported_package_set_hash(context) do
    context.reported_package_set_hash || context.package_set_hash
  end

  defp effective_server_package_set_hash(context, current, true) do
    context.server_package_set_hash || Map.get(current || %{}, :server_package_set_hash) ||
      Map.get(current || %{}, :package_set_hash)
  end

  defp effective_server_package_set_hash(context, _current, false) do
    context.server_package_set_hash
  end

  defp effective_package_set_hash(context, current, true, _server_hash) do
    reported_package_set_hash(context) || Map.get(current || %{}, :package_set_hash)
  end

  defp effective_package_set_hash(context, _current, false, server_hash) do
    server_hash || reported_package_set_hash(context)
  end

  defp package_set_hash_mismatch?(nil, _server_hash), do: false
  defp package_set_hash_mismatch?(_package_set_hash, nil), do: false

  defp package_set_hash_mismatch?(package_set_hash, server_hash),
    do: package_set_hash != server_hash

  defp unchanged_scan_count(_context, current, true) do
    Map.get(current || %{}, :unchanged_scan_count, 0) + 1
  end

  defp unchanged_scan_count(context, _current, false) do
    if successful_scan?(context), do: 0, else: 0
  end

  defp last_changed_scan_at(_context, current, true) do
    Map.get(current || %{}, :last_changed_scan_at)
  end

  defp last_changed_scan_at(context, _current, false) do
    if successful_scan?(context) and changed_upload?(context) do
      context.last_successful_scan_at || context.last_scan_at
    end
  end

  defp changed_upload?(context), do: context.upload_reason != @upload_reason_unchanged

  defp reconcile_floor_due?(context, last_changed_at, unchanged_scan_count) do
    successful_scan?(context) and context.upload_reason == @upload_reason_unchanged and
      (scan_floor_due?(context.reconcile_floor_scan_count, unchanged_scan_count) or
         age_floor_due?(context, last_changed_at))
  end

  defp scan_floor_due?(scan_count_floor, unchanged_scan_count)
       when is_integer(scan_count_floor) and scan_count_floor > 0 do
    unchanged_scan_count >= scan_count_floor
  end

  defp scan_floor_due?(_scan_count_floor, _unchanged_scan_count), do: false

  defp age_floor_due?(context, %DateTime{} = last_changed_at) do
    max_age_days = context.reconcile_floor_max_age_days

    is_integer(max_age_days) and max_age_days > 0 and
      DateTime.diff(context.last_scan_at, last_changed_at, :day) >= max_age_days
  end

  defp age_floor_due?(_context, _last_changed_at), do: false

  defp scan_ack_directives(%{reconcile_floor_due?: true}) do
    %{
      "endpoint_inventory" => %{
        "reconcile_floor" => true,
        "upload_reason" => @upload_reason_changed,
        "message" => "server reconcile floor reached; next scan must perform a full upload"
      }
    }
  end

  defp scan_ack_directives(_context), do: %{}

  defp scan_metadata(context) do
    context.metadata
    |> Map.merge(%{
      "schema_version" => Payload.string_value(context.payload, :schema_version),
      "os" => Payload.map_value(context.payload, :os),
      "source" => "endpoint_inventory",
      "reported_package_set_hash" => context.reported_package_set_hash,
      "package_set_hash" => context.package_set_hash,
      "artifact_hash" => context.artifact_hash,
      "hash_algorithm" => context.hash_algorithm,
      "config_hash" => Payload.string_value(context.payload, :config_hash),
      "duration_ms" => Payload.integer_value(context.payload, :duration_ms, nil),
      "truncated" => Payload.boolean_value(context.payload, :truncated),
      "enabled_plugins" => Payload.string_list_value(context.payload, :enabled_plugins),
      "detected_plugins" => Payload.string_list_value(context.payload, :detected_plugins),
      "upload_reason" => context.upload_reason,
      "server_package_set_hash" => context.server_package_set_hash,
      "package_set_hash_mismatch" => context.package_set_hash_mismatch?,
      "unchanged_scan_count" => context.unchanged_scan_count,
      "last_changed_scan_at" => Payload.iso8601(context.last_changed_scan_at),
      "reconcile_floor_due" => context.reconcile_floor_due?,
      "package_set_applied_via" => context.package_set_applied_via,
      "raw_package_count" => Payload.integer_value(context.payload, :package_count, nil),
      "reported_package_count" => context.reported_package_count,
      "loaded_package_count" => context.package_count,
      "degraded_empty_upload" => context.degraded_empty_upload?
    })
    |> Payload.compact_map()
  end

  defp resolve_agent_device_uid(agent_id, actor) do
    query = Ash.Query.for_read(Agent, :by_uid, %{uid: agent_id})

    case Ash.read_one(query, actor: actor) do
      {:ok, %{device_uid: device_uid}} when is_binary(device_uid) and device_uid != "" ->
        device_uid

      _ ->
        nil
    end
  end

  defp existing_scan_device_uid(agent_id) do
    query =
      from(s in "endpoint_inventory_scans",
        where: s.agent_id == ^agent_id and not is_nil(s.device_uid),
        select: s.device_uid,
        order_by: [desc_nulls_last: s.last_scan_at, desc: s.inserted_at],
        limit: 1
      )

    Repo.one(query, prefix: "platform")
  end

  defp canonical_device_uid("sr:" <> _ = device_uid), do: device_uid
  defp canonical_device_uid(_device_uid), do: nil

  defp normalize_scan_activity_raw_payload(payload) when is_map(payload) do
    payload
    |> Map.drop([:sbom, "sbom"])
    |> Jason.encode()
    |> case do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(payload)
    end
  end

  defp normalize_scan_activity_raw_payload(payload), do: inspect(payload)

  defp deterministic_uuid(key) do
    <<a1::32, a2::16, a3::16, a4::16, a5::48, _rest::binary>> = :crypto.hash(:sha256, key)
    versioned_a3 = a3 |> band(0x0FFF) |> bor(0x4000)
    versioned_a4 = a4 |> band(0x3FFF) |> bor(0x8000)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a1, a2, versioned_a3, versioned_a4, a5])
    |> IO.iodata_to_binary()
  end

  defp delete_scan_rows(table, scan_ref) do
    query = from(r in table, where: r.scan_ref == ^scan_ref)
    Repo.delete_all(query, prefix: "platform")
  end
end
