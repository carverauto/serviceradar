defmodule ServiceRadar.Inventory.Identity.MergeEngine do
  @moduledoc """
  Device merge/unmerge execution with stability guards.

  Guards applied to every automatic merge: distinct agent identities
  veto the merge; a per-pair cooldown (merge-audit history, either
  direction) breaks oscillation loops. Merges are transactional and
  audited; unmerge reverses an incorrect merge from the audit trail.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.CompositeChecks.DeviceCompositeCheckResult
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceAgentAvailability
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DeviceSourceObservation
  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.EndpointInventoryMoves
  alias ServiceRadar.Inventory.Identity.MergePolicy
  alias ServiceRadar.Inventory.Identity.Reassignments
  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  def merge_conflicting_devices(canonical_id, device_ids, matches, actor) do
    details = %{
      identifiers:
        Enum.map(matches, fn {id_type, %{value: value, device_id: device_id}} ->
          %{type: id_type, value: value, device_id: device_id}
        end)
    }

    cond do
      source_conflict = SourceAuthorityGuard.conflict_details(device_ids) ->
        _ =
          SourceAuthorityGuard.record_blocked(
            source_conflict,
            "identifier_conflict",
            details
          )

        emit_merge_guard_telemetry(
          :source_authority_conflict,
          "identifier_conflict",
          Enum.join(device_ids, ","),
          canonical_id
        )

      MergePolicy.merge_allowed_for_matches?(matches) ->
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

      true ->
        blocked_reason = MergePolicy.blocked_merge_reason(matches)

        Logger.warning(
          "Blocked merge: shared identifiers are not eligible for auto-merge. " <>
            "Devices: #{inspect(device_ids)}, " <>
            "identifiers: #{inspect(details.identifiers)}"
        )

        MergePolicy.emit_blocked_merge_telemetry(blocked_reason, device_ids, details.identifiers)
    end
  end

  @doc """
  Merge a duplicate device into a canonical device and reassign related records.
  """
  @spec merge_devices(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def merge_devices(from_device_id, to_device_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:device_merge))
    reason = Keyword.get(opts, :reason, "identity_resolution")
    details = Keyword.get(opts, :details, %{})

    cond do
      from_device_id == to_device_id ->
        :ok

      merge_guard_blocked = merge_guard_violation(from_device_id, to_device_id, reason, actor) ->
        emit_merge_guard_telemetry(merge_guard_blocked, reason, from_device_id, to_device_id)

        Logger.warning(
          "Blocked merge #{from_device_id} -> #{to_device_id} " <>
            "(reason: #{reason}, guard: #{merge_guard_blocked})"
        )

        {:error, {:merge_blocked, merge_guard_blocked}}

      true ->
        do_merge_devices(from_device_id, to_device_id, reason, details, actor)
    end
  end

  # Guards that apply to every automatic merge path (ingest-time, alias,
  # scheduled backfill). Manual/administrative merges bypass them.
  defp merge_guard_violation(from_device_id, to_device_id, reason, actor) do
    cond do
      manual_override_merge_reason?(reason) or reason == "unmerge" ->
        nil

      AliasGuard.distinct_agent_identity_conflict?(from_device_id, to_device_id, actor) ->
        :distinct_agent_identity

      source_conflict =
          SourceAuthorityGuard.conflict_details([from_device_id, to_device_id]) ->
        _ = SourceAuthorityGuard.record_blocked(source_conflict, reason)
        :source_authority_conflict

      guard = provisional_topology_merge_violation(from_device_id, to_device_id, actor) ->
        guard

      recent_pair_merge?(from_device_id, to_device_id, actor) ->
        :merge_cooldown

      true ->
        nil
    end
  end

  # Merge-inert provisional topology identities (endpoint attachment identity
  # promotion): a device minted from mapper topology sightings may be merged
  # INTO a corroborated device when identity-proof rules allow it, but it must
  # never absorb a corroborated device's identifiers (the corroborated device
  # is never merged INTO the provisional one), and devices with distinct
  # registered hardware MACs are never merged in either direction.
  defp provisional_topology_merge_violation(from_device_id, to_device_id, actor) do
    from_provisional? = provisional_topology_sighting_device?(from_device_id, actor)
    to_provisional? = provisional_topology_sighting_device?(to_device_id, actor)

    if from_provisional? or to_provisional? do
      provisional_topology_merge_guard(
        from_provisional?,
        to_provisional?,
        AliasGuard.distinct_mac_conflict?(from_device_id, to_device_id, actor)
      )
    end
  end

  # Pure decision table for the provisional-topology merge guard; public for
  # tests. Inputs: whether the merge source/target is a provisional
  # mapper-topology-sighted device, and whether the pair holds disjoint
  # registered MAC identities.
  @doc false
  def provisional_topology_merge_guard(from_provisional?, to_provisional?, distinct_macs?) do
    cond do
      not from_provisional? and not to_provisional? -> nil
      to_provisional? and not from_provisional? -> :provisional_identity_absorb
      distinct_macs? -> :distinct_mac_identity
      true -> nil
    end
  end

  defp provisional_topology_sighting_device?(device_id, actor) when is_binary(device_id) do
    case Device.get_by_uid(device_id, true, actor: actor) do
      {:ok, %Device{metadata: metadata}} when is_map(metadata) ->
        Map.get(metadata, "identity_state") == "provisional" and
          Map.get(metadata, "identity_source") == "mapper_topology_sighting"

      _ ->
        false
    end
  rescue
    e ->
      Logger.warning(
        "Provisional-identity merge guard lookup failed for #{device_id}: #{inspect(e)}"
      )

      false
  end

  defp provisional_topology_sighting_device?(_device_id, _actor), do: false

  # Oscillation breaker: a pair that already merged (in either direction)
  # within the cooldown window is ping-ponging — re-merging would feed the
  # loop, so block and alert instead.
  defp recent_pair_merge?(device_a, device_b, actor) do
    window_seconds = merge_cooldown_seconds()
    cutoff = DateTime.add(DateTime.utc_now(), -window_seconds, :second)
    query_opts = if actor, do: [actor: actor], else: []

    MergeAudit
    |> Ash.Query.filter(
      ((from_device_id == ^device_a and to_device_id == ^device_b) or
         (from_device_id == ^device_b and to_device_id == ^device_a)) and
        created_at > ^cutoff
    )
    |> Ash.Query.limit(1)
    |> Ash.read(query_opts)
    |> case do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  rescue
    e ->
      Logger.warning("Merge cooldown lookup failed: #{inspect(e)}")
      false
  end

  defp merge_cooldown_seconds do
    :serviceradar
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:merge_cooldown_seconds, 86_400)
  end

  defp emit_merge_guard_telemetry(guard, reason, from_device_id, to_device_id) do
    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :merge, :guard_blocked],
      %{count: 1},
      %{
        guard: guard,
        reason: reason,
        from_device_id: from_device_id,
        to_device_id: to_device_id
      }
    )
  end

  defp do_merge_devices(from_device_id, to_device_id, reason, details, actor) do
    resources = [
      Device,
      DeviceIdentifier,
      DeviceSourceObservation,
      Interface,
      MergeAudit,
      ServiceCheck,
      Alert,
      Agent,
      DeviceAgentAvailability,
      DeviceCompositeCheckResult,
      DeviceAliasState
    ]

    # Ash.transact/3, NOT the deprecated Ash.transaction/3. The two differ in
    # exactly one respect: transact passes rollback_on_error?: true, which is
    # what makes a `with` that RETURNS {:error, _} roll back rather than commit
    # (ash/lib/ash.ex:4243-4257 vs :4140-4153; the flag defaults to false at
    # ash/lib/ash/data_layer/data_layer.ex:585 and this app sets no override).
    #
    # Without it a merge that failed partway COMMITTED: identifiers already
    # reassigned to the survivor, the source device still live and untombstoned,
    # and no merge_audit row. Resolver.follow_canonical_device_id/2 cannot detect
    # that state because it keys on deleted_at, so nothing downstream could ever
    # tell that the identity decision had gone stale.
    resources
    |> Ash.transact(fn ->
      with {:ok, %Device{} = from_device} <-
             Device.get_by_uid(from_device_id, false, actor: actor),
           {:ok, %Device{} = to_device} <- Device.get_by_uid(to_device_id, false, actor: actor),
           :ok <-
             source_authority_transaction_guard(from_device_id, to_device_id, reason),
           audit_details = merge_audit_details(details, from_device),
           :ok <- preserve_survivor_attributes(from_device_id, to_device_id),
           :ok <- Reassignments.reassign_device_identifiers(from_device_id, to_device_id, actor),
           :ok <-
             Reassignments.reassign_source_observations(from_device_id, to_device_id, actor),
           :ok <- Reassignments.reassign_service_checks(from_device_id, to_device_id, actor),
           :ok <- Reassignments.reassign_alerts(from_device_id, to_device_id, actor),
           :ok <- Reassignments.reassign_agents(from_device_id, to_device_id, actor),
           :ok <- Reassignments.reassign_availability(from_device_id, to_device_id, actor),
           :ok <-
             Reassignments.reassign_composite_results(from_device_id, to_device_id, actor),
           :ok <- Reassignments.reassign_alias_states(from_device_id, to_device_id, actor),
           :ok <- Reassignments.reassign_interfaces(from_device_id, to_device_id, actor),
           :ok <-
             EndpointInventoryMoves.reconcile_endpoint_inventory_device_identity(
               from_device_id,
               to_device_id
             ),
           {:ok, _merge} <-
             MergeAudit.record(
               %{
                 from_device_id: from_device_id,
                 to_device_id: to_device_id,
                 reason: reason,
                 source: "identity_reconciler",
                 details: audit_details
               },
               actor: actor
             ),
           {:ok, _} <- tombstone_merged_device(from_device, actor),
           # The survivor's identity composition changed: it now owns the
           # merged-away device's identifiers. Once here, not per reassigned
           # record -- the reassignments above are bulk updates, and a
           # per-identifier bump would be N writes describing one transition.
           #
           # Last in the chain so the exclusive lock on a live, hot device row is
           # held for as little of the merge as possible. Ordering is otherwise
           # immaterial: this is all one Ash.transact, so no reader outside the
           # transaction can observe an intermediate state.
           #
           # The source needs no bump here -- tombstone_merged_device/2 goes
           # through :soft_delete, which carries one.
           {:ok, _} <- Device.bump_identity_revision(to_device, actor: actor) do
        :ok
      end
    end)
    |> case do
      {:ok, :ok} ->
        emit_merge_executed_telemetry(reason, from_device_id, to_device_id)
        :ok

      # With transact a returned {:error, _} arrives here as {:error, _}, having
      # rolled back. {:ok, other} is retained for a `with` clause that fails with
      # some other shape, which does NOT trigger a rollback.
      {:ok, other} ->
        emit_merge_failed_telemetry(reason, from_device_id, to_device_id, other)
        other

      {:error, _} = error ->
        maybe_record_transaction_source_conflict(error, reason, details)
        emit_merge_failed_telemetry(reason, from_device_id, to_device_id, error)
        error
    end
  end

  defp source_authority_transaction_guard(from_device_id, to_device_id, reason) do
    if manual_override_merge_reason?(reason) or reason == "unmerge" do
      :ok
    else
      SourceAuthorityGuard.ensure_merge_allowed([from_device_id, to_device_id], lock: true)
    end
  end

  defp maybe_record_transaction_source_conflict(
         {:error, {:source_authority_conflict, conflict}},
         reason,
         details
       ) do
    _ = SourceAuthorityGuard.record_blocked(conflict, reason, details)
    :ok
  end

  defp maybe_record_transaction_source_conflict(_error, _reason, _details), do: :ok

  # A merge retires one row but must not retire operator-owned classification
  # with it. Tags are user data (CSV imports are a common source), metadata is
  # multi-source enrichment, and discovery_sources is provenance. Preserve the
  # union atomically before tombstoning the source; values already present on
  # the chosen survivor win key conflicts.
  #
  # This is deliberately one database expression rather than a read/Map.merge/
  # write through :update. Device metadata has concurrent writers, and a stale
  # whole-map write would silently erase whatever landed while the merge waited
  # for the row lock.
  defp preserve_survivor_attributes(from_device_id, to_device_id) do
    case Repo.query(
           """
           UPDATE platform.ocsf_devices AS survivor
           SET tags = COALESCE(source.tags, '{}'::jsonb) ||
                      COALESCE(survivor.tags, '{}'::jsonb),
               metadata = COALESCE(source.metadata, '{}'::jsonb) ||
                          COALESCE(survivor.metadata, '{}'::jsonb) ||
                          jsonb_build_object('type_manually_set',
                        (COALESCE(source.metadata->'type_manually_set' = 'true'::jsonb,
                          'manual' = ANY(COALESCE(source.discovery_sources, ARRAY[]::text[])))
                        AND lower(COALESCE(NULLIF(btrim(source.type), ''), 'unknown')) <> 'unknown') OR
                        (COALESCE(survivor.metadata->'type_manually_set' = 'true'::jsonb,
                          'manual' = ANY(COALESCE(survivor.discovery_sources, ARRAY[]::text[])))
                        AND lower(COALESCE(NULLIF(btrim(survivor.type), ''), 'unknown')) <> 'unknown')),
               type = CASE
                 WHEN COALESCE(source.metadata->'type_manually_set' = 'true'::jsonb,
                        'manual' = ANY(COALESCE(source.discovery_sources, ARRAY[]::text[])))
                      AND lower(COALESCE(NULLIF(btrim(source.type), ''), 'unknown')) <> 'unknown'
                      AND NOT (
                        COALESCE(survivor.metadata->'type_manually_set' = 'true'::jsonb,
                        'manual' = ANY(COALESCE(survivor.discovery_sources, ARRAY[]::text[])))
                        AND lower(COALESCE(NULLIF(btrim(survivor.type), ''), 'unknown')) <> 'unknown'
                      )
                   THEN source.type
                 ELSE survivor.type
               END,
               type_id = CASE
                 WHEN COALESCE(source.metadata->'type_manually_set' = 'true'::jsonb,
                        'manual' = ANY(COALESCE(source.discovery_sources, ARRAY[]::text[])))
                      AND lower(COALESCE(NULLIF(btrim(source.type), ''), 'unknown')) <> 'unknown'
                      AND NOT (
                        COALESCE(survivor.metadata->'type_manually_set' = 'true'::jsonb,
                        'manual' = ANY(COALESCE(survivor.discovery_sources, ARRAY[]::text[])))
                        AND lower(COALESCE(NULLIF(btrim(survivor.type), ''), 'unknown')) <> 'unknown'
                      )
                   THEN source.type_id
                 ELSE survivor.type_id
               END,
               discovery_sources = ARRAY(
                 SELECT DISTINCT discovery_source
                 FROM unnest(
                   COALESCE(source.discovery_sources, ARRAY[]::text[]) ||
                   COALESCE(survivor.discovery_sources, ARRAY[]::text[])
                 ) AS discovery_source
                 WHERE discovery_source IS NOT NULL AND discovery_source <> ''
                 ORDER BY discovery_source
               ),
               -- How long the HOST has been known, not how long this row has
               -- existed. The survivor is frequently the newer row -- a census
               -- sighting of an address the reconciler later recognises as an
               -- already-known device -- and without this the merge discards
               -- the earlier date and the host reappears on "devices first seen
               -- in the last 30 days" months after it was actually found.
               --
               -- LEAST ignores NULLs (it is NULL only when every argument is),
               -- so a survivor or source with no recorded date takes the other
               -- one rather than poisoning the result.
               first_seen_time = LEAST(survivor.first_seen_time, source.first_seen_time),
               modified_time = timezone('UTC', now())
           FROM platform.ocsf_devices AS source
           WHERE source.uid = $1 AND survivor.uid = $2
           RETURNING survivor.uid
           """,
           [from_device_id, to_device_id]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :merge_device_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  # Unmerge already knows how to restore these fields when present. Record them
  # for every path instead of relying on individual callers to remember.
  defp merge_audit_details(details, from_device) do
    details
    |> Map.new()
    |> Map.put_new(:from_device_ip, from_device.ip)
    |> Map.put_new(:from_device_hostname, from_device.hostname)
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

  defp tombstone_merged_device(%Device{} = device, actor) do
    device
    |> Ash.Changeset.for_update(:soft_delete, %{
      deleted_reason: "merged",
      deleted_by: "identity_reconciler"
    })
    |> Ash.update(actor: actor)
  end

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

    # See do_merge_devices/5: must be transact, not transaction, or an unmerge
    # that fails partway commits a half-reversed merge.
    resources
    |> Ash.transact(fn ->
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
             ),
           # The to-device just gave identifiers back, so its identity
           # composition changed too. The from-device needs no bump here:
           # recreate_device/3 restores it through :restore, which carries one.
           #
           # Read inside the transaction rather than reusing an earlier struct --
           # reassign_original_identifiers/4 has already run, and the increment is
           # a database expression, so a stale struct would still be correct but a
           # missing row must fail the unmerge rather than silently skip a bump.
           {:ok, %Device{} = to_device} <- Device.get_by_uid(to_device_id, false, actor: actor),
           {:ok, _} <- Device.bump_identity_revision(to_device, actor: actor) do
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
    details = audit.details || %{}
    ip = details["from_device_ip"] || details[:from_device_ip]
    hostname = details["from_device_hostname"] || details[:from_device_hostname]

    # The merge soft-deleted the from-device, so its row still exists —
    # restore it in place instead of inserting a duplicate uid. The original
    # IP is only reclaimed when no live device holds it (the survivor
    # usually does; unique-active-IP would reject the restore otherwise).
    case Device.get_by_uid(from_device_id, true, actor: actor) do
      {:ok, %Device{deleted_at: %_{}}} ->
        # Atomic updates on tombstoned rows raise StaleRecord (the update
        # query is built from the primary read, which filters deleted rows);
        # bulk_update over an include_deleted query restores in place.
        restore_result =
          Device
          |> Ash.Query.for_read(:read, %{include_deleted: true})
          |> Ash.Query.filter(uid == ^from_device_id)
          |> Ash.bulk_update(:restore, %{},
            actor: actor,
            return_records?: true,
            return_errors?: true,
            strategy: [:atomic, :stream]
          )

        case restore_result do
          %Ash.BulkResult{status: :success, records: [restored | _]} ->
            restore_device_attributes(restored, ip, hostname, actor)

          %Ash.BulkResult{status: :success} ->
            Device.get_by_uid(from_device_id, false, actor: actor)

          %Ash.BulkResult{errors: errors} ->
            {:error, errors}
        end

      {:ok, %Device{} = live} ->
        {:ok, live}

      _ ->
        attrs = %{uid: from_device_id}
        attrs = if ip && ip_unclaimed?(ip, actor), do: Map.put(attrs, :ip, ip), else: attrs
        attrs = if hostname, do: Map.put(attrs, :hostname, hostname), else: attrs

        Device
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(actor: actor)
    end
  end

  defp restore_device_attributes(device, ip, hostname, actor) do
    attrs = %{}
    attrs = if ip && ip_unclaimed?(ip, actor), do: Map.put(attrs, :ip, ip), else: attrs
    attrs = if hostname, do: Map.put(attrs, :hostname, hostname), else: attrs

    if attrs == %{} do
      {:ok, device}
    else
      device
      |> Ash.Changeset.for_update(:update, attrs)
      |> Ash.update(actor: actor)
    end
  end

  defp ip_unclaimed?(ip, actor) do
    case Device.get_by_ip(ip, false, actor: actor) do
      {:ok, devices} when is_list(devices) -> devices == []
      {:ok, %Device{}} -> false
      _ -> true
    end
  rescue
    _ -> true
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
end
