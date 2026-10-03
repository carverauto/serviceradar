defmodule ServiceRadar.Inventory.Identity.SourceRetirement do
  @moduledoc """
  Retires a source-authoritative identifier its source stopped reporting (change
  `add-source-id-succession`, design D1; requirement "Source Identifiers Retire On Sustained
  Absence").

  An identifier retires once it was absent from at least N consecutive exact, activated
  collections of the source instance that owns its scope, all under one collection query, and
  was last reported at least T ago (`source_retirement_absent_collections` and
  `source_retirement_min_absence_hours` in `ServiceRadar.Inventory.DeviceCleanupSettings`).
  Retiring moves the `device_identifiers` row to `device_identifier_archive`, with
  `archive_reason` `source_absent`, and records a `source_id_retired` identity decision naming
  the device, the identifier and the collections that proved the absence, in one transaction.
  The record's `integration_id` derived from the retired id
  (`ServiceRadar.Inventory.IntegrationIdentity.scoped_device_id/3`) moves with it: an
  integration id governs identity only through the typed id it accompanies, and one left behind
  would keep matching updates for the retired id.
  Once that commits, the record's retirement is emitted as `[:serviceradar, :inventory,
  :source_retirement, :retired]`, and a pass's counts as `[:serviceradar, :inventory,
  :source_retirement, :run]`. The record keeps the retired value as history:
  `SourceAuthorityGuard` still treats it as deciding the record's identity, so retirement never
  makes a record attachable to, or mergeable with, a record holding another value.

  A retirement that leaves the record retired-only marks it `source_retired` in the same
  transaction (design D5): `ocsf_devices.source_retired_at` is set, and the database mirrors it
  into `metadata.identity_state`. A record is retired-only when it holds no source-authoritative
  identifier of any type and no agent identifier, its last identity-bearing observation
  (`identity_observed_at`; none counts as old) is at least T old, and no operator created it
  (`discovery_sources` holds no `"manual"`). A marked record stays live: `Device :inventory` and
  the SRQL device queries hide it, the inventory counts leave it out, and
  `ServiceRadar.Inventory.SourceRetiredExpiry` soft-deletes it after
  `source_retired_grace_days` unless an identifier registered on it first clears the mark. Each
  `source_id_retired` decision records whether its retirement marked the record. Marking
  happens only here, when an id of the record's own retires: a record an operator restores is
  not marked again until another of its ids retires.

  Absence is counted when an exact collection activates (`record_collection/1`, inside the
  activation transaction). Each identifier of the instance's scope that a live record holds
  and the collection did not report gains one absence in
  `platform.source_identifier_absences`; one the collection reported loses its row; a
  collection under a different query restarts the count at 1. A collection that is not exact
  counts neither way.

  Retirement runs afterwards, in `ServiceRadar.Inventory.Identity.SourceRetirementWorker`,
  never during ingest. A source with no exact collections, and a scope that does not map to
  exactly one source instance (`SourceAuthorityGuard.collection_scope/2`), retire nothing.

  A pass that would retire ids from more than `source_retirement_max_fraction` of the
  instance's live records is refused: nothing is retired, and the refusal is logged at error
  level with the counts and emitted as `[:serviceradar, :inventory, :source_retirement,
  :refused]`. `source_retirement_guard_override` admits the next refused pass, and that pass
  clears it. The grace pass (`ServiceRadar.Inventory.SourceRetiredExpiry`) is bounded by the same
  fraction and admitted by the same override.
  """

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @archive_reason "source_absent"
  @decision_source "source_retirement"
  @operator_sources ["manual"]
  # Collection ids an absence row keeps as evidence: the largest N the settings allow.
  @max_collection_ids 32

  @reset_presence_sql """
  DELETE FROM platform.source_identifier_absences AS a
  USING platform.device_source_observations AS o
  WHERE a.partition = $1::text AND a.source = $2::text AND a.source_instance = $3::text
    AND o.partition = a.partition AND o.source = a.source
    AND o.source_instance = a.source_instance AND o.source_object_id = a.source_object_id
    AND o.collection_id = $4::text AND o.present
  """

  # One absence per in-scope identifier value a live record holds that the collection did not
  # report. The conflict clause skips a row this collection already counted, so counting is
  # idempotent per collection.
  @count_absences_sql """
  INSERT INTO platform.source_identifier_absences AS a
    (partition, source, source_instance, source_object_id, identifier_type, absent_count,
     query_hash, collection_ids, first_absent_at, last_absent_at, inserted_at, updated_at)
  SELECT DISTINCT $1::text, $2::text, $3::text, di.identifier_value, $5::text, 1, $7::text,
         ARRAY[$4::text], $8::timestamp, $8::timestamp, $9::timestamp, $9::timestamp
  FROM platform.device_identifiers AS di
  JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
  WHERE di.identifier_type = $5::text
    AND right(di.partition, char_length($6::text)) = $6::text
    AND NOT EXISTS (
      SELECT 1 FROM platform.device_source_observations AS o
      WHERE o.partition = $1::text AND o.source = $2::text AND o.source_instance = $3::text
        AND o.source_object_id = di.identifier_value
        AND o.collection_id = $4::text AND o.present
    )
  ON CONFLICT (partition, source, source_instance, source_object_id) DO UPDATE SET
    absent_count =
      CASE WHEN a.query_hash IS NOT DISTINCT FROM EXCLUDED.query_hash
        THEN a.absent_count + 1 ELSE 1 END,
    collection_ids =
      CASE WHEN a.query_hash IS NOT DISTINCT FROM EXCLUDED.query_hash
        THEN (a.collection_ids || EXCLUDED.collection_ids)
          [GREATEST(cardinality(a.collection_ids) + 2 - $10::integer, 1):]
        ELSE EXCLUDED.collection_ids END,
    first_absent_at =
      CASE WHEN a.query_hash IS NOT DISTINCT FROM EXCLUDED.query_hash
        THEN a.first_absent_at ELSE EXCLUDED.first_absent_at END,
    identifier_type = EXCLUDED.identifier_type,
    query_hash = EXCLUDED.query_hash,
    last_absent_at = EXCLUDED.last_absent_at,
    updated_at = EXCLUDED.updated_at
  WHERE NOT (EXCLUDED.collection_ids[1] = ANY (a.collection_ids))
  """

  # An absence row whose identifier no live record of the scope holds any more (merged away,
  # retired, deleted) proves nothing.
  @prune_absences_sql """
  DELETE FROM platform.source_identifier_absences AS a
  WHERE a.partition = $1::text AND a.source = $2::text AND a.source_instance = $3::text
    AND NOT EXISTS (
      SELECT 1 FROM platform.device_identifiers AS di
      JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
      WHERE di.identifier_type = a.identifier_type
        AND di.identifier_value = a.source_object_id
        AND right(di.partition, char_length($4::text)) = $4::text
    )
  """

  # The identifier rows the rule retires. "Last reported" is the later of the source
  # observation and the identifier's own last sighting, so a report on any ingest path, exact
  # or not, holds the id. Neither known means no proof, and NULL compares false.
  @candidates_sql """
  SELECT di.id, di.device_id, di.identifier_value, di.partition, a.absent_count,
         a.collection_ids, GREATEST(o.last_observed_at, di.last_seen)
  FROM platform.source_identifier_absences AS a
  JOIN platform.device_identifiers AS di
    ON di.identifier_type = a.identifier_type AND di.identifier_value = a.source_object_id
   AND right(di.partition, char_length($4::text)) = $4::text
  JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
  LEFT JOIN platform.device_source_observations AS o
    ON o.partition = a.partition AND o.source = a.source
   AND o.source_instance = a.source_instance AND o.source_object_id = a.source_object_id
  WHERE a.partition = $1::text AND a.source = $2::text AND a.source_instance = $3::text
    AND a.identifier_type = $5::text
    AND a.absent_count >= $6::integer
    AND a.query_hash IS NOT DISTINCT FROM $7::text
    AND GREATEST(o.last_observed_at, di.last_seen) <= $8::timestamp
    AND ($9::text[] IS NULL OR di.device_id = ANY ($9::text[]))
  ORDER BY di.device_id, di.id
  """

  @live_holders_sql """
  SELECT count(DISTINCT di.device_id)
  FROM platform.device_identifiers AS di
  JOIN platform.ocsf_devices AS d ON d.uid = di.device_id AND d.deleted_at IS NULL
  WHERE di.identifier_type = $1::text
    AND right(di.partition, char_length($2::text)) = $2::text
    AND ($3::text[] IS NULL OR di.device_id = ANY ($3::text[]))
  """

  # The candidate rule again, for one device, under the transaction's locks.
  @recheck_sql """
  SELECT di.id, di.device_id, di.identifier_value, di.partition, a.absent_count,
         a.collection_ids, GREATEST(o.last_observed_at, di.last_seen)
  FROM platform.device_identifiers AS di
  JOIN platform.source_identifier_absences AS a
    ON a.partition = $1::text AND a.source = $2::text AND a.source_instance = $3::text
   AND a.identifier_type = di.identifier_type AND a.source_object_id = di.identifier_value
  LEFT JOIN platform.device_source_observations AS o
    ON o.partition = a.partition AND o.source = a.source
   AND o.source_instance = a.source_instance AND o.source_object_id = a.source_object_id
  WHERE di.device_id = $4::text
    AND di.id = ANY ($5::bigint[])
    AND di.identifier_type = $6::text
    AND right(di.partition, char_length($7::text)) = $7::text
    AND a.absent_count >= $8::integer
    AND a.query_hash IS NOT DISTINCT FROM $9::text
    AND GREATEST(o.last_observed_at, di.last_seen) <= $10::timestamp
  ORDER BY di.id
  FOR UPDATE OF di, a
  """

  # The device's integration ids derived from the ids being retired, in the same scope.
  @accompanying_sql """
  SELECT di.id, di.identifier_value
  FROM platform.device_identifiers AS di
  WHERE di.device_id = $1::text AND di.identifier_type = 'integration_id'
    AND di.identifier_value = ANY ($2::text[])
    AND right(di.partition, char_length($3::text)) = $3::text
  ORDER BY di.id
  FOR UPDATE
  """

  @archive_sql """
  WITH moved AS (
    DELETE FROM platform.device_identifiers AS di
    WHERE di.device_id = $1::text AND di.id = ANY ($2::bigint[])
    RETURNING di.*
  )
  INSERT INTO platform.device_identifier_archive
    (id, device_id, identifier_type, identifier_value, partition, confidence, source,
     first_seen, last_seen, verified, metadata, archived_at, archive_reason)
  SELECT id, device_id, identifier_type::text, identifier_value,
         COALESCE(partition, 'default'), confidence::text, source,
         first_seen AT TIME ZONE 'UTC', last_seen AT TIME ZONE 'UTC',
         COALESCE(verified, false), COALESCE(metadata, '{}'::jsonb), $3::timestamptz, $4::text
  FROM moved
  ON CONFLICT (id) DO UPDATE SET
    device_id = EXCLUDED.device_id,
    identifier_type = EXCLUDED.identifier_type,
    identifier_value = EXCLUDED.identifier_value,
    partition = EXCLUDED.partition,
    confidence = EXCLUDED.confidence,
    source = EXCLUDED.source,
    first_seen = EXCLUDED.first_seen,
    last_seen = EXCLUDED.last_seen,
    verified = EXCLUDED.verified,
    metadata = EXCLUDED.metadata,
    archived_at = EXCLUDED.archived_at,
    archive_reason = EXCLUDED.archive_reason
  RETURNING id
  """

  # A retired value's absence row goes with it, unless another record of the scope still holds
  # the value and is still counting.
  @clear_absences_sql """
  DELETE FROM platform.source_identifier_absences AS a
  WHERE a.partition = $1::text AND a.source = $2::text AND a.source_instance = $3::text
    AND a.source_object_id = ANY ($4::text[])
    AND NOT EXISTS (
      SELECT 1 FROM platform.device_identifiers AS di
      WHERE di.identifier_type = a.identifier_type
        AND di.identifier_value = a.source_object_id
        AND right(di.partition, char_length($5::text)) = $5::text
    )
  """

  # Marks the record source_retired when the retirement leaves it retired-only (design D5): no
  # source-authoritative or agent identifier of any type left, no agent claiming it, no recent
  # identity-bearing observation, and not created by an operator.
  @mark_sql """
  UPDATE platform.ocsf_devices AS d
  SET source_retired_at = $2::timestamp
  WHERE d.uid = $1::text AND d.deleted_at IS NULL AND d.source_retired_at IS NULL
    AND NULLIF(btrim(COALESCE(d.agent_id, '')), '') IS NULL
    AND (d.identity_observed_at IS NULL OR d.identity_observed_at <= $3::timestamp)
    AND NOT (COALESCE(d.discovery_sources, ARRAY[]::text[]) && $4::text[])
    AND NOT EXISTS (
      SELECT 1 FROM platform.device_identifiers AS di
      WHERE di.device_id = d.uid AND di.identifier_type = ANY ($5::text[])
    )
  """

  @owner_lock_sql """
  SELECT pg_advisory_xact_lock(
           hashtextextended('serviceradar:armis-identifier-owner:' || $1::text, 0)
         )
  """

  @type instance :: %{partition: String.t(), source: String.t(), source_instance: String.t()}

  @doc """
  Counts the absences an exact collection proves. Called by
  `ServiceRadar.Inventory.DeviceSourceObservationIngestor` inside the activation transaction,
  after the collection's observations and snapshot are written and while the instance's
  advisory lock is held. Returns `:skipped` for a collection that is not exact or whose source
  has no retirement scope.
  """
  @spec record_collection(map()) ::
          {:ok, %{reset: non_neg_integer(), absent: non_neg_integer(), pruned: non_neg_integer()}}
          | :skipped
  def record_collection(snapshot) when is_map(snapshot) do
    with true <- exact_collection?(snapshot),
         {:ok, scope} <-
           SourceAuthorityGuard.collection_scope(snapshot.source, snapshot.source_instance) do
      {:ok, count_collection(snapshot, scope)}
    else
      _ -> :skipped
    end
  end

  @doc "Whether a collection's accounting is exact, so that it counts as presence and absence."
  @spec exact_collection?(map() | nil) :: boolean()
  def exact_collection?(%{metadata: %{"accounting_status" => "exact"}}), do: true
  def exact_collection?(_collection), do: false

  defp count_collection(snapshot, scope) do
    instance = [snapshot.partition, snapshot.source, snapshot.source_instance]

    %{num_rows: reset} =
      Repo.query!(@reset_presence_sql, instance ++ [snapshot.collection_id])

    %{num_rows: absent} =
      Repo.query!(
        @count_absences_sql,
        instance ++
          [
            snapshot.collection_id,
            Atom.to_string(scope.identifier_type),
            scope.partition_suffix,
            snapshot.query_hash,
            snapshot.observed_at,
            DateTime.utc_now(),
            @max_collection_ids
          ]
      )

    %{num_rows: pruned} = Repo.query!(@prune_absences_sql, instance ++ [scope.partition_suffix])

    %{reset: reset, absent: absent, pruned: pruned}
  end

  @doc """
  Runs one retirement pass for a source instance (`partition`, `source`, `source_instance`, as
  in `device_source_snapshots`).

  `opts`: `:settings` (required, the `DeviceCleanupSettings`), `:actor`, `:now`, and `:uids`,
  which limits the pass, and the live records the mass guard counts, to those devices.

  Returns `{:ok, stats}`, whose `:status` is `:completed`, `:disabled`, `:unscoped` or
  `:no_exact_collection`, or `{:error, {:mass_retirement_refused, counts}}`.
  """
  @spec run(instance(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%{partition: _, source: _, source_instance: _} = instance, opts) do
    settings = Keyword.fetch!(opts, :settings)

    with :ok <- ensure_enabled(settings),
         {:ok, ctx} <- context(instance, opts),
         candidates = candidates(ctx),
         :ok <- mass_retirement_guard(candidates, settings, ctx) do
      {:ok, retire_candidates(candidates, ctx)}
    else
      {:skip, status} -> {:ok, %{status: status}}
      {:error, _} = error -> error
    end
  end

  @doc """
  The context a retirement pass for a source instance runs under, whether or not retirement is
  enabled: the scope, the latest exact collection and its query hash, N, T, the cutoff T
  implies, and the devices the pass is limited to. Takes the options of `run/2`.

  Returns `{:skip, :unscoped}` for a source with no exact collections or a scope that does not
  map to exactly one source instance, and `{:skip, :no_exact_collection}` when the instance's
  latest activated collection is not exact.
  """
  @spec context(instance(), keyword()) :: {:ok, map()} | {:skip, atom()}
  def context(%{partition: _, source: source, source_instance: source_instance} = instance, opts) do
    settings = Keyword.fetch!(opts, :settings)

    with {:ok, scope} <- instance_scope(source, source_instance),
         {:ok, collection} <- latest_exact_collection(instance) do
      {:ok,
       %{
         instance: instance,
         scope: scope,
         collection: collection,
         query_hash: collection.query_hash,
         min_collections: settings.source_retirement_absent_collections,
         min_absence_hours: settings.source_retirement_min_absence_hours,
         cutoff:
           opts
           |> Keyword.get(:now, DateTime.utc_now())
           |> DateTime.add(-settings.source_retirement_min_absence_hours * 3_600, :second),
         uids: Keyword.get(opts, :uids),
         actor: Keyword.get(opts, :actor, SystemActor.system(:source_retirement))
       }}
    end
  end

  @doc """
  The identifier rows the retirement rule admits in a `context/2` now, before the mass guard,
  of the devices `uids` (`nil` for every device of the scope). The dry-run classifier
  (`ServiceRadar.Inventory.Remediation.SourceIdentityRepair`) reads the rule here, so it
  reports what a pass would retire.
  """
  @spec retirable(map(), [String.t()] | nil) :: [map()]
  def retirable(ctx, uids), do: candidates(%{ctx | uids: uids})

  defp ensure_enabled(%{source_retirement_enabled: true}), do: :ok
  defp ensure_enabled(_settings), do: {:skip, :disabled}

  defp instance_scope(source, source_instance) do
    case SourceAuthorityGuard.collection_scope(source, source_instance) do
      {:ok, scope} -> {:ok, scope}
      :error -> {:skip, :unscoped}
    end
  end

  # The newest activated collection decides which query the absences must have been counted
  # under. A source whose latest collection is not exact retires nothing.
  defp latest_exact_collection(instance) do
    from(snapshot in "device_source_snapshots",
      where:
        snapshot.partition == ^instance.partition and snapshot.source == ^instance.source and
          snapshot.source_instance == ^instance.source_instance,
      select: %{
        collection_id: snapshot.collection_id,
        content_hash: snapshot.content_hash,
        query_hash: snapshot.query_hash,
        observed_at: snapshot.observed_at,
        activated_at: snapshot.activated_at,
        metadata: snapshot.metadata
      }
    )
    |> Repo.one(prefix: "platform")
    |> case do
      nil ->
        {:skip, :no_exact_collection}

      collection ->
        if exact_collection?(collection),
          do: {:ok, collection},
          else: {:skip, :no_exact_collection}
    end
  end

  defp candidates(ctx) do
    instance = ctx.instance

    @candidates_sql
    |> Repo.query!([
      instance.partition,
      instance.source,
      instance.source_instance,
      ctx.scope.partition_suffix,
      Atom.to_string(ctx.scope.identifier_type),
      ctx.min_collections,
      ctx.query_hash,
      ctx.cutoff,
      ctx.uids
    ])
    |> candidate_rows()
  end

  defp candidate_rows(%{rows: rows}) do
    Enum.map(rows, fn [id, device_id, value, partition, absent_count, collection_ids, last] ->
      %{
        id: id,
        device_id: device_id,
        identifier_value: value,
        partition: partition,
        absent_count: absent_count,
        collection_ids: collection_ids,
        last_reported_at: last
      }
    end)
  end

  defp mass_retirement_guard(candidates, settings, ctx) do
    devices = candidates |> Enum.map(& &1.device_id) |> Enum.uniq() |> length()
    live = live_holders(ctx)
    max_fraction = settings.source_retirement_max_fraction

    case CanonicalRebuild.prune_guard_check(devices, live, max_fraction, false) do
      :allow ->
        :ok

      {:refuse, reason} ->
        if settings.source_retirement_guard_override == true and consume_guard_override() do
          Logger.warning(
            "SourceRetirement: #{describe(ctx.instance)} pass over the guard admitted by " <>
              "source_retirement_guard_override, now cleared: retiring ids from #{devices} " <>
              "of #{live} live records (max fraction #{max_fraction})"
          )

          :ok
        else
          refuse(reason, devices, live, max_fraction, ctx)
        end
    end
  end

  defp live_holders(ctx) do
    %{rows: [[count]]} =
      Repo.query!(@live_holders_sql, [
        Atom.to_string(ctx.scope.identifier_type),
        ctx.scope.partition_suffix,
        ctx.uids
      ])

    count
  end

  @doc """
  Clears `source_retirement_guard_override` and returns whether this call cleared it. The
  override admits one refused pass, a retirement pass or the grace pass, and clearing it is the
  admission: of two passes racing for one override, only the one whose update matched
  proceeds.
  """
  @spec consume_guard_override() :: boolean()
  def consume_guard_override do
    {count, _} =
      Repo.update_all(
        from(settings in "device_cleanup_settings",
          where: settings.key == "default" and settings.source_retirement_guard_override == true
        ),
        [set: [source_retirement_guard_override: false, updated_at: DateTime.utc_now()]],
        prefix: "platform"
      )

    count == 1
  end

  defp refuse(reason, devices, live, max_fraction, ctx) do
    instance = ctx.instance

    :telemetry.execute(
      [:serviceradar, :inventory, :source_retirement, :refused],
      %{candidates: devices, live_devices: live},
      %{
        reason: reason,
        max_fraction: max_fraction,
        source: instance.source,
        source_instance: instance.source_instance
      }
    )

    Logger.error(
      "SourceRetirement: #{describe(instance)} pass refused (#{reason}): would retire ids " <>
        "from #{devices} of #{live} live records in one pass (max fraction #{max_fraction}); " <>
        "set source_retirement_guard_override in the device cleanup settings to admit it"
    )

    {:error,
     {:mass_retirement_refused, %{candidates: devices, live: live, max_fraction: max_fraction}}}
  end

  defp retire_candidates(candidates, ctx) do
    results =
      candidates
      |> Enum.group_by(& &1.device_id)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {device_id, rows} -> {device_id, retire_device(device_id, rows, ctx)} end)

    retired = for {device_id, {:ok, %{} = retirement}} <- results, do: {device_id, retirement}
    skipped = Enum.count(results, &match?({_device_id, {:ok, :not_retirable}}, &1))
    failed = Enum.count(results, &match?({_device_id, {:error, _}}, &1))

    retired_ids =
      retired
      |> Enum.map(fn {_device_id, retirement} -> length(retirement.rows) end)
      |> Enum.sum()

    stats = %{
      status: :completed,
      candidates: length(candidates),
      retired: retired_ids,
      devices: length(retired),
      marked: Enum.count(retired, fn {_device_id, retirement} -> retirement.marked end),
      skipped: skipped,
      failed: failed
    }

    Enum.each(retired, &emit_retired(&1, ctx))
    emit(stats, ctx)
    log_retired(retired, ctx)
    stats
  end

  # One transaction per device: the instance lock orders the pass after any activation in
  # flight, the device row is locked before its identifiers (as the fenced ingest write and
  # `MergeEngine` do), and the rule is checked again under those locks, so an id reported, or
  # a device deleted, since the candidates were read is left alone. Returns the retired rows
  # and whether the record was marked, or :not_retirable.
  defp retire_device(device_id, rows, ctx) do
    Device
    |> Ash.transact(fn ->
      lock_instance(ctx.instance)

      with {:ok, device} <- lock_live_device(device_id, ctx.actor),
           :ok <- lock_identifier_owner(device_id),
           [_ | _] = rows <- recheck(device_id, rows, ctx) do
        archive(device_id, rows, device, ctx)
      else
        {:error, _} = error -> error
        _not_retirable -> {:ok, :not_retirable}
      end
    end)
    |> case do
      {:ok, {:ok, retired}} ->
        {:ok, retired}

      {:error, error} ->
        Logger.warning(
          "SourceRetirement: #{describe(ctx.instance)} could not retire ids of #{device_id}: " <>
            inspect(error)
        )

        {:error, error}
    end
  end

  defp lock_instance(instance) do
    key = Enum.join([instance.partition, instance.source, instance.source_instance], ":")
    _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
    :ok
  end

  defp lock_live_device(device_id, actor) do
    Device
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(uid == ^device_id)
    |> Ash.Query.select([:uid])
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read(actor: actor)
    |> Page.unwrap()
    |> case do
      {:ok, [_locked]} -> Device.get_by_uid(device_id, false, actor: actor)
      {:ok, []} -> :not_live
      {:error, _} = error -> error
    end
  end

  # The lock the `device_identifiers` ownership trigger takes for this device's writes, taken
  # before the recheck so a concurrent identifier write lands either wholly before it or after
  # the retirement commits.
  defp lock_identifier_owner(device_id) do
    _ = Repo.query!(@owner_lock_sql, [device_id])
    :ok
  end

  defp recheck(device_id, rows, ctx) do
    instance = ctx.instance

    @recheck_sql
    |> Repo.query!([
      instance.partition,
      instance.source,
      instance.source_instance,
      device_id,
      Enum.map(rows, & &1.id),
      Atom.to_string(ctx.scope.identifier_type),
      ctx.scope.partition_suffix,
      ctx.min_collections,
      ctx.query_hash,
      ctx.cutoff
    ])
    |> candidate_rows()
  end

  defp archive(device_id, rows, device, ctx) do
    instance = ctx.instance
    rows = accompany(device_id, rows, ctx)
    ids = Enum.flat_map(rows, fn row -> [row.id | Enum.map(row.accompanying, & &1.id)] end)

    %{num_rows: archived} =
      Repo.query!(@archive_sql, [device_id, ids, DateTime.utc_now(), @archive_reason])

    if archived == length(ids) do
      %{} =
        Repo.query!(@clear_absences_sql, [
          instance.partition,
          instance.source,
          instance.source_instance,
          Enum.map(rows, & &1.identifier_value),
          ctx.scope.partition_suffix
        ])

      with {:ok, _device} <- Device.bump_identity_revision(device, actor: ctx.actor),
           marked = mark(device_id, ctx),
           :ok <-
             DecisionLog.record_many_strict(Enum.map(rows, &retired_decision(&1, marked, ctx))) do
        {:ok, %{rows: rows, marked: marked}}
      end
    else
      {:error, {:archive_incomplete, archived, length(ids)}}
    end
  end

  # Runs after the archive, so the identifiers this retirement moved no longer count. The T of
  # the identity-bearing observation is the pass's own minimum absence.
  defp mark(device_id, ctx) do
    %{num_rows: marked} =
      Repo.query!(@mark_sql, [
        device_id,
        DateTime.utc_now(),
        ctx.cutoff,
        @operator_sources,
        Enum.map(marking_identifier_types(), &Atom.to_string/1)
      ])

    marked == 1
  end

  @doc """
  The identifier types whose presence keeps a record from being marked `source_retired`, and
  whose registration on a marked record clears the mark: the agent identifier and every
  source-authoritative type. The clearing trigger lists them too
  (`trg_device_identifiers_clear_source_retired`).
  """
  @spec marking_identifier_types() :: [atom()]
  def marking_identifier_types, do: [:agent_id | SourceAuthorityGuard.source_identifier_types()]

  # Each row gains the `integration_id` rows the device holds that were derived from its value.
  defp accompany(device_id, rows, ctx) do
    derived =
      Map.new(rows, fn row ->
        {derived_integration_id(row.identifier_value, ctx), row.identifier_value}
      end)

    %{rows: found} =
      Repo.query!(@accompanying_sql, [
        device_id,
        derived |> Map.keys() |> Enum.reject(&is_nil/1),
        ctx.scope.partition_suffix
      ])

    by_value =
      Enum.group_by(
        found,
        fn [_id, integration_id] -> Map.fetch!(derived, integration_id) end,
        fn [id, integration_id] -> %{id: id, identifier_value: integration_id} end
      )

    Enum.map(rows, &Map.put(&1, :accompanying, Map.get(by_value, &1.identifier_value, [])))
  end

  defp derived_integration_id(value, %{instance: instance}) do
    IntegrationIdentity.scoped_device_id(instance.source, instance.source_instance, value)
  end

  defp retired_decision(row, marked, ctx) do
    instance = ctx.instance

    %{
      kind: :source_id_retired,
      reason: @archive_reason,
      device_uids: [row.device_id],
      subject: row.identifier_value,
      source: @decision_source,
      evidence: %{
        "identifier_type" => Atom.to_string(ctx.scope.identifier_type),
        "identifier_value" => row.identifier_value,
        "identifier_partition" => row.partition,
        "archived_identifier_id" => row.id,
        "accompanying_identifiers" =>
          Enum.map(row.accompanying, fn accompanying ->
            %{
              "identifier_type" => "integration_id",
              "identifier_value" => accompanying.identifier_value,
              "archived_identifier_id" => accompanying.id
            }
          end),
        "source" => instance.source,
        "source_instance" => instance.source_instance,
        "collection_partition" => instance.partition,
        "absent_collections" => row.absent_count,
        "collection_ids" => row.collection_ids,
        "query_hash" => ctx.query_hash,
        "last_reported_at" => iso8601(row.last_reported_at),
        "min_absent_collections" => ctx.min_collections,
        "min_absence_hours" => ctx.min_absence_hours,
        "marked_source_retired" => marked
      }
    }
  end

  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil

  defp emit_retired({device_id, %{rows: rows, marked: marked}}, ctx) do
    :telemetry.execute(
      [:serviceradar, :inventory, :source_retirement, :retired],
      %{identifiers: length(rows)},
      %{
        device_uid: device_id,
        identifier_type: ctx.scope.identifier_type,
        identifier_values: Enum.map(rows, & &1.identifier_value),
        marked: marked,
        source: ctx.instance.source,
        source_instance: ctx.instance.source_instance
      }
    )
  end

  defp emit(stats, ctx) do
    :telemetry.execute(
      [:serviceradar, :inventory, :source_retirement, :run],
      Map.take(stats, [:candidates, :retired, :devices, :marked, :skipped, :failed]),
      %{source: ctx.instance.source, source_instance: ctx.instance.source_instance}
    )
  end

  defp log_retired([], _ctx), do: :ok

  defp log_retired(retired, ctx) do
    marked = for {device_id, %{marked: true}} <- retired, do: device_id

    Logger.info(
      "SourceRetirement: #{describe(ctx.instance)} retired #{ctx.scope.identifier_type} ids " <>
        "absent from #{ctx.min_collections}+ exact collections and unreported for " <>
        "#{ctx.min_absence_hours}h+ on #{length(retired)} record(s), marking " <>
        "#{length(marked)} source_retired: " <>
        inspect(Enum.take(Enum.map(retired, &elem(&1, 0)), 50)) <>
        if(marked == [], do: "", else: "; marked: " <> inspect(Enum.take(marked, 50)))
    )
  end

  defp describe(instance), do: "#{instance.source} instance #{instance.source_instance}"
end
