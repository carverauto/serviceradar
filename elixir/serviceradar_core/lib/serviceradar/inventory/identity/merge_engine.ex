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
  alias ServiceRadar.Inventory.DistinctDeviceAssertion
  alias ServiceRadar.Inventory.Identity.AliasGuard
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Deduplication
  alias ServiceRadar.Inventory.Identity.EndpointInventoryMoves
  alias ServiceRadar.Inventory.Identity.MergePolicy
  alias ServiceRadar.Inventory.Identity.Reassignments
  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard
  alias ServiceRadar.Inventory.Identity.SourceSuccession
  alias ServiceRadar.Inventory.IdentityDecision
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
        {mergeable, randomized_only} =
          MergePolicy.split_randomized_mac_links(device_ids, matches, canonical_id)

        Enum.each(mergeable, fn from_id ->
          _ =
            merge_devices(from_id, canonical_id,
              actor: actor,
              reason: "identifier_conflict",
              details: details
            )
        end)

        if randomized_only != [] do
          MergePolicy.record_blocked_merge(
            "randomized_mac_link",
            [canonical_id | randomized_only],
            details.identifiers,
            "identifier_conflict"
          )
        end

      true ->
        blocked_reason = MergePolicy.blocked_merge_reason(matches)

        Logger.warning(
          "Blocked merge: shared identifiers are not eligible for auto-merge. " <>
            "Devices: #{inspect(device_ids)}, " <>
            "identifiers: #{inspect(details.identifiers)}"
        )

        MergePolicy.record_blocked_merge(
          blocked_reason,
          device_ids,
          details.identifiers,
          "identifier_conflict"
        )
    end
  end

  @succession_reason "source_succession"

  # A succession's metadata change (`SourceSuccession.metadata_patch/3`): remove the keys, then
  # put the values. The device rows are locked for the merge, so no write lands between the
  # read the change is computed from and this one.
  @succession_metadata_sql """
  UPDATE platform.ocsf_devices
  SET metadata = (COALESCE(metadata, CAST('{}' AS jsonb)) - CAST($2 AS text[])) || CAST($3 AS jsonb)
  WHERE uid = $1
  RETURNING uid
  """

  # Whether a live record of the partition other than the named ones holds the address.
  @address_held_sql """
  SELECT EXISTS (
    SELECT 1 FROM platform.ocsf_devices
    WHERE deleted_at IS NULL AND partition = $1 AND ip = $2 AND uid <> ALL (CAST($3 AS text[]))
  )
  """

  @set_address_sql """
  UPDATE platform.ocsf_devices SET ip = $2, modified_time = timezone('UTC', now())
  WHERE uid = $1 AND deleted_at IS NULL
  RETURNING uid
  """

  @doc """
  Merge a duplicate device into a canonical device and reassign related records.

  A source succession (`SourceSuccession`) passes reason `#{@succession_reason}` with
  `succession:`, the pair it merges; neither is accepted without the other.

  `fingerprint:` is the evidence fingerprint of the pair (`BlockFingerprint`). A guard block
  records it in its decision, so the next scheduled run can skip the pair while the evidence is
  unchanged (`block_decision_keys/2`).

  `on_merged:` is called with the merge's `MergeAudit` record as the last step of the merge
  transaction; a call that returns `{:error, _}` rolls the merge back. The remediation (design
  D11) writes its rollback manifest entry there, so that no merge commits unrecorded.
  """
  @spec merge_devices(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def merge_devices(from_device_id, to_device_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:device_merge))
    reason = Keyword.get(opts, :reason, "identity_resolution")
    details = Keyword.get(opts, :details, %{})
    succession = Keyword.get(opts, :succession)
    fingerprint = Keyword.get(opts, :fingerprint)
    on_merged = Keyword.get(opts, :on_merged, fn _merge -> :ok end)

    cond do
      from_device_id == to_device_id ->
        :ok

      error = succession_error(from_device_id, to_device_id, reason, succession) ->
        {:error, error}

      merge_guard_blocked =
          merge_guard_violation(from_device_id, to_device_id, reason, actor,
            succession: succession,
            fingerprint: fingerprint
          ) ->
        emit_merge_guard_telemetry(merge_guard_blocked, reason, from_device_id, to_device_id)

        record_guard_block(merge_guard_blocked, reason, {from_device_id, to_device_id}, details,
          fingerprint: fingerprint
        )

        Logger.info(
          "Blocked merge #{from_device_id} -> #{to_device_id} " <>
            "(reason: #{reason}, guard: #{merge_guard_blocked})"
        )

        {:error, {:merge_blocked, merge_guard_blocked}}

      true ->
        do_merge_devices(
          from_device_id,
          to_device_id,
          reason,
          details,
          succession,
          actor,
          on_merged
        )
    end
  end

  # A succession merges exactly its pair, and only a succession merges with its reason.
  defp succession_error(_from, _to, @succession_reason, nil), do: :succession_required
  defp succession_error(_from, _to, _reason, nil), do: nil

  defp succession_error(from, to, @succession_reason, %{
         identifier_type: type,
         partitions: [_ | _],
         predecessor: predecessor,
         successor: successor
       })
       when is_atom(type) do
    if Enum.sort([from, to]) == Enum.sort([predecessor, successor]),
      do: nil,
      else: :succession_mismatch
  end

  defp succession_error(_from, _to, @succession_reason, _succession), do: :succession_mismatch
  defp succession_error(_from, _to, _reason, _succession), do: :succession_reason_mismatch

  # Guards that apply to every automatic merge path (ingest-time, alias,
  # scheduled backfill). Manual/administrative merges bypass them.
  #
  # The scheduled run skips a pair these guards blocked while its evidence fingerprint is
  # unchanged (`BlockFingerprint`). A change to any guard here, or to what one reads, must bump
  # `BlockFingerprint`'s rule version, and the fingerprint must keep covering every input a guard
  # reads. The cooldown is the exception: it depends on time, so its blocks are never skipped.
  defp merge_guard_violation(from_device_id, to_device_id, reason, actor, opts) do
    succession = Keyword.get(opts, :succession)

    cond do
      manual_override_merge_reason?(reason) or reason == "unmerge" ->
        nil

      # An operator resolved a de-duplication task for this pair as "different devices" (#4604).
      Deduplication.asserted_distinct?(from_device_id, to_device_id) ->
        :asserted_distinct

      AliasGuard.distinct_agent_identity_conflict?(from_device_id, to_device_id, actor) ->
        :distinct_agent_identity

      source_conflict = source_conflict(from_device_id, to_device_id, succession) ->
        _ =
          SourceAuthorityGuard.record_blocked(source_conflict, reason, %{},
            fingerprint: Keyword.get(opts, :fingerprint)
          )

        :source_authority_conflict

      guard = provisional_topology_merge_violation(from_device_id, to_device_id, actor) ->
        guard

      recent_pair_merge?(from_device_id, to_device_id, actor) ->
        :merge_cooldown

      true ->
        nil
    end
  end

  defp source_conflict(from_device_id, to_device_id, nil),
    do: SourceAuthorityGuard.conflict_details([from_device_id, to_device_id])

  defp source_conflict(from_device_id, to_device_id, succession),
    do: SourceAuthorityGuard.succession_conflict([from_device_id, to_device_id], succession)

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
      {:ok, %Device{metadata: metadata}} -> provisional_topology_sighting?(metadata)
      _ -> false
    end
  rescue
    e ->
      Logger.warning(
        "Provisional-identity merge guard lookup failed for #{device_id}: #{inspect(e)}"
      )

      false
  end

  defp provisional_topology_sighting_device?(_device_id, _actor), do: false

  @doc """
  Whether a device's metadata marks it a provisional identity minted from mapper topology
  sightings, which the provisional-identity guard never lets absorb a corroborated device.
  """
  @spec provisional_topology_sighting?(term()) :: boolean()
  def provisional_topology_sighting?(%{} = metadata) do
    Map.get(metadata, "identity_state") == "provisional" and
      Map.get(metadata, "identity_source") == "mapper_topology_sighting"
  end

  def provisional_topology_sighting?(_metadata), do: false

  # Oscillation breaker: a pair that already merged (in either direction)
  # within the cooldown window is ping-ponging — re-merging would feed the
  # loop, so block and alert instead.
  defp recent_pair_merge?(device_a, device_b, actor) do
    window_seconds = merge_cooldown_seconds()
    cutoff = DateTime.shift(DateTime.utc_now(), second: -window_seconds)
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

  # Guards whose blocks a scheduled run may skip while the pair's evidence is unchanged: each
  # decides from the inputs `BlockFingerprint` covers. The cooldown is left out, because it
  # depends on time.
  @fingerprinted_guards [
    :asserted_distinct,
    :distinct_agent_identity,
    :source_authority_conflict,
    :provisional_identity_absorb,
    :distinct_mac_identity
  ]

  @doc """
  The keys of the decisions a guard block of `device_a` and `device_b` records, one for each
  guard whose block a scheduled run may skip (`BlockFingerprint`). The keys do not depend on
  the direction.
  """
  @spec block_decision_keys(String.t(), String.t()) :: [String.t()]
  def block_decision_keys(device_a, device_b) do
    Enum.map(@fingerprinted_guards, fn
      :source_authority_conflict ->
        IdentityDecision.decision_key(
          :source_block,
          "source_authority_conflict",
          [device_a, device_b],
          nil
        )

      guard ->
        IdentityDecision.decision_key(:guard_block, to_string(guard), [device_a, device_b], nil)
    end)
  end

  # The source-authority guard records its own decision (SourceAuthorityGuard.record_blocked/4,
  # a `:source_block` carrying both source id sets), so it is not recorded twice here.
  defp record_guard_block(:source_authority_conflict, _reason, _pair, _details, _opts), do: :ok

  defp record_guard_block(guard, reason, {from_device_id, to_device_id}, details, opts) do
    evidence = %{
      "merge_reason" => reason,
      "from_device_id" => from_device_id,
      "to_device_id" => to_device_id,
      "details" => details
    }

    evidence =
      case Keyword.get(opts, :fingerprint) do
        fingerprint when is_binary(fingerprint) and guard in @fingerprinted_guards ->
          Map.put(evidence, "fingerprint", fingerprint)

        _ ->
          evidence
      end

    DecisionLog.record(:guard_block, to_string(guard), [from_device_id, to_device_id],
      source: reason,
      evidence: evidence
    )
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

  defp do_merge_devices(
         from_device_id,
         to_device_id,
         reason,
         details,
         succession,
         actor,
         on_merged
       ) do
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
      with :ok <- lock_device_rows([from_device_id, to_device_id], actor),
           {:ok, %Device{} = from_device} <-
             Device.get_by_uid(from_device_id, false, actor: actor),
           {:ok, %Device{} = to_device} <- Device.get_by_uid(to_device_id, false, actor: actor),
           :ok <-
             from_device_id
             |> source_authority_transaction_guard(to_device_id, reason, succession, actor)
             |> transaction_refusal(),
           # Read before the reassignment moves them: these are the identifiers
           # an unmerge must give back, and nothing else records them.
           {:ok, source_identifiers} <- source_identifiers(from_device_id, actor),
           :ok <- preserve_survivor_attributes(from_device_id, to_device_id),
           {:ok, succession_details} <- succession_changes(succession, from_device, to_device),
           :ok <- Reassignments.reassign_device_identifiers(from_device_id, to_device_id, actor),
           # Returns the rows it moved, which an unmerge moves back.
           {:ok, archived_identifiers} <-
             Reassignments.reassign_archived_identifiers(from_device_id, to_device_id),
           audit_details =
             details
             |> merge_audit_details(from_device, source_identifiers, archived_identifiers)
             |> put_succession_details(succession_details),
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
           {:ok, merge} <-
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
           # After the tombstone, which frees the successor's address when it is the merged record.
           :ok <- take_successor_address(succession_details, to_device_id),
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
        on_merged.(merge)
      end
    end)
    |> case do
      {:ok, :ok} ->
        emit_merge_executed_telemetry(reason, from_device_id, to_device_id)
        :ok

      # The guard under the locks refused, before anything was written.
      {:ok, {:refused, error}} ->
        maybe_record_transaction_source_conflict(error, reason, details)
        emit_merge_failed_telemetry(reason, from_device_id, to_device_id, error)
        error

      # With transact a returned {:error, _} arrives here as an Ash error, having
      # rolled back. {:ok, other} is retained for a `with` clause that fails with
      # some other shape, which does NOT trigger a rollback.
      {:ok, other} ->
        emit_merge_failed_telemetry(reason, from_device_id, to_device_id, other)
        other

      {:error, _} = error ->
        emit_merge_failed_telemetry(reason, from_device_id, to_device_id, error)
        error
    end
  end

  # Both device rows, locked before anything else in the transaction and in uid
  # order. The fenced ingest write (Identity.Fence.fenced_write/3) locks its batch's
  # device rows the same way before touching their identifiers, so a merge or
  # unmerge and an ingest write on the same devices serialize on the device rows
  # instead of taking child-table row locks in opposite orders and deadlocking.
  # A tombstone is locked too (an unmerge restores one); a missing row locks
  # nothing, and the reads that follow report it.
  defp lock_device_rows(device_ids, actor) do
    device_ids = device_ids |> Enum.uniq() |> Enum.sort()

    Device
    |> Ash.Query.for_read(:read, %{include_deleted: true}, actor: actor)
    |> Ash.Query.filter(uid in ^device_ids)
    |> Ash.Query.select([:uid])
    |> Ash.Query.sort(uid: :asc)
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read(actor: actor)
    |> case do
      {:ok, _rows} -> :ok
      {:error, _} = error -> error
    end
  end

  # The guard's refusal under the locks, before the merge has written anything, is a value, and
  # the transaction commits nothing: an error returned through Ash.transact/3 arrives as an Ash
  # error, which would hide the reason (a source-authority conflict, a stale succession) from
  # the caller and from the blocked-merge record.
  defp transaction_refusal({:error, {tag, _detail}} = error)
       when tag in [:source_authority_conflict, :succession_stale],
       do: {:refused, error}

  defp transaction_refusal(result), do: result

  defp source_authority_transaction_guard(from_device_id, to_device_id, reason, nil, _actor) do
    if manual_override_merge_reason?(reason) or reason == "unmerge" do
      :ok
    else
      SourceAuthorityGuard.ensure_merge_allowed([from_device_id, to_device_id], lock: true)
    end
  end

  # A run's earlier merges can change a succession, so it is re-checked under the locks.
  defp source_authority_transaction_guard(
         from_device_id,
         to_device_id,
         _reason,
         succession,
         actor
       ) do
    with :ok <-
           SourceAuthorityGuard.ensure_succession_allowed(
             [from_device_id, to_device_id],
             succession,
             lock: true
           ) do
      SourceSuccession.revalidate(succession, actor)
    end
  end

  # The survivor takes the successor's source-owned metadata, the facts the source updated
  # last, and the successor's address (D3). Returns what the unmerge needs to give them back.
  defp succession_changes(nil, _from_device, _to_device), do: {:ok, nil}

  defp succession_changes(%{successor: successor}, from_device, to_device) do
    {side, successor_device, predecessor_device} =
      if to_device.uid == successor,
        do: {:survivor, to_device, from_device},
        else: {:merged, from_device, to_device}

    patch = SourceSuccession.metadata_patch(to_device.metadata, from_device.metadata, side)

    with {:ok, _result} <-
           Repo.query(@succession_metadata_sql, [to_device.uid, patch.remove, patch.put]),
         {:ok, take_address?} <- take_address?(successor_device, to_device) do
      {:ok,
       %{
         "survivor_before" => %{
           "ip" => to_device.ip,
           "source_owned" => SourceSuccession.source_owned(to_device.metadata)
         },
         "survivor_after" => %{
           "ip" => if(take_address?, do: successor_device.ip, else: to_device.ip),
           "source_owned" => SourceSuccession.source_owned(patch.put)
         },
         "ip_transferred" => take_address?,
         "predecessor_source_retired_at" =>
           predecessor_device.source_retired_at &&
             DateTime.to_iso8601(predecessor_device.source_retired_at)
       }}
    end
  end

  # The successor's address, when it holds one the survivor does not and no other live record
  # of the survivor's partition holds it.
  defp take_address?(%Device{uid: uid}, %Device{uid: uid}), do: {:ok, false}

  defp take_address?(%Device{ip: ip} = successor, %Device{} = survivor)
       when is_binary(ip) and ip != "" do
    if ip == survivor.ip do
      {:ok, false}
    else
      with {:ok, held?} <- address_held?(survivor.partition, ip, [successor.uid, survivor.uid]),
           do: {:ok, not held?}
    end
  end

  defp take_address?(_successor, _survivor), do: {:ok, false}

  defp address_held?(partition, ip, except) do
    case Repo.query(@address_held_sql, [partition, ip, except]) do
      {:ok, %{rows: [[held?]]}} -> {:ok, held?}
      {:error, _} = error -> error
    end
  end

  defp set_address(uid, ip) do
    case Repo.query(@set_address_sql, [uid, ip]) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _result} -> {:error, {:address_not_set, uid}}
      {:error, _} = error -> error
    end
  end

  defp take_successor_address(
         %{"ip_transferred" => true, "survivor_after" => %{"ip" => ip}},
         uid
       ),
       do: set_address(uid, ip)

  defp take_successor_address(_succession_details, _uid), do: :ok

  defp put_succession_details(details, nil), do: details
  defp put_succession_details(details, succession), do: Map.put(details, "succession", succession)

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
  #
  # `source_identifiers` is what the merged-away device itself owned when the
  # merge ran. It is written by the engine for every merge path and overwrites
  # anything a caller passed: it is the only record an unmerge may restore from
  # (see reassign_original_identifiers/4). A caller's own `identifiers` detail
  # is evidence for the merge decision and is left as the caller wrote it.
  #
  # `source_archived_identifiers` is the merged-away device's archived
  # identifiers, which the merge moved to the survivor; the unmerge moves back
  # exactly these (restore_archived_identifiers/3).
  defp merge_audit_details(details, from_device, source_identifiers, archived_identifiers) do
    details
    |> Map.new()
    |> Map.put_new(:from_device_ip, from_device.ip)
    |> Map.put_new(:from_device_hostname, from_device.hostname)
    |> Map.put(:source_identifiers, source_identifiers)
    |> Map.put(:source_archived_identifiers, archived_identifiers)
  end

  defp source_identifiers(device_id, actor) do
    DeviceIdentifier
    |> Ash.Query.for_read(:by_device, %{device_id: device_id})
    |> Ash.read(actor: actor)
    |> case do
      {:ok, identifiers} ->
        {:ok,
         identifiers
         |> Enum.map(fn identifier ->
           %{
             type: to_string(identifier.identifier_type),
             value: identifier.identifier_value,
             partition: identifier.partition
           }
         end)
         |> Enum.sort_by(&{&1.type, &1.value, &1.partition})}

      {:error, _} = error ->
        error
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

  `opts`: `:actor`; `:unmerged_by`, recorded in the unmerge audit entry (default `"admin"`);
  and `:event_id`, which reverses exactly that merge of the device instead of its latest one.
  With `:event_id` the unmerge is refused as `:already_unmerged` once the merge was reversed,
  as `:merge_superseded` when the device merged again since, and as `:not_merged` unless the
  device is still the merge's tombstone, so that a rollback replayed over a changed inventory
  does nothing.
  """
  @spec unmerge_device(String.t(), keyword()) :: :ok | {:error, term()}
  def unmerge_device(from_device_id, opts \\ []) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:device_unmerge))
    unmerge = %{unmerged_by: Keyword.get(opts, :unmerged_by, "admin"), require_merged: false}

    case Keyword.get(opts, :event_id) do
      nil ->
        # Find the merge audit entry for this from_device_id
        case MergeAudit.get_merged_to(from_device_id, actor: actor) do
          {:ok, [audit | _]} ->
            do_unmerge(from_device_id, audit.to_device_id, audit, actor, unmerge)

          {:ok, []} ->
            {:error, :no_merge_audit_found}

          {:error, _} = error ->
            error
        end

      event_id ->
        with {:ok, audit} <- merge_event(from_device_id, event_id, actor) do
          do_unmerge(from_device_id, audit.to_device_id, audit, actor, %{
            unmerge
            | require_merged: true
          })
        end
    end
  end

  defp merge_event(from_device_id, event_id, actor) do
    with {:ok, audits} <- MergeAudit.get_by_device(from_device_id, actor: actor) do
      case Enum.find(audits, &merge_of?(&1, from_device_id, event_id)) do
        nil ->
          {:error, :no_merge_audit_found}

        audit ->
          cond do
            Enum.any?(audits, &unmerge_of?(&1, event_id)) -> {:error, :already_unmerged}
            Enum.any?(audits, &later_merge?(&1, audit)) -> {:error, :merge_superseded}
            true -> {:ok, audit}
          end
      end
    end
  end

  defp merge_of?(%MergeAudit{} = audit, from_device_id, event_id) do
    audit.event_id == event_id and audit.from_device_id == from_device_id and
      audit.reason != "unmerge"
  end

  defp unmerge_of?(%MergeAudit{reason: "unmerge", details: %{} = details}, event_id),
    do: details["original_merge_event_id"] == event_id

  defp unmerge_of?(_audit, _event_id), do: false

  defp later_merge?(%MergeAudit{} = other, %MergeAudit{} = audit) do
    other.event_id != audit.event_id and other.from_device_id == audit.from_device_id and
      other.reason != "unmerge" and DateTime.compare(other.created_at, audit.created_at) != :lt
  end

  defp do_unmerge(from_device_id, to_device_id, audit, actor, unmerge) do
    resources = [Device, DeviceIdentifier, MergeAudit, DistinctDeviceAssertion]

    # See do_merge_devices/7: must be transact, not transaction, or an unmerge
    # that fails partway commits a half-reversed merge.
    resources
    |> Ash.transact(fn ->
      # Recreate the from-device
      with :ok <- lock_device_rows([from_device_id, to_device_id], actor),
           :ok <- check_merged(from_device_id, unmerge, actor),
           # Before the restore, which reclaims the merged record's address when it is free.
           :ok <- revert_succession(audit, to_device_id, actor),
           {:ok, _device} <- recreate_device(from_device_id, audit, actor),
           {:ok, restored} <-
             reassign_original_identifiers(from_device_id, to_device_id, audit, actor),
           {:ok, restored_archived} <-
             restore_archived_identifiers(from_device_id, to_device_id, audit),
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
                   unmerged_by: unmerge.unmerged_by,
                   restored_identifiers: Enum.sort_by(restored.restored, &{&1.type, &1.value}),
                   restored_identifiers_source: restored.provenance,
                   restored_archived_identifiers: restored_archived
                 }
               },
               actor: actor
             ),
           :ok <- assert_succession_distinct(audit, from_device_id, to_device_id),
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
      {:ok, {:refused, reason}} -> {:error, reason}
      {:ok, other} -> other
      {:error, _} = error -> error
    end
  end

  # Under the device locks: an unmerge of one named merge needs the device to be its tombstone
  # still. The refusal is a value, not an error: nothing has changed yet, and an error returned
  # through Ash.transact/3 arrives as an Ash error, which would hide the reason from the caller.
  defp check_merged(_from_device_id, %{require_merged: false}, _actor), do: :ok

  defp check_merged(from_device_id, %{require_merged: true}, actor) do
    case Device.get_by_uid(from_device_id, true, actor: actor) do
      {:ok, %Device{deleted_at: %_{}, deleted_reason: "merged"}} -> :ok
      {:error, _} = error -> error
      _other -> {:refused, :not_merged}
    end
  end

  # An unmerge of a succession gives the survivor back its address and source-owned metadata,
  # each only when the succession's value is still there; a later write wins. The facts and the
  # `source_retired` mark are not restored.
  defp revert_succession(
         %MergeAudit{reason: @succession_reason, details: %{"succession" => %{} = succession}},
         to_device_id,
         actor
       ) do
    with {:ok, %Device{} = survivor} <- Device.get_by_uid(to_device_id, false, actor: actor),
         :ok <- revert_address(survivor, succession) do
      revert_source_owned(survivor, succession)
    end
  end

  defp revert_succession(_audit, _to_device_id, _actor), do: :ok

  defp revert_address(%Device{} = survivor, %{
         "ip_transferred" => true,
         "survivor_before" => %{"ip" => before},
         "survivor_after" => %{"ip" => taken}
       }) do
    cond do
      survivor.ip != taken ->
        :ok

      is_binary(before) and before != "" ->
        with {:ok, held?} <- address_held?(survivor.partition, before, [survivor.uid]),
             do: set_address(survivor.uid, if(held?, do: nil, else: before))

      true ->
        set_address(survivor.uid, nil)
    end
  end

  defp revert_address(_survivor, _succession), do: :ok

  defp revert_source_owned(%Device{} = survivor, %{
         "survivor_before" => %{"source_owned" => before},
         "survivor_after" => %{"source_owned" => taken}
       }) do
    if SourceSuccession.source_owned(survivor.metadata) == taken do
      case Repo.query(@succession_metadata_sql, [
             survivor.uid,
             SourceSuccession.source_owned_keys(),
             before || %{}
           ]) do
        {:ok, _result} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  defp revert_source_owned(_survivor, _succession), do: :ok

  # So that the next run does not merge the pair again (D3).
  defp assert_succession_distinct(%MergeAudit{reason: @succession_reason} = audit, from, to) do
    case Deduplication.assert_distinct(
           from,
           to,
           "Unmerged source succession #{audit.event_id}",
           SystemActor.system(:device_unmerge)
         ) do
      {:ok, _assertion} -> :ok
      {:error, _} = error -> error
    end
  end

  defp assert_succession_distinct(_audit, _from, _to), do: :ok

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
        # bulk_update over an include_deleted query restores in place. An
        # unmerge is an administrative restore, so a retained tombstone is
        # restored too (Device.retained_reasons/0).
        restore_result =
          Device
          |> Ash.Query.for_read(:read, %{include_deleted: true})
          |> Ash.Query.filter(uid == ^from_device_id)
          |> Ash.bulk_update(:restore, %{allow_retained: true},
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

  # Give back exactly the identifiers the from-device owned when it was merged,
  # of those the survivor still holds. Never anything the survivor owned itself:
  # a merge moves only the source's identifiers, so only those may move back.
  #
  # Returns the provenance of the restored set so the unmerge audit row can say
  # how it was decided.
  defp reassign_original_identifiers(from_device_id, to_device_id, audit, actor) do
    {provenance, restore_keys} = identifiers_to_restore(from_device_id, audit)

    case DeviceIdentifier
         |> Ash.Query.for_read(:by_device, %{device_id: to_device_id})
         |> Ash.read(actor: actor) do
      {:ok, current_identifiers} ->
        current_identifiers
        |> Enum.filter(&restore_identifier?(&1, restore_keys))
        |> reassign_identifiers_to(from_device_id, actor)
        |> case do
          {:ok, restored} -> {:ok, %{provenance: provenance, restored: restored}}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp reassign_identifiers_to(identifiers, device_id, actor) do
    Enum.reduce_while(identifiers, {:ok, []}, fn identifier, {:ok, acc} ->
      identifier
      |> Ash.Changeset.for_update(:reassign_device, %{device_id: device_id})
      |> Ash.update(actor: actor)
      |> case do
        {:ok, _} ->
          {:cont,
           {:ok,
            [
              %{
                type: to_string(identifier.identifier_type),
                value: identifier.identifier_value,
                partition: identifier.partition
              }
              | acc
            ]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Give back exactly the archived identifiers the merge moved to the survivor
  # (`source_archived_identifiers`), of those still archived on it. The survivor's
  # own archive stays, and so does an identifier that returned to the live table
  # since. A merge recorded before archive rows moved with merges left them on the
  # merged-away device, so it records none and none move.
  defp restore_archived_identifiers(from_device_id, to_device_id, audit) do
    case archived_ids_to_restore(audit) do
      [] ->
        {:ok, []}

      ids ->
        case Repo.query(
               """
               UPDATE platform.device_identifier_archive
               SET device_id = $1
               WHERE device_id = $2 AND id = ANY($3::bigint[])
               RETURNING id, identifier_type, identifier_value, partition
               """,
               [from_device_id, to_device_id, ids]
             ) do
          {:ok, %{rows: rows}} -> {:ok, Reassignments.archived_identifiers(rows)}
          {:error, _} = error -> error
        end
    end
  end

  defp archived_ids_to_restore(audit) do
    case detail(audit.details || %{}, :source_archived_identifiers) do
      recorded when is_list(recorded) ->
        for %{} = entry <- recorded,
            id = detail(entry, :id),
            is_integer(id),
            uniq: true,
            do: id

      _ ->
        []
    end
  end

  # Which identifiers an unmerge restores, and how that was decided.
  #
  # "recorded": the merge recorded the source's own identifiers
  # (`source_identifiers`, written by every merge since this was introduced).
  #
  # Rows written before that carry no such record. The only older detail that
  # says who owned what is merge_conflicting_devices/4's `identifiers` list, whose
  # entries each name the device that held the match; the entries naming the
  # from-device are its own ("legacy_conflict_matches"). The same list's other
  # entries are the survivor's own identifiers and must never move. Every other
  # legacy shape (the registrar's map, and paths that recorded nothing) restores
  # nothing ("unrecorded"): an unmerge that leaves the source without its
  # identifiers is recoverable, one that strips the survivor is not.
  defp identifiers_to_restore(from_device_id, audit) do
    details = audit.details || %{}

    case detail(details, :source_identifiers) do
      recorded when is_list(recorded) ->
        {"recorded", identifier_keys(recorded)}

      _ ->
        legacy_source_identifiers(detail(details, :identifiers), from_device_id)
    end
  end

  defp legacy_source_identifiers(matches, from_device_id) when is_list(matches) do
    own =
      Enum.filter(matches, fn
        match when is_map(match) -> detail(match, :device_id) == from_device_id
        _ -> false
      end)

    {"legacy_conflict_matches", identifier_keys(own)}
  end

  defp legacy_source_identifiers(_matches, _from_device_id), do: {"unrecorded", MapSet.new()}

  defp identifier_keys(entries) do
    entries
    |> Enum.map(&identifier_key/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # {type, value, partition}; partition is nil for legacy entries, which never
  # recorded one, and then matches any partition.
  defp identifier_key(entry) when is_map(entry) do
    type = detail(entry, :type) || detail(entry, :identifier_type)
    value = detail(entry, :value) || detail(entry, :identifier_value)

    if is_nil(type) or is_nil(value) do
      nil
    else
      {to_string(type), value, detail(entry, :partition)}
    end
  end

  defp identifier_key(_entry), do: nil

  defp restore_identifier?(identifier, restore_keys) do
    type = to_string(identifier.identifier_type)
    value = identifier.identifier_value

    MapSet.member?(restore_keys, {type, value, identifier.partition}) or
      MapSet.member?(restore_keys, {type, value, nil})
  end

  # merge_audit.details is jsonb: string keys once read back, atom keys on a
  # struct built in this process.
  defp detail(map, key) when is_map(map), do: Map.get(map, to_string(key), Map.get(map, key))

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
