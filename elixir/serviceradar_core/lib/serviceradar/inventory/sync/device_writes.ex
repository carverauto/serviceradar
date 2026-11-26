defmodule ServiceRadar.Inventory.Sync.DeviceWrites do
  @moduledoc """
  Bulk device upserts with active-IP-conflict recovery and inventory
  rollup refresh.

  Known active-IP claims are resolved *before* the first `insert_all` so
  recurring integration syncs (for example AWX host inventory claiming an IP
  already held by an agent device) do not trip
  `ocsf_devices_unique_active_ip_idx` on every cycle. A reactive retry remains
  for true races with concurrent writers.
  """

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.NotificationQueue
  alias ServiceRadar.Inventory.Availability.LegacyWrites
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.Inventory.Identity.Address
  alias ServiceRadar.Inventory.Identity.DecisionLog
  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Identity.Resolver
  alias ServiceRadar.Inventory.Identity.SourceAuthorityGuard
  alias ServiceRadar.Inventory.SourceIdentityDrift
  alias ServiceRadar.Inventory.Sync.DeviceRecords
  alias ServiceRadar.Inventory.Sync.ParameterChunking
  alias ServiceRadar.Inventory.Sync.SourcePolicy
  alias ServiceRadar.Repo

  require Logger

  @inventory_rollup_refresh_lock_key 20_240_306
  # Above this many device records a write bypasses the statement-level rollup
  # triggers and rebuilds the rollups afterwards. The rebuild truncates the three
  # rollup tables and rescans every device, so its cost follows the inventory,
  # not the batch: about 0.25 s on an idle 88k-device table, and seconds behind
  # the refresh lock under load. The statement triggers read only the changed
  # rows (about 25-45 ms for a 131-device upsert on the same table) and match one
  # rebuild at roughly 10k changed rows. A batch of a few hundred devices, such as
  # one plugin result's discovery or Wi-Fi inventory, must not pay for a rebuild
  # inside its commit.
  @default_inventory_rollup_bulk_refresh_threshold 10_000
  # Concurrent cross-handoffs can deadlock on per-row release UPDATEs; retry a
  # few times after locking UIDs in a deterministic order.
  @deadlock_retries 3
  @identity_anchor_types [
    :agent_id,
    :armis_device_id,
    :integration_id,
    :netbox_device_id,
    :hardware_serial,
    :tls_certificate_fingerprint,
    :mac
  ]

  # Source-authoritative identifier types, one list shared with resolution and
  # merging (`SourceAuthorityGuard`). A record carrying one is a source's own
  # sighting, and a holder whose rows of them are all archived is retired
  # (`claim_address_from_holder/5`).
  @source_authoritative_types SourceAuthorityGuard.source_identifier_types()

  # Tombstones the upsert never writes to (device_upsert_update_query/1): a merged-away
  # device and a retained tombstone (`Device.retained_reasons/0`).
  @unrevivable_reasons ["merged" | Device.retained_reasons()]

  # The `^absent` and `^resighted` arrays and the `^cutoff` pinned into
  # device_upsert_update_query/1, bound once per use on top of the rows (ParameterChunking).
  @upsert_extra_parameters 10

  # An anchorless sweep seed that releases its only address to an identified
  # device (retire_released_seeds/1).
  @seed_released_reason "seed_released"
  @seed_released_by "system:seed_release"

  # DB connection's search_path determines the schema
  def bulk_upsert_devices(records, strong_uids \\ MapSet.new(), resolved_updates \\ nil) do
    case bulk_upsert_devices(records, strong_uids, resolved_updates, []) do
      {:ok, remap, _stale_uids} -> {:ok, remap}
      {:error, _} = error -> error
    end
  end

  @doc """
  `bulk_upsert_devices/3` for a fenced caller (`SyncIngestor`, inside
  `Identity.Fence.fenced_write/3`).

  With `lock_remap_targets: true`, every existing device the upsert redirects a
  record to -- an active-IP holder it adopts, or the survivor of a merged-away uid
  -- is locked `FOR NO KEY UPDATE` in uid order before anything is written to it and
  must still be live. The fence pins and locks only the uids the batch resolved; a
  redirect target is chosen later, inside the transaction, and without this a merge,
  delete or purge of it that committed after it was chosen would go unseen. A record
  whose target is gone, tombstoned or merged is withheld, and its resolved uid is
  returned in `stale_uids` so the caller treats it as a stale pin: re-resolve once,
  then abandon.

  Returns `{:ok, remap, stale_uids}`.
  """
  @spec bulk_upsert_devices([map()], MapSet.t(), list() | nil, keyword()) ::
          {:ok, %{String.t() => String.t()}, [String.t()]} | {:error, term()}
  def bulk_upsert_devices(records, strong_uids, resolved_updates, opts) do
    records = attach_identity_claims(records, resolved_updates)
    refresh_rollups? = inventory_rollup_bulk_refresh_required?(length(records))
    lock? = Keyword.get(opts, :lock_remap_targets, false)

    records
    |> do_bulk_upsert_devices(strong_uids, refresh_rollups?, lock?)
    |> follow_merged_away_uids(records, lock?)
  rescue
    e ->
      Logger.warning("Bulk device upsert failed: #{inspect(e)}")
      {:error, e}
  end

  defp do_bulk_upsert_devices(records, strong_uids, refresh_rollups?, lock?) do
    within_savepoint("device_writes_attempt", fn ->
      # Resolve predictable active-IP collisions up front so the first insert
      # succeeds. Reactive recovery below only covers concurrent writers that
      # land between this prepare step and insert_all.
      {prepared_records, remap, releases, stale_releases} =
        prepare_active_ip_claims(records, strong_uids, :precheck)

      # Test-only barrier point (Application env :device_writes_test_hooks).
      run_test_hook(:after_active_ip_precheck)

      {prepared_records, remap, stale_uids} =
        withhold_stale_remap_targets(prepared_records, remap, lock?)

      insert_devices_with_releases(
        prepared_records,
        releases,
        stale_releases,
        refresh_rollups?
      )

      {:ok, remap, stale_uids}
    end)
  rescue
    e in Postgrex.Error ->
      if ip_unique_conflict?(e) do
        recover_ip_conflict_and_retry(
          records,
          strong_uids,
          e,
          refresh_rollups?,
          lock?
        )
      else
        Logger.warning("Bulk device upsert failed: #{inspect(e)}")
        {:error, e}
      end
  end

  defp recover_ip_conflict_and_retry(
         records,
         strong_uids,
         original_error,
         refresh_rollups?,
         lock?
       ) do
    {recovered_records, remap, releases, stale_releases} =
      prepare_active_ip_claims(records, strong_uids, :retry)

    run_test_hook(:after_active_ip_precheck)

    {recovered_records, remap, stale_uids} =
      withhold_stale_remap_targets(recovered_records, remap, lock?)

    conflict_ip = unique_violation_ip(original_error)

    if map_size(remap) == 0 and not active_ip_claims_changed?(records, recovered_records) do
      Logger.warning(
        "Bulk device upsert hit active-IP conflict without an identity remap" <>
          "#{optional_ip_suffix(conflict_ip)}; retrying once after the concurrent insert: " <>
          "#{inspect(original_error)}"
      )
    else
      Logger.warning(
        "Bulk device upsert hit active-IP conflict after precheck" <>
          "#{optional_ip_suffix(conflict_ip)}; uid_remaps=#{map_size(remap)} " <>
          "records=#{length(records)}->#{length(recovered_records)} and retrying: " <>
          "#{inspect(original_error)}"
      )
    end

    case do_bulk_upsert_devices_once(
           recovered_records,
           releases,
           stale_releases,
           refresh_rollups?
         ) do
      :ok -> {:ok, remap, stale_uids}
      {:error, _} = error -> error
    end
  end

  # Lock every adopted active-IP holder in uid order and withhold the records
  # redirected to one that is no longer live (see bulk_upsert_devices/4). The
  # holders were live when prepare_active_ip_claims/3 read them; the lock is what
  # keeps a later transition from landing before this write commits.
  defp withhold_stale_remap_targets(records, remap, false), do: {records, remap, []}

  defp withhold_stale_remap_targets(records, remap, _lock?) when map_size(remap) == 0,
    do: {records, remap, []}

  defp withhold_stale_remap_targets(records, remap, true) do
    case remap |> Map.values() |> dead_targets() do
      [] ->
        {records, remap, []}

      dead ->
        dead = MapSet.new(dead)
        stale_uids = for {from, to} <- remap, MapSet.member?(dead, to), do: from

        Logger.warning(
          "SyncIngestor: withheld #{length(stale_uids)} write(s) whose adopted device " <>
            "is no longer live: #{inspect(Enum.sort(MapSet.to_list(dead)))}"
        )

        {Enum.reject(records, &MapSet.member?(dead, &1.uid)), Map.drop(remap, stale_uids),
         stale_uids}
    end
  end

  # The target uids that are missing or tombstoned (soft-deleted or merged), read
  # under FOR NO KEY UPDATE in uid order -- the order Identity.Fence and
  # MergeEngine lock device rows in.
  defp dead_targets(targets) do
    targets = targets |> Enum.uniq() |> Enum.sort()

    live =
      from(d in Device,
        where: d.uid in ^targets,
        order_by: [asc: d.uid],
        lock: "FOR NO KEY UPDATE",
        select: {d.uid, is_nil(d.deleted_at)}
      )
      |> Repo.all()
      |> Enum.filter(&elem(&1, 1))
      |> MapSet.new(&elem(&1, 0))

    Enum.reject(targets, &MapSet.member?(live, &1))
  end

  defp do_bulk_upsert_devices_once(records, releases, stale_releases, refresh_rollups?) do
    insert_devices_with_releases(
      records,
      releases,
      stale_releases,
      refresh_rollups?
    )

    :ok
  rescue
    error ->
      Logger.warning("Bulk device upsert retry failed: #{inspect(error)}")
      {:error, error}
  end

  # A uid merged into another device is never written back to life: the upsert's
  # on_conflict WHERE leaves its tombstone alone (device_upsert_update_query/1). What
  # the batch resolved for that uid -- identifiers, interfaces, aliases -- follows the
  # merge instead, through the same remap an active-IP recovery uses, so none of it
  # lands on the tombstone.
  #
  # BatchResolver already follows merge redirects, so a batch reaches a merged-away
  # uid only when a merge lands between resolution and this write. The check runs
  # after the upsert, so a merge that commits between the upsert and this read is
  # caught as well; the window left is the one between here and the dependent
  # writes, which the identity fence covers (#4618).
  defp follow_merged_away_uids({:ok, remap, stale_uids}, records, lock?) do
    stale = MapSet.new(stale_uids)

    landed =
      for %{uid: uid} <- records,
          not MapSet.member?(stale, uid),
          into: %{},
          do: {uid, Map.get(remap, uid, uid)}

    case landed |> Map.values() |> Enum.uniq() |> merged_away_uids() do
      [] ->
        {:ok, remap, stale_uids}

      merged ->
        actor = SystemActor.system(:device_writes)
        survivors = Map.new(merged, &{&1, Resolver.follow_canonical_device_id(&1, actor)})
        {survivors, dead_survivor_uids} = drop_dead_survivors(survivors, landed, lock?)

        Enum.each(survivors, fn
          {uid, uid} ->
            Logger.warning(
              "SyncIngestor: skipped a write to merged-away device #{uid}; " <>
                "no merge redirect found, so its resolved identifiers stay unmoved"
            )

          {uid, survivor} ->
            Logger.warning(
              "SyncIngestor: skipped a write to merged-away device #{uid}; " <>
                "following its merge into #{survivor}"
            )
        end)

        {:ok, Enum.reduce(landed, remap, &redirect_to_survivor(&1, &2, survivors)),
         stale_uids ++ dead_survivor_uids}
    end
  end

  defp follow_merged_away_uids(result, _records, _lock?), do: result

  # A fenced caller locks each survivor it will redirect to, like an adopted
  # active-IP holder; a survivor that is no longer live makes the writes that
  # would follow it stale instead.
  defp drop_dead_survivors(survivors, _landed, false), do: {survivors, []}

  defp drop_dead_survivors(survivors, landed, true) do
    targets = for {merged, survivor} <- survivors, survivor != merged, do: survivor

    case dead_targets(targets) do
      [] ->
        {survivors, []}

      dead ->
        dead = MapSet.new(dead)

        dead_merged =
          for {merged, survivor} <- survivors, MapSet.member?(dead, survivor), do: merged

        stale_uids = for {uid, landed_uid} <- landed, landed_uid in dead_merged, do: uid
        {Map.drop(survivors, dead_merged), stale_uids}
    end
  end

  defp redirect_to_survivor({uid, landed_uid}, remap, survivors) do
    case Map.get(survivors, landed_uid, landed_uid) do
      ^landed_uid -> remap
      survivor -> Map.put(remap, uid, survivor)
    end
  end

  defp merged_away_uids([]), do: []

  defp merged_away_uids(uids) do
    Repo.all(
      from(d in Device,
        where: d.uid in ^uids and not is_nil(d.deleted_at) and d.deleted_reason == "merged",
        select: d.uid
      )
    )
  end

  # When a batch moves device A off IP X while device B claims X, multi-row
  # INSERT ... ON CONFLICT can still trip the unique index depending on row
  # order. Clear the relinquished IPs first, then apply the final claims, in
  # one transaction so a failed upsert cannot leave owners IP-less.
  #
  # `releases` are the batch's own moves; `stale_releases` are the addresses a
  # strong-identified record takes from a stale holder
  # (`claim_address_from_holder/5`), whose released seeds retire in the same
  # transaction (`lock_and_clear_for_upsert/3`).
  defp insert_devices_with_releases(records, releases, stale_releases, refresh_rollups?) do
    with_deadlock_retry(fn ->
      within_savepoint("device_writes_upsert", fn ->
        do_insert_devices_with_releases(
          records,
          releases,
          stale_releases,
          refresh_rollups?
        )
      end)
    end)
  end

  defp within_savepoint(name, fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      Repo.query!("SAVEPOINT " <> name)

      try do
        result = fun.()
        Repo.query!("RELEASE SAVEPOINT " <> name)
        result
      rescue
        e in Postgrex.Error ->
          Repo.query!("ROLLBACK TO SAVEPOINT " <> name)
          Repo.query!("RELEASE SAVEPOINT " <> name)
          reraise e, __STACKTRACE__
      end
    else
      fun.()
    end
  end

  defp do_insert_devices_with_releases(records, [], [], refresh_rollups?) do
    insert_devices(records, refresh_rollups?)
  end

  defp do_insert_devices_with_releases(records, releases, stale_releases, true) do
    with_inventory_rollup_bypassed(fn ->
      lock_and_clear_for_upsert(records, releases, stale_releases)
      insert_devices(records, false)
    end)
  end

  defp do_insert_devices_with_releases(records, releases, stale_releases, false) do
    within_transaction(fn ->
      lock_and_clear_for_upsert(records, releases, stale_releases)
      insert_devices(records, false)
    end)
  end

  defp insert_devices(records, true) do
    with_inventory_rollup_bypassed(fn -> insert_devices(records, false) end)
  end

  # One statement per chunk, so a wide batch stays under the bound-parameter
  # limit without losing whole-batch atomicity.
  #
  # A record's non-nil is_available is the legacy value the sync path computed. The
  # column belongs to the merged resolver, so the records go in with is_available nil
  # (the upsert's COALESCE keeps the stored value) and the values go to the
  # compatibility table instead (LegacyWrites).
  defp insert_devices(records, false) do
    within_transaction(fn ->
      {records, legacy_values} = route_legacy_availability(records)

      records
      |> jsonb_safe()
      |> ParameterChunking.insert_all_chunks(extra_parameters: @upsert_extra_parameters)
      |> Enum.each(&insert_device_chunk/1)

      follow_kept_address_names(records)

      _written = LegacyWrites.record(legacy_values)
      :ok
    end)
  end

  # An address-fallback name (AttributeStrength tier 1: the write had no
  # hostname) names the device by the address it KEEPS, which only the upsert's
  # address guard decides -- a fallback built from an address the guard refused
  # would otherwise rename the device to it. So after the upsert, a recorded
  # fallback name that differs from the kept primary takes it, unless the kept
  # primary is link-local or absent (rank below a ULA's 30), in which case the
  # fallback is unset: a link-local never names a device.
  defp follow_kept_address_names([]), do: :ok

  defp follow_kept_address_names(records) do
    uids = records |> Enum.map(& &1.uid) |> Enum.uniq()

    Repo.query!(
      """
      UPDATE platform.ocsf_devices AS d
      SET name = CASE WHEN platform.sr_address_rank(d.ip) >= 30 THEN d.ip END,
          attribute_provenance =
            CASE WHEN platform.sr_address_rank(d.ip) >= 30 THEN d.attribute_provenance
                 ELSE d.attribute_provenance - 'name' END
      WHERE d.uid = ANY($1::text[])
        AND d.attribute_provenance -> 'name' ->> 'strength' = '1'
        AND d.name IS DISTINCT FROM d.ip
      """,
      [uids]
    )

    :ok
  end

  defp route_legacy_availability(records) do
    values =
      for %{uid: uid, is_available: available?} <- records,
          is_boolean(available?),
          do: {uid, available?}

    {Enum.map(records, &clear_availability/1), values}
  end

  defp clear_availability(%{is_available: _} = record), do: %{record | is_available: nil}
  defp clear_availability(record), do: record

  # A caller that already owns a transaction (the identity fence) gets the work
  # inline inside it; an unfenced caller (mapper discovery) gets a transaction
  # of its own.
  #
  # The already-in-transaction case MUST NOT open a nested Repo.transaction:
  # on this Ecto/DBConnection stack a nested transaction is a passthrough (no
  # savepoint) whose exception path calls DBConnection.fail/1, which marks the
  # connection failed client-side on the very errors the IP-conflict recovery
  # is designed to retry inside the same fence -- the recovery then sees
  # ConnectionError "transaction rolling back" instead of the server's
  # Postgrex.Error, the fenced-write retry classifier treats it as
  # non-transient, and a lost active-IP race kills the whole batch.
  #
  # A transaction opened here owns the notification queue, so the hints queued
  # inside it (`lock_and_clear_for_upsert/3`) are sent only once it commits.
  defp within_transaction(fun) when is_function(fun, 0) do
    if Repo.in_transaction?(),
      do: fun.(),
      else: NotificationQueue.with_queue(fn -> Repo.transaction(fun, timeout: :infinity) end)
  end

  # The stored primaries a chunk's records may replace at equal strength are read in
  # the write's transaction, right before the statement (primary_ip_inputs/1); the
  # upsert compares strengths against the row it updates.
  defp insert_device_chunk(chunk) do
    inputs = primary_ip_inputs(chunk)

    Repo.insert_all(
      Device,
      Enum.map(chunk, &insert_row/1),
      on_conflict: device_upsert_update_query(inputs),
      conflict_target: [:uid]
    )
  end

  # Converts :ip_seen_at only where the record carries it: adding the key would bind a
  # column per row that ParameterChunking did not count, and a missing key inserts NULL
  # just as nil does.
  defp insert_row(record) do
    record
    |> Map.delete(:ip_sightings)
    |> convert_ip_seen_at()
  end

  defp convert_ip_seen_at(%{ip_seen_at: seen_at} = record),
    do: %{record | ip_seen_at: usec(seen_at)}

  defp convert_ip_seen_at(record), do: record

  # Separates a device uid from its stored address in a primary-ip input key.
  @primary_key_separator <<31>>

  @doc """
  The equal-strength inputs to the primary-ip guard for `records`, from the stored rows.

  The upsert keeps a stored primary unless the incoming address is strictly stronger
  (`platform.sr_address_strength/1`), or the stored address is absent from the
  sightings of the source that recorded it (`ip_source`). Absence is decided here,
  never inferred in SQL from the incoming address differing:

    * the recording source reported the device in this write with a complete
      address set (`ip_sightings`, built by `DeviceRecords`) that no longer contains it; or
    * the recording source has not sighted it within the primary sighting window
      (`ip_seen_at`); a row with no recorded source has no sighting to keep it.

  An absence lets an address of the same class or a stronger one replace the stored
  primary (`Address.class_downgrade?/2`); a weaker class (a usable IPv4 to an IPv6,
  a routable address to a link-local) replaces it only once the stored address has
  also left the window. `cutoff` is the window's start, and the upsert applies the
  same class rule against the row it updates.

  A record whose recording source re-sighted the stored primary refreshes
  `ip_seen_at` (`resighted`). Another source's update never counts as absence.
  Keys are `uid <> <<31>> <> stored_ip`, so an input never applies to an address the
  row no longer holds.
  """
  @spec primary_ip_inputs([map()]) :: %{
          absent: [String.t()],
          resighted: [String.t()],
          cutoff: DateTime.t()
        }
  def primary_ip_inputs(records) do
    candidates =
      for %{uid: uid} = record <- records, present_ip?(Map.get(record, :ip)), do: {uid, record}

    stored = load_stored_primaries(Enum.map(candidates, &elem(&1, 0)))
    cutoff = DateTime.shift(DateTime.utc_now(), second: -primary_ip_sighting_window_seconds())

    Enum.reduce(candidates, %{absent: [], resighted: [], cutoff: cutoff}, fn {uid, record}, acc ->
      case Map.get(stored, uid) do
        %{ip: ip} = row when is_binary(ip) and ip != "" ->
          key = uid <> @primary_key_separator <> ip

          case stored_primary_sighting(row, Map.get(record, :ip_sightings) || %{}, record, cutoff) do
            :absent ->
              if class_held?(row, record.ip, cutoff),
                do: acc,
                else: %{acc | absent: [key | acc.absent]}

            :resighted ->
              %{acc | resighted: [key | acc.resighted]}

            :present ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  defp class_held?(%{ip: stored, ip_seen_at: seen_at}, incoming, cutoff),
    do: Address.class_downgrade?(incoming, stored) and not aged_out?(seen_at, cutoff)

  defp stored_primary_sighting(%{ip: ip, ip_source: nil}, sightings, record, _cutoff) do
    # No recorded source: the record's own source adopts the address when it sighted
    # it; otherwise nothing recorded keeps it.
    if sighted?(Map.get(sightings, Map.get(record, :ip_source)), ip),
      do: :resighted,
      else: :absent
  end

  defp stored_primary_sighting(%{ip: ip, ip_source: source} = row, sightings, _record, cutoff) do
    entry = Map.get(sightings, source)

    cond do
      sighted?(entry, ip) -> :resighted
      entry != nil and entry.complete? -> :absent
      aged_out?(row.ip_seen_at, cutoff) -> :absent
      true -> :present
    end
  end

  defp sighted?(%{addresses: addresses}, ip), do: MapSet.member?(addresses, ip)
  defp sighted?(_entry, _ip), do: false

  @doc """
  Whether a writer that sets one device's `ip` directly, outside the bulk upsert (an agent
  check-in, a camera inventory update, a mapper address move), replaces the stored primary
  with `incoming`.

  The same keep decision as the upsert: `incoming` replaces the stored primary when it is
  strictly stronger (`Address.better?/2`), or when the stored primary is absent from the
  sightings of the source that recorded it. A direct writer reports one address for the
  device, which is its whole view of it, so a stored primary it recorded (`source`) and
  one no source recorded are absent once it reports another; a primary another source
  recorded is absent only after that source has not sighted it for the window. Another
  source's equally strong address never displaces it, and an absence lets a weaker class
  (`Address.class_downgrade?/2`) replace the stored primary only once it has also left
  the window.
  """
  @spec direct_write_takes_primary?(Device.t(), String.t() | nil, String.t() | nil) :: boolean()
  def direct_write_takes_primary?(%Device{ip: stored} = device, incoming, source)
      when is_binary(incoming) do
    cond do
      not present_ip?(incoming) ->
        false

      not present_ip?(stored) ->
        true

      incoming == stored ->
        false

      Address.better?(incoming, stored) ->
        true

      Address.strength(incoming) == 0 ->
        false

      device.ip_source in [nil, source] and not Address.class_downgrade?(incoming, stored) ->
        true

      true ->
        primary_ip_aged_out?(device.ip_seen_at)
    end
  end

  def direct_write_takes_primary?(_device, _incoming, _source), do: false

  @doc """
  The primary-ip attributes a direct writer (`direct_write_takes_primary?/3`) sets on
  `device` when `source` reports it at `incoming`, sighted at `seen_at`: the address with
  its recording source and sighting time when it takes the primary, a refreshed
  `ip_seen_at` when `source` re-sighted the primary it recorded, otherwise nothing.
  """
  @spec direct_primary_ip_attrs(Device.t(), String.t() | nil, String.t(), DateTime.t()) :: map()
  def direct_primary_ip_attrs(%Device{} = device, incoming, source, seen_at)
      when is_binary(source) do
    cond do
      direct_write_takes_primary?(device, incoming, source) ->
        %{ip: incoming, ip_source: source, ip_seen_at: seen_at}

      is_binary(incoming) and incoming == device.ip and device.ip_source == source ->
        %{ip_seen_at: seen_at}

      true ->
        %{}
    end
  end

  @doc """
  True when a stored primary's recording source last sighted it (`seen_at`) longer ago
  than the primary sighting window, or never.
  """
  @spec primary_ip_aged_out?(DateTime.t() | NaiveDateTime.t() | nil) :: boolean()
  def primary_ip_aged_out?(seen_at) do
    aged_out?(
      seen_at,
      DateTime.shift(DateTime.utc_now(), second: -primary_ip_sighting_window_seconds())
    )
  end

  defp aged_out?(nil, _cutoff), do: true

  defp aged_out?(%NaiveDateTime{} = at, cutoff),
    do: aged_out?(DateTime.from_naive!(at, "Etc/UTC"), cutoff)

  defp aged_out?(%DateTime{} = at, cutoff), do: DateTime.before?(at, cutoff)

  defp load_stored_primaries([]), do: %{}

  defp load_stored_primaries(uids) do
    from(d in Device,
      where: d.uid in ^Enum.uniq(uids) and is_nil(d.deleted_at),
      select: {d.uid, %{ip: d.ip, ip_source: d.ip_source, ip_seen_at: d.ip_seen_at}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @default_primary_ip_sighting_window_seconds 86_400

  defp primary_ip_sighting_window_seconds do
    case Application.get_env(:serviceradar_core, :primary_ip_sighting_window_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_primary_ip_sighting_window_seconds
    end
  end

  defp present_ip?(ip) when is_binary(ip), do: String.trim(ip) != ""
  defp present_ip?(_ip), do: false

  # Last line of defence before anything reaches a jsonb column.
  #
  # A single unencodable byte anywhere in one device's metadata fails the ENTIRE
  # batch, not just that row -- insert_all is one statement, and the encode
  # happens while building it. That amplification is the actual damage: farm01
  # lost every sync batch (87 devices at a time) to one bad value, for hours.
  #
  # The known source was a raw 16-byte uuid: Postgrex returns `uuid` columns as
  # raw binaries, which satisfy is_binary/1 and therefore sail through code that
  # reasonably assumes a binary is text. That specific producer is fixed in
  # mac_vendor.ex, but it is one of many places a uuid can be read and stashed in
  # metadata, and this has now taken farm01 down twice. Fixing producers one at a
  # time treats instances; refusing to hand unencodable bytes to the writer
  # closes the class.
  #
  # Repair beats reject: a 16-byte binary is almost certainly a uuid, so it is
  # cast to its printable form and the value is preserved. Anything else
  # unencodable is dropped, because a device that lands with one missing metadata
  # key is strictly better than a batch that does not land at all. Both paths log
  # with the uid and key so the producer is still findable -- silently discarding
  # data here would trade an outage for a mystery.
  def jsonb_safe(records) when is_list(records) do
    Enum.map(records, &jsonb_safe_record/1)
  end

  defp jsonb_safe_record(%{metadata: metadata} = record) when is_map(metadata) do
    case sanitize_jsonb_map(metadata, record) do
      ^metadata -> record
      sanitized -> %{record | metadata: sanitized}
    end
  end

  defp jsonb_safe_record(record), do: record

  defp sanitize_jsonb_map(metadata, record) do
    Enum.reduce(metadata, metadata, fn {key, value}, acc ->
      case sanitize_jsonb_value(value) do
        :ok ->
          acc

        {:repaired, repaired} ->
          Logger.warning(
            "Repaired unencodable metadata value: uid=#{inspect(record[:uid])} key=#{inspect(key)} -> #{inspect(repaired)}"
          )

          Map.put(acc, key, repaired)

        :drop ->
          Logger.warning(
            "Dropped unencodable metadata value: uid=#{inspect(record[:uid])} key=#{inspect(key)} bytes=#{inspect(value, limit: 8)}"
          )

          Map.delete(acc, key)
      end
    end)
  end

  # Only binaries can carry bytes that are valid Erlang terms but invalid JSON
  # text; numbers, booleans, atoms and nil are always encodable. Nested maps and
  # lists are left alone deliberately -- metadata is flat in every writer here,
  # and walking arbitrary depth on every row of every batch is a cost paid on the
  # hot path to guard a shape that does not occur.
  defp sanitize_jsonb_value(value) when is_binary(value) do
    if String.valid?(value) do
      :ok
    else
      case Ecto.UUID.cast(value) do
        {:ok, uuid} -> {:repaired, uuid}
        :error -> :drop
      end
    end
  end

  defp sanitize_jsonb_value(_value), do: :ok

  # Lock the sorted union of release-owner UIDs *and* prepared-record UIDs that
  # already exist, then clear released (uid, ip) pairs set-wise. Locking only
  # release owners left a cross-lock cycle with insert_all's ON CONFLICT updates
  # of other prepared rows (PostgreSQL 40P01 under concurrent cross-handoffs).
  #
  # `stale_releases` are addresses a strong-identified record takes from a stale
  # holder. Their holders are locked and cleared with the rest, and a holder
  # that is an anchorless sweep seed is soft-deleted as `seed_released` in the
  # same transaction (`retire_released_seeds/1`), so a released seed is never
  # left live without an address. A batch's own moves (`releases`) never retire
  # anything: the holder is moving, not losing its address.
  @doc false
  def lock_and_clear_for_upsert(records, releases, stale_releases \\ [])

  def lock_and_clear_for_upsert(_records, [], []), do: :ok

  def lock_and_clear_for_upsert(records, releases, stale_releases) do
    stale_releases = Enum.uniq(stale_releases)

    releases =
      (releases ++ stale_releases)
      |> Enum.uniq()
      |> Enum.sort_by(fn {uid, ip} -> {uid, ip} end)

    lock_uids = upsert_lock_uids(records, releases)

    if lock_uids != [] do
      _locked =
        Repo.all(
          from(d in Device,
            where: d.uid in ^lock_uids and is_nil(d.deleted_at),
            select: d.uid,
            order_by: [asc: d.uid],
            lock: "FOR UPDATE"
          )
        )
    end

    # Read under the lock and before the clear: the seed still holds the
    # address it releases.
    seeds = released_seed_uids(records, stale_releases)

    {uids_col, ips_col} = Enum.unzip(releases)

    {_count, released} =
      Repo.update_all(
        from(d in Device,
          where:
            is_nil(d.deleted_at) and
              fragment(
                "(?, ?) IN (SELECT * FROM unnest(?::text[], ?::text[]))",
                d.uid,
                d.ip,
                ^uids_col,
                ^ips_col
              ),
          select: d.uid
        ),
        set: [ip: nil]
      )

    # A released holder, and so a retired seed, need not be among the records the caller
    # hints, and these raw updates send no notifications.
    NotificationQueue.after_commit(fn -> DevicePubSub.broadcast_invalidated(released) end)

    retire_released_seeds(seeds)
  end

  # D8: the holders among `stale_releases` that are anchorless sweep seeds, still
  # at the address they release. A seed qualifies only when the address is all
  # it is: it has no identifier row, current or archived (a retired id still
  # anchors a record); every discovery source it has is `sweep`; and no active
  # address alias names another address for it. A holder carrying anything more
  # releases the address and stays live. The claimants themselves (`records`)
  # are never retired.
  defp released_seed_uids(_records, []), do: []

  defp released_seed_uids(records, stale_releases) do
    record_uids = Enum.map(records, &Map.fetch!(&1, :uid))
    {uids_col, ips_col} = Enum.unzip(stale_releases)

    Repo.all(
      from(d in Device,
        where:
          is_nil(d.deleted_at) and d.uid not in ^record_uids and
            fragment(
              "(?, ?) IN (SELECT * FROM unnest(?::text[], ?::text[]))",
              d.uid,
              d.ip,
              ^uids_col,
              ^ips_col
            ) and
            fragment(
              """
              EXISTS (SELECT 1 FROM unnest(?) AS src WHERE lower(btrim(src)) = 'sweep')
              AND NOT EXISTS (
                SELECT 1 FROM unnest(?) AS src
                WHERE btrim(src) <> '' AND lower(btrim(src)) <> 'sweep'
              )
              AND NOT EXISTS (SELECT 1 FROM platform.device_identifiers i WHERE i.device_id = ?)
              AND NOT EXISTS (
                SELECT 1 FROM platform.device_identifier_archive a WHERE a.device_id = ?
              )
              AND NOT EXISTS (
                SELECT 1 FROM platform.device_alias_states s
                WHERE s.device_id = ?
                  AND s.alias_type IN ('ip', 'interface_ip')
                  AND s.state IN ('detected', 'confirmed', 'updated')
                  AND s.alias_value <> ?
              )
              """,
              d.discovery_sources,
              d.discovery_sources,
              d.uid,
              d.uid,
              d.uid,
              d.ip
            ),
        select: d.uid,
        order_by: [asc: d.uid]
      )
    )
  end

  # The seed is tombstoned rather than merged into the claimant: a seed is named
  # by its address, so redirecting its uid would make the address resolve to the
  # claimant for ever. `seed_released` is a retained tombstone
  # (`Device.retained_reasons/0`): no sweep or sync revives it, so the address
  # gets no new seed while it stays. The update mirrors `Device :soft_delete`,
  # identity revision included, as the clear above mirrors an address release.
  defp retire_released_seeds([]), do: :ok

  defp retire_released_seeds(uids) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        from(d in Device, where: d.uid in ^uids and is_nil(d.deleted_at)),
        set: [
          deleted_at: now,
          deleted_by: @seed_released_by,
          deleted_reason: @seed_released_reason,
          modified_time: DateTime.truncate(now, :second)
        ],
        inc: [identity_revision: 1]
      )

    Logger.info(
      "Active-IP release soft-deleted #{count} sweep seed(s) as " <>
        "#{@seed_released_reason}: #{inspect(uids)}"
    )

    :telemetry.execute(
      [:serviceradar, :inventory, :seed_released],
      %{count: count},
      %{deleted_reason: @seed_released_reason}
    )

    :ok
  end

  @doc false
  # Sorted unique UIDs that this upsert will touch via release clear and/or
  # ON CONFLICT updates. New (not-yet-inserted) UIDs are included in the set but
  # simply produce no FOR UPDATE rows.
  def upsert_lock_uids(records, releases) do
    release_uids = Enum.map(releases, &elem(&1, 0))
    record_uids = Enum.map(records, &Map.fetch!(&1, :uid))

    release_uids
    |> Kernel.++(record_uids)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def with_deadlock_retry(fun, attempts_left \\ @deadlock_retries)

  def with_deadlock_retry(fun, attempts_left) when attempts_left > 0 do
    fun.()
  rescue
    e in Postgrex.Error ->
      if deadlock_detected?(e) and attempts_left > 1 do
        Logger.warning(
          "Bulk device upsert hit deadlock while applying active-IP releases; " <>
            "retrying (#{attempts_left - 1} left): #{inspect(e)}"
        )

        # Brief jitter so concurrent cross-handoffs do not re-collide immediately.
        Process.sleep(10 + :rand.uniform(40))
        with_deadlock_retry(fun, attempts_left - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc false
  def deadlock_detected?(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    postgres[:code] == :deadlock_detected or postgres[:pg_code] == "40P01"
  end

  def deadlock_detected?(_), do: false

  # Optional test hooks via Application env:
  #   config :serviceradar_core, :device_writes_test_hooks, %{after_active_ip_precheck: fn -> ... end}
  # Production leaves this unset so the call is a no-op.
  defp run_test_hook(event) do
    case Application.get_env(:serviceradar_core, :device_writes_test_hooks) do
      %{^event => fun} when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  # Apply the same active-IP policy used by conflict recovery *before* insert so
  # recurring sync batches do not pay a unique_violation + retry every cycle.
  # Returns `{prepared_records, remap, releases, stale_releases}` where `remap`
  # is `original_uid => canonical_uid`, `releases` is a list of
  # `{owner_uid, ip}` pairs that this batch moves off an IP, and
  # `stale_releases` the `{holder_uid, ip}` pairs a strong-identified record
  # takes from a stale holder. Both are staged before insert so same-batch
  # handoffs are atomic.
  defp prepare_active_ip_claims(records, strong_uids, reason) do
    {remapped_records, remap, releases, stale_releases} =
      remap_records_to_existing_ip(records, strong_uids)

    prepared_records =
      remapped_records
      |> Enum.map(&Map.drop(&1, [:identity_claims, :observed_address]))
      |> DeviceRecords.merge_records_by_uid()

    if map_size(remap) > 0 or active_ip_claims_changed?(records, prepared_records) or
         releases != [] or stale_releases != [] do
      Logger.info(
        "SyncIngestor: #{active_ip_prepare_label(reason)} active-IP claims " <>
          "(uid_remaps=#{map_size(remap)}, " <>
          "releases=#{length(releases) + length(stale_releases)}, " <>
          "records=#{length(records)}->#{length(prepared_records)})"
      )
    end

    {prepared_records, remap, releases, stale_releases}
  end

  defp active_ip_prepare_label(:precheck), do: "pre-resolved"
  defp active_ip_prepare_label(:retry), do: "re-resolved"

  defp active_ip_claims_changed?(original, prepared) do
    original_claims =
      MapSet.new(original, fn record -> {record.uid, Map.get(record, :ip)} end)

    prepared_claims =
      MapSet.new(prepared, fn record -> {record.uid, Map.get(record, :ip)} end)

    original_claims != prepared_claims
  end

  defp unique_violation_ip(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    detail = postgres[:detail] || postgres["detail"] || ""

    case Regex.run(~r/Key \(ip\)=\(([^)]*)\)/, detail) do
      [_, ip] -> ip
      _ -> nil
    end
  end

  defp unique_violation_ip(_), do: nil

  defp optional_ip_suffix(nil), do: ""
  defp optional_ip_suffix(ip), do: " on #{ip}"

  # Returns `{remapped_records, remap, releases, stale_releases}` where `remap`
  # is a map of `original_uid => canonical_uid` for every record whose uid was
  # rewritten to match an existing active device sharing the same IP,
  # `releases` lists `{owner_uid, ip}` for owners that this batch moves onto a
  # different IP, and `stale_releases` lists `{holder_uid, ip}` for holders
  # that release an address to a strong-identified record
  # (`claim_address_from_holder/5`). Callers must apply the same mapping to any
  # other record set referencing those uids (identifier rows, alias-state
  # updates) before issuing dependent inserts.
  defp remap_records_to_existing_ip(records, strong_uids) do
    # Align blank-IP representation with the upsert SQL: whitespace-only becomes
    # an explicit clear (""), nil remains "omit / keep current".
    records = Enum.map(records, &normalize_record_ip/1)

    ips =
      records
      |> Enum.map(&Map.get(&1, :ip))
      |> Enum.filter(&SourcePolicy.valid_ip?/1)
      |> Enum.uniq()

    existing_by_ip = load_active_ip_owners(ips)
    batch_ip_by_uid = batch_intended_ips(records)

    # Owners that this batch vacates an IP (move to another valid address or
    # explicit blank clear) no longer hold it for conflict purposes — otherwise
    # a same-batch handoff would clear the claimant and leave the IP unowned.
    {active_holders, releases} =
      partition_holders_by_batch_release(existing_by_ip, batch_ip_by_uid)

    incoming_ip_owners = incoming_ip_owners(records)

    # The retired holders, and which colliding records already exist, with
    # their last identity-bearing observation, for the adoption and address
    # rules below. Loaded once per batch and only when a strong record actually
    # collides with a different holder; batches without such collisions pay no
    # extra query.
    colliding = Enum.filter(records, &strong_ip_collision?(&1, strong_uids, active_holders))

    identity_regs =
      if colliding == [] do
        %{retired: MapSet.new(), existing_uids: MapSet.new(), identity_times: %{}}
      else
        identity_times = load_identity_times(colliding)

        %{
          retired: load_retired_holders(existing_by_ip),
          existing_uids: identity_times |> Map.keys() |> MapSet.new(),
          identity_times: identity_times
        }
      end

    {remapped_records, {remap, conflicts, _anchors, stale_releases}} =
      Enum.map_reduce(records, {%{}, [], :not_loaded, []}, fn record, acc ->
        resolve_record_active_ip(
          record,
          strong_uids,
          active_holders,
          existing_by_ip,
          incoming_ip_owners,
          identity_regs,
          acc
        )
      end)

    # One batched diagnostic write instead of an insert per IP collision, and one batched write
    # of the matching identity decisions.
    conflicts = Enum.reverse(conflicts)
    _ = SourceIdentityDrift.record_conflicts(conflicts)
    _ = DecisionLog.record_many(Enum.map(conflicts, &active_ip_decision/1))

    {remapped_records, remap, Enum.uniq(releases), Enum.uniq(Enum.reverse(stale_releases))}
  end

  # Match the partial unique index predicate exactly so Postgres can use
  # ocsf_devices_unique_active_ip_idx (index-only) instead of a sequential scan.
  #
  # Keyed by {partition, ip}, NOT by ip alone. That index is
  # `UNIQUE (partition, ip)` since the isolation-partition migration, so an IP
  # may legally be held by one live device per partition. Keying this map on ip
  # alone made `Map.new/1` silently keep an arbitrary one of them, and the
  # conflict remapper below then released or re-pointed the wrong device's uid --
  # a monitoring sweep could take the isolation copy's row, or the reverse.
  defp load_active_ip_owners([]), do: %{}

  defp load_active_ip_owners(ips) do
    from(d in Device,
      where: d.ip in ^ips and is_nil(d.deleted_at) and not is_nil(d.ip) and d.ip != "",
      select:
        {{d.partition, d.ip},
         %{
           uid: d.uid,
           metadata: d.metadata,
           hostname: d.hostname,
           agent_id: d.agent_id,
           mac: d.mac,
           last_seen_time: d.last_seen_time,
           identity_observed_at: d.identity_observed_at,
           source_retired_at: d.source_retired_at
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  # The partition an incoming record claims. Mirrors `Ids.identifier_partition/2`
  # so the device row and its identifiers are scoped to the same partition.
  defp record_partition(record) do
    case Map.get(record, :partition) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> "default"
          trimmed -> trimmed
        end

      _ ->
        "default"
    end
  end

  defp record_ip_key(record), do: {record_partition(record), Map.get(record, :ip)}

  defp batch_intended_ips(records) do
    Map.new(records, fn record -> {record.uid, Map.get(record, :ip)} end)
  end

  # Explicit blank and nil are distinct under the upsert SQL:
  # - nil EXCLUDED.ip → keep current IP (omit)
  # - blank EXCLUDED.ip → write NULL (clear; vacates unique active-IP slot)
  # - other value → set that IP
  defp normalize_record_ip(record) do
    case Map.get(record, :ip) do
      ip when is_binary(ip) ->
        trimmed = String.trim(ip)
        Map.put(record, :ip, if(trimmed == "", do: "", else: trimmed))

      other ->
        Map.put(record, :ip, other)
    end
  end

  defp blank_ip?(ip) when is_binary(ip), do: String.trim(ip) == ""
  defp blank_ip?(_ip), do: false

  # True when the batch intended IP vacates `held_ip` under upsert SQL semantics.
  defp batch_releases_held_ip?(new_ip, held_ip) do
    cond do
      blank_ip?(new_ip) ->
        true

      SourcePolicy.valid_ip?(new_ip) and new_ip != held_ip ->
        true

      true ->
        false
    end
  end

  defp partition_holders_by_batch_release(existing_by_ip, batch_ip_by_uid) do
    Enum.reduce(existing_by_ip, {%{}, []}, fn {{_partition, ip} = key, holder},
                                              {keepers, releases} ->
      case Map.fetch(batch_ip_by_uid, holder.uid) do
        {:ok, new_ip} ->
          if batch_releases_held_ip?(new_ip, ip) do
            dest =
              if blank_ip?(new_ip) do
                "blank clear"
              else
                new_ip
              end

            Logger.info(
              "SyncIngestor: batch releases active IP #{ip} from device #{holder.uid} " <>
                "(moving to #{dest})"
            )

            {keepers, [{holder.uid, ip} | releases]}
          else
            # nil/omit keeps the current IP via the upsert CASE; same IP keeps
            # the holder. Either way the owner still claims the unique slot.
            {Map.put(keepers, key, holder), releases}
          end

        :error ->
          {Map.put(keepers, key, holder), releases}
      end
    end)
  end

  defp resolve_record_active_ip(
         record,
         strong_uids,
         active_holders,
         existing_by_ip,
         incoming_ip_owners,
         identity_regs,
         {remap, conflicts, anchors, stale_releases}
       ) do
    case Map.get(active_holders, record_ip_key(record)) do
      nil ->
        {resolved, {remap, conflicts}} =
          drop_batch_conflicting_ip(record, incoming_ip_owners, strong_uids, remap, conflicts)

        {resolved, {remap, conflicts, anchors, stale_releases}}

      %{uid: existing_uid} when existing_uid == record.uid ->
        {record, {remap, conflicts, anchors, stale_releases}}

      %{uid: existing_uid} = existing ->
        if MapSet.member?(strong_uids, record.uid) do
          # Defer identifier-anchor lookup until a strong identity actually
          # collides with a different active owner (provisional-seed path).
          {anchors, anchored_uids} = ensure_anchored_uids(anchors, existing_by_ip)

          if provisional_ip_seed?(existing, anchored_uids) and
               not MapSet.member?(identity_regs.existing_uids, record.uid) do
            {Map.put(record, :uid, existing_uid),
             {Map.put(remap, record.uid, existing_uid), conflicts, anchors, stale_releases}}
          else
            maybe_record_hostname_agreement(record, existing)

            claim_address_from_holder(
              record,
              existing,
              incoming_ip_owners,
              identity_regs,
              {remap, conflicts, anchors, stale_releases}
            )
          end
        else
          {Map.put(record, :uid, existing_uid),
           {Map.put(remap, record.uid, existing_uid), conflicts, anchors, stale_releases}}
        end
    end
  end

  # A strong-identified write at an address another live record still holds.
  # Strong identities never adopt an unrelated IP owner, and the decision is
  # recorded as an `active_ip_conflict` row either way.
  #
  # The address is evidence, not identity: it follows the device observed at
  # it. The incoming record takes the address, and the holder releases it (its
  # ip is cleared), in two cases:
  #
  #   1. the holder is retired and the incoming record carries a current
  #      source-authoritative identifier, whatever either record's observation
  #      times. A holder is retired when it is marked `source_retired`, or when
  #      its source-authoritative identifiers are all archived: the source has
  #      stopped reporting it, so it never keeps an address against a record the
  #      source still reports.
  #   2. the incoming record was observed at the address
  #      (`SourcePolicy.observed_address_source?/1`), and more recently than the
  #      holder by the newer-observation rule (`observed_after?/2`), which
  #      compares last identity-bearing observations (`identity_observed_at`). A
  #      sweep, a census sighting or an address-only sighting never advances
  #      one, so a sweep that keeps answering at a stale holder's address does
  #      not make the holder newer.
  #
  # Otherwise the incoming record drops the address. A declarative inventory's
  # address is configuration, not a sighting, so it displaces only a retired
  # holder.
  #
  # The release is staged as a stale release, so it is cleared in the same
  # transaction, before the insert that claims the address
  # (`lock_and_clear_for_upsert/3`), and ocsf_devices_unique_active_ip_idx
  # never sees both claims. A holder that is an anchorless sweep seed is
  # soft-deleted there as `seed_released`; any other holder stays live.
  #
  # When another record in this batch also claims the address (the holder's
  # own or a second incoming one), the observations contend for it and neither
  # is fresher; the incoming record drops it, as before, so the insert never
  # carries two rows at one address.
  defp claim_address_from_holder(
         record,
         %{uid: holder_uid} = holder,
         incoming_ip_owners,
         identity_regs,
         {remap, conflicts, anchors, stale_releases}
       ) do
    ip = Map.get(record, :ip)

    if takes_address?(record, holder, incoming_ip_owners, identity_regs) do
      Logger.info(
        "SyncIngestor: strong-identified device #{record.uid} takes active IP #{ip}; " <>
          "releasing it from stale holder #{holder_uid}"
      )

      conflict =
        SourceIdentityDrift.build_active_ip_conflict(record, holder_uid, ip,
          action: :release_holder
        )

      {record,
       {remap, prepend_conflict(conflicts, conflict), anchors,
        [{holder_uid, ip} | stale_releases]}}
    else
      Logger.info(
        "SyncIngestor: dropping conflicting IP #{ip} from strong-identified " <>
          "device #{record.uid} (held by #{holder_uid})"
      )

      conflict = SourceIdentityDrift.build_active_ip_conflict(record, holder_uid, ip)

      {Map.put(record, :ip, nil),
       {remap, prepend_conflict(conflicts, conflict), anchors, stale_releases}}
    end
  end

  defp takes_address?(record, holder, incoming_ip_owners, identity_regs) do
    cond do
      length(Map.get(incoming_ip_owners, record_ip_key(record), [])) > 1 ->
        false

      retired_holder?(holder, identity_regs) and
          source_authoritative?(record_identity_pairs(record, record_partition(record))) ->
        true

      Map.get(record, :observed_address) != true ->
        false

      true ->
        incoming_at =
          later(
            Map.get(record, :identity_observed_at),
            Map.get(identity_regs.identity_times, record.uid)
          )

        observed_after?(%{identity_observed_at: incoming_at}, holder)
    end
  end

  defp retired_holder?(%{uid: uid} = holder, identity_regs) do
    not is_nil(Map.get(holder, :source_retired_at)) or
      MapSet.member?(identity_regs.retired, uid)
  end

  @doc """
  The newer-observation rule: true when `incoming` was observed after
  `holder`, comparing each one's last identity-bearing observation
  (`identity_observed_at`).

  Only an observation that carries a strong identifier as the device's own
  report advances it: a source sync carrying a current source-authoritative
  identifier, an agent check-in, a discovery poll of the device itself. A
  sweep, a census sighting and an address-only sighting never do. A holder with
  no recorded observation counts as older than any incoming one; an incoming
  record with none never displaces a holder that has one.
  """
  @spec observed_after?(map(), map()) :: boolean()
  def observed_after?(incoming, holder) do
    case {Map.get(incoming, :identity_observed_at), Map.get(holder, :identity_observed_at)} do
      {_incoming_at, nil} -> true
      {%DateTime{} = incoming_at, %DateTime{} = held_at} -> DateTime.after?(incoming_at, held_at)
      _ -> false
    end
  end

  defp attach_identity_claims(records, nil), do: records

  defp attach_identity_claims(records, resolved_updates) do
    {claims, observed_at} =
      Enum.reduce(resolved_updates, {%{}, %{}}, fn {update, uid}, {claims, observed_at} ->
        ids = SourcePolicy.effective_identifiers(update)
        pairs = identity_pairs(ids, ids.partition)

        {Map.update(claims, uid, pairs, &Enum.uniq(&1 ++ pairs)),
         put_identity_observation(observed_at, uid, update, pairs)}
      end)

    # A record observed at its address (SourcePolicy.observed_address_source?/1)
    # may take that address from a stale holder.
    observed =
      for {update, uid} <- resolved_updates,
          SourcePolicy.observed_address_source?(update),
          into: MapSet.new(),
          do: uid

    Enum.map(records, fn record ->
      record
      |> Map.put(:identity_claims, Map.get(claims, record.uid, []))
      |> Map.put(:observed_address, MapSet.member?(observed, record.uid))
      |> put_identity_observed_at(observed_at)
    end)
  end

  # A source sync carrying a current source-authoritative identifier is an
  # identity-bearing observation (observed_after?/2), at the time the source
  # last saw the device. A sync with no time of its own observes at the
  # record's last_seen_time (put_identity_observed_at/2).
  defp put_identity_observation(observed_at, uid, update, pairs) do
    if source_authoritative?(pairs) do
      at = Map.get(update, :last_seen_time) || Map.get(update, :timestamp)
      Map.update(observed_at, uid, at, &later(&1, at))
    else
      observed_at
    end
  end

  # A record that already carries an observation (a discovery poll of the
  # device itself, MapperResultsIngestor) keeps the later of the two. The
  # upsert keeps the later of the record's and the stored value
  # (device_upsert_update_query/1).
  defp put_identity_observed_at(record, observed_at) do
    case Map.fetch(observed_at, record.uid) do
      {:ok, at} ->
        at = later(at || Map.get(record, :last_seen_time), Map.get(record, :identity_observed_at))
        Map.put(record, :identity_observed_at, usec(at))

      :error ->
        record
    end
  end

  defp later(nil, other), do: other
  defp later(at, nil), do: at
  defp later(at, other), do: if(DateTime.after?(other, at), do: other, else: at)

  # identity_observed_at is :utc_datetime_usec, which refuses a value without
  # microsecond precision; sync times arrive truncated to the second.
  defp usec(nil), do: nil
  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}

  # True when this record can take the strong-collision branch: it carries a
  # strong identity and its IP is held by a different active device. Mirrors
  # the branch condition so the registration lookup below is loaded exactly
  # when it will be consulted.
  defp strong_ip_collision?(record, strong_uids, active_holders) do
    MapSet.member?(strong_uids, Map.get(record, :uid)) and
      case Map.get(active_holders, record_ip_key(record)) do
        %{uid: holder_uid} -> holder_uid != Map.get(record, :uid)
        _ -> false
      end
  end

  # Anchor identifier claims on a record or holder map, extracted with the
  # same vocabulary registrations are written in (`Ids`). Values the
  # extractor rejects (integration compatibility echoes, placeholder serials,
  # unparseable MACs) never become claims, exactly as they never become rows.
  defp record_identity_pairs(%{identity_claims: claims}, _partition), do: claims

  defp record_identity_pairs(map, partition) do
    ids = map |> Map.put(:partition, partition) |> Ids.extract_strong_identifiers()
    identity_pairs(ids, ids.partition)
  end

  defp identity_pairs(ids, partition) do
    for type <- @identity_anchor_types,
        value <- Ids.get_identifier_values(type, ids),
        Ids.present_id?(value),
        do: {Atom.to_string(type), value, partition}
  end

  # Hostname agreement is not identity. A strong record that collides on an
  # address with a live holder whose hostname agrees is never adopted onto the
  # holder for it: it is written as its own device, and the address is decided
  # by `claim_address_from_holder/5` exactly as it would be if the names
  # differed. Many unrelated hosts share a name (lab nodes, cloned images,
  # default appliance names), so the pair is recorded as a `:policy_block`
  # decision, which opens a de-duplication task for an operator to merge, mark
  # distinct or dismiss, and the record never forks from the holder silently.
  # Either hostname blank is not agreement: two records that say nothing about
  # a name are merely silent.
  defp maybe_record_hostname_agreement(record, holder) do
    if hostnames_agree?(Map.get(record, :hostname), Map.get(holder, :hostname)) do
      record_hostname_agreement(record, holder)
    end

    :ok
  end

  # The colliding records whose uid already names a device row (live or
  # tombstoned), each with its stored identity_observed_at. Such a record is a
  # device, not a sighting looking for one, so it never adopts the holder of
  # its address; and the newer-observation rule (`observed_after?/2`) counts
  # its stored observation with the batch's own.
  defp load_identity_times(records) do
    uids = records |> Enum.map(& &1.uid) |> Enum.uniq()

    from(d in Device, where: d.uid in ^uids, select: {d.uid, d.identity_observed_at})
    |> Repo.all()
    |> Map.new()
  end

  defp source_authoritative?(pairs) do
    types = Enum.map(@source_authoritative_types, &Atom.to_string/1)
    Enum.any?(pairs, fn {type, _value, _partition} -> type in types end)
  end

  # The retired holders: those with archived source-authoritative identifier
  # rows and no live one. The holder map's metadata may not carry the
  # identifier the row does. The source has stopped reporting a retired holder,
  # so it yields its address to a record the source still reports
  # (`claim_address_from_holder/5`).
  defp load_retired_holders(existing_by_ip) do
    uids = existing_by_ip |> Map.values() |> Enum.map(& &1.uid) |> Enum.uniq()

    live =
      DeviceIdentifier
      |> where(
        [i],
        i.device_id in ^uids and i.identifier_type in ^@source_authoritative_types
      )
      |> select([i], i.device_id)
      |> distinct(true)
      |> Repo.all()
      |> MapSet.new()

    archived =
      uids
      |> archived_identifier_holders(@source_authoritative_types)
      |> MapSet.new()

    MapSet.difference(archived, live)
  end

  defp record_hostname_agreement(record, %{uid: holder_uid} = holder) do
    ip = Map.get(record, :ip)

    Logger.info(
      "SyncIngestor: device #{record.uid} agrees on hostname with active IP #{ip} holder " <>
        "#{holder_uid}; a hostname is not identity, recording a de-duplication decision"
    )

    :telemetry.execute(
      [:serviceradar, :identity_reconciler, :hostname_agreement, :refused],
      %{count: 1},
      %{incoming_device_uid: record.uid, existing_device_uid: holder_uid}
    )

    DecisionLog.record(:policy_block, "hostname_agreement_not_identity", [record.uid, holder_uid],
      subject: ip,
      source: "sync_ip_hostname_agreement",
      evidence: %{
        "incoming_device_uid" => record.uid,
        "existing_device_uid" => holder_uid,
        "hostname" => Map.get(holder, :hostname),
        "ip" => ip
      }
    )
  end

  defp hostnames_agree?(a, b) when is_binary(a) and is_binary(b) do
    a = String.trim(a)
    b = String.trim(b)
    a != "" and b != "" and String.downcase(a) == String.downcase(b)
  end

  defp hostnames_agree?(_, _), do: false

  defp ensure_anchored_uids(:not_loaded, existing_by_ip) do
    set = anchored_device_uids(existing_by_ip)
    {set, set}
  end

  defp ensure_anchored_uids(%MapSet{} = set, _existing_by_ip), do: {set, set}

  # Archived identifier rows anchor as live ones do. A record whose only source id
  # retired is not an anchorless seed: adopting it for a new record of another
  # device's id would make one record describe two devices.
  defp anchored_device_uids(existing_by_ip) do
    uids = existing_by_ip |> Map.values() |> Enum.map(& &1.uid) |> Enum.uniq()

    if uids == [] do
      MapSet.new()
    else
      live =
        DeviceIdentifier
        |> where([identifier], identifier.device_id in ^uids)
        |> where([identifier], identifier.identifier_type in ^@identity_anchor_types)
        |> select([identifier], identifier.device_id)
        |> Repo.all()

      MapSet.new(live ++ archived_identifier_holders(uids, @identity_anchor_types))
    end
  end

  # The devices among `uids` with an archived identifier row of one of `types`
  # (`platform.device_identifier_archive`, where a retired identifier moves).
  defp archived_identifier_holders(uids, types) do
    types = Enum.map(types, &Atom.to_string/1)

    Repo.all(
      from(archived in "device_identifier_archive",
        where: archived.device_id in ^uids and archived.identifier_type in ^types,
        select: archived.device_id,
        distinct: true
      ),
      prefix: "platform"
    )
  end

  # An unanchored holder is a provisional IP seed in two cases:
  #
  #   1. it DECLARES itself provisional (`identity_state`), which the registrar
  #      and the mapper IP-seed path both stamp. This is the original rule and
  #      is kept verbatim -- a declared seed is adoptable even when it carries a
  #      placeholder hostname, which is exactly what lets a mapper seed be
  #      enriched by the SNMP sweep that identifies it.
  #
  #   2. the IP is the ONLY thing known about it -- no hostname, no MAC -- and
  #      it does not claim to be canonical. This is the case that was missing:
  #      the manual and sweep creation paths never stamp `identity_state`, so
  #      such a row was treated as an established identity and won the
  #      unique-active-IP slot against a genuinely identified device. The loser
  #      was left with `ip: nil`, re-collided on the next sync, and the conflict
  #      was re-detected forever instead of converging.
  #
  # Case 2 is deliberately narrow. A hostname or MAC on the holder only keeps
  # it from being adopted here: it then keeps its own record, and the incoming
  # record takes the address under `claim_address_from_holder/5`. That prevents
  # a merge and never causes one, so it does not make a hostname identity
  # (requirement "Hostname Agreement Is Not Identity"). An IP alone is not
  # identity either, because IPs move; a hostname that agrees with an
  # established holder's is recorded for review only
  # (`maybe_record_hostname_agreement/2`).
  #
  # Adoption does not discard the seed. The incoming record takes the *existing*
  # uid, so an operator-added "something is at this IP" row survives and gains
  # the discovered identity, which is what lets importing and manual entry
  # coexist.
  #
  # Only a record that is not yet a device adopts a seed. An existing device
  # that moves onto a seeded address keeps its own record: remapping its write
  # onto the seed would leave its identifiers and its stale address behind on
  # the real record while the seed took its attributes, on every sync. It takes
  # the address under `claim_address_from_holder/5` instead, and the seed
  # releases it. A seed that is an anchorless sweep seed, with nothing but the
  # address, is soft-deleted as `seed_released` in the same transaction
  # (`lock_and_clear_for_upsert/3`); a seed that carries more stays live.
  defp provisional_ip_seed?(%{uid: uid} = holder, anchored_uids) do
    not MapSet.member?(anchored_uids, uid) and
      (declared_provisional?(holder) or
         (not canonical_identity?(holder) and ip_only_holder?(holder)))
  end

  defp declared_provisional?(%{metadata: metadata}) when is_map(metadata),
    do: metadata["identity_state"] == "provisional"

  defp declared_provisional?(_holder), do: false

  defp canonical_identity?(%{metadata: metadata}) when is_map(metadata),
    do: metadata["identity_state"] == "canonical"

  defp canonical_identity?(_holder), do: false

  defp ip_only_holder?(holder) do
    blank_attribute?(Map.get(holder, :hostname)) and blank_attribute?(Map.get(holder, :mac))
  end

  defp blank_attribute?(nil), do: true
  defp blank_attribute?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_attribute?(_value), do: false

  @doc """
  The live uid a new strong identity adopts at `ip` in `partition` when that
  holder is an eligible provisional seed, otherwise nil.

  Holder selection and eligibility are the active-IP remap in
  `bulk_upsert_devices/3`: one live owner per partition and address, anchors
  from live and archived identifier rows, and `provisional_ip_seed?/2`. An
  incoming uid that already names a device adopts nothing.
  """
  @spec adoptable_provisional_seed_uid(term(), term(), term()) :: String.t() | nil
  def adoptable_provisional_seed_uid(ip, partition, incoming_uid)
      when is_binary(ip) and ip != "" and is_binary(incoming_uid) do
    partition = record_partition(%{partition: partition})
    holders = load_active_ip_owners([ip])

    case Map.get(holders, {partition, ip}) do
      %{uid: holder_uid} = holder when holder_uid != incoming_uid ->
        if provisional_ip_seed?(holder, anchored_device_uids(holders)) and
             not Map.has_key?(load_identity_times([%{uid: incoming_uid}]), incoming_uid) do
          holder_uid
        end

      _ ->
        nil
    end
  end

  def adoptable_provisional_seed_uid(_ip, _partition, _incoming_uid), do: nil

  # A failed INSERT can be caused by two previously-unseen records in the same
  # bulk statement sharing an IP. There is no database owner to find in that
  # case, so the old recovery path retried the exact same conflict. Never pick
  # one source identity as the winner based on record order: remove the
  # contested IP from every distinct UID and retain their stronger identities.
  # Grouped by {partition, ip}: two records sharing an IP in DIFFERENT partitions
  # are not in conflict, they are the monitoring and isolation copies of one
  # address and both must survive the batch.
  defp incoming_ip_owners(records) do
    records
    |> Enum.filter(&SourcePolicy.valid_ip?(Map.get(&1, :ip)))
    |> Enum.group_by(&record_ip_key/1, &Map.fetch!(&1, :uid))
    |> Map.new(fn {key, uids} -> {key, Enum.uniq(uids)} end)
  end

  defp drop_batch_conflicting_ip(record, incoming_ip_owners, strong_uids, remap, conflicts) do
    ip = Map.get(record, :ip)
    conflicting_uids = Map.get(incoming_ip_owners, record_ip_key(record), [])

    if length(conflicting_uids) > 1 do
      conflicting_uid = Enum.find(conflicting_uids, &(&1 != record.uid))

      Logger.info(
        "SyncIngestor: dropping batch-conflicting IP #{ip} from device #{record.uid} " <>
          "(also claimed by #{conflicting_uid})"
      )

      conflict =
        if MapSet.member?(strong_uids, record.uid),
          do: SourceIdentityDrift.build_active_ip_conflict(record, conflicting_uid, ip)

      {Map.put(record, :ip, nil), {remap, prepend_conflict(conflicts, conflict)}}
    else
      {record, {remap, conflicts}}
    end
  end

  # A strong-identified record that did not take an address another device holds.
  defp active_ip_decision(conflict) do
    ids = conflict.conflicting_identifiers

    %{
      kind: :ip_conflict,
      reason: "active_ip_conflict",
      device_uids: [ids["incoming_device_uid"], ids["existing_device_uid"]],
      subject: conflict.current_ip,
      source: "sync_ingestor",
      evidence: %{
        "incoming_device_uid" => ids["incoming_device_uid"],
        "existing_device_uid" => ids["existing_device_uid"],
        "ip" => conflict.current_ip,
        "source_type" => conflict.source_type,
        "source_identifier_type" => ids["source_identifier_type"],
        "source_identifier_value" => ids["source_identifier_value"],
        "proposed_action" => conflict.proposed_action
      }
    }
  end

  defp prepend_conflict(conflicts, nil), do: conflicts
  defp prepend_conflict(conflicts, conflict), do: [conflict | conflicts]

  def maybe_refresh_inventory_rollups(:ok, total_count) when total_count > 0 do
    if inventory_rollup_bulk_refresh_required?(total_count) do
      refresh_inventory_rollups()
    else
      :ok
    end
  end

  def maybe_refresh_inventory_rollups(result, _total_count), do: result

  @doc false
  def inventory_rollup_bulk_refresh_required?(count) when is_integer(count) and count > 0 do
    count > inventory_rollup_bulk_refresh_threshold()
  end

  def inventory_rollup_bulk_refresh_required?(_count), do: false

  # SET LOCAL lasts until the enclosing transaction ends, so inside the fence
  # the bypass also covers the rest of the fenced write.
  defp with_inventory_rollup_bypassed(fun) when is_function(fun, 0) do
    within_transaction(fn ->
      Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")
      fun.()
    end)
  end

  @doc """
  Rebuilds the inventory rollup counters from the device table, under the rollup
  refresh lock. Returns `:ok` or `{:error, reason}`.
  """
  @spec refresh_inventory_rollups() :: :ok | {:error, term()}
  def refresh_inventory_rollups do
    if inventory_rollups_supported?(), do: run_inventory_rollup_refresh(), else: :ok
  end

  defp run_inventory_rollup_refresh do
    case Repo.transaction(&refresh_inventory_rollups_in_transaction/0, timeout: :infinity) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("SyncIngestor: Failed to refresh inventory rollups: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp refresh_inventory_rollups_in_transaction do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@inventory_rollup_refresh_lock_key])
    Repo.query!("SELECT platform.refresh_device_inventory_rollups()")
  end

  defp inventory_rollups_supported? do
    case Repo.query(
           "SELECT to_regprocedure('platform.refresh_device_inventory_rollups()') IS NOT NULL",
           []
         ) do
      {:ok, %{rows: [[true]]}} ->
        :ok
        true

      _ ->
        false
    end
  end

  defp inventory_rollup_bulk_refresh_threshold do
    :serviceradar_core
    |> Application.get_env(
      :inventory_rollup_bulk_refresh_threshold,
      @default_inventory_rollup_bulk_refresh_threshold
    )
    |> parse_nonnegative_integer(@default_inventory_rollup_bulk_refresh_threshold)
  end

  defp parse_nonnegative_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp parse_nonnegative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_nonnegative_integer(_value, default), do: default

  defp ip_unique_conflict?(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    postgres[:code] == :unique_violation and
      postgres[:constraint] == "ocsf_devices_unique_active_ip_idx"
  end

  defp ip_unique_conflict?(_), do: false

  # The WHERE keeps a merged-away device's tombstone: a conflicting insert for it
  # updates nothing (follow_merged_away_uids/3 then redirects the batch's dependent
  # writes to the survivor). It keeps a retained tombstone (`Device.retained_reasons/0`)
  # the same way: a sync reaching one is evidence, and evidence never revives it. The
  # fenced sync path withholds those updates before writing (SyncIngestor); this is the
  # backstop. Any other tombstone the upsert reaches is revived, and a revival is an
  # identity transition -- the uid names a live thing again -- so it bumps
  # identity_revision exactly as Device :restore does. The
  # trg_ocsf_devices_revival_audit trigger records the tombstone the revival clears.
  defp device_upsert_update_query(%{absent: absent, resighted: resighted, cutoff: cutoff}) do
    from(d in Device,
      where:
        is_nil(d.deleted_at) or is_nil(d.deleted_reason) or
          d.deleted_reason not in @unrevivable_reasons,
      update: [
        set: [
          # nil EXCLUDED.ip = omit (keep current). Blank EXCLUDED.ip = explicit
          # clear to NULL (vacates ocsf_devices_unique_active_ip_idx). A bare
          # COALESCE would treat '' as present and store empty strings, which
          # diverged from the release classifier and broke blank-IP handoffs.
          #
          # The stored primary is KEPT unless the incoming address is strictly
          # stronger (platform.sr_address_strength: a usable IPv4 beats any IPv6,
          # a routable address of either family beats a link-local of either
          # family, otherwise the higher rank within the family wins), or the
          # stored address is absent from the sightings of the source that
          # recorded it (`absent`, decided by primary_ip_inputs/1 before the
          # write; never inferred here from EXCLUDED.ip differing). An absence
          # takes an address of a weaker class (strength / 100) only once the
          # stored address has also left the sighting window (`cutoff`).
          #
          # Comparing ranks alone tied a global IPv6 (50) with a private IPv4
          # (40), so the last writer won and a dual-stack device's primary
          # flipped between families on every census pass. An equal-strength
          # address replacing on arrival let two addresses of one device take
          # turns. A real re-IP still lands: the old address leaves its
          # recording source's sightings.
          #
          # A link-local-only device keeps its link-local: nothing stronger
          # arrives, and an equal-strength link-local (fe80:: vs 169.254/16)
          # does not swap.
          #
          # A revival takes only the address the incoming record carries, ahead of
          # both rules above. A tombstone's stored address is history that another
          # live device may hold by now (the active-IP precheck drops a contested
          # address to nil), and keeping it would put two live rows on one address
          # and fail the whole batch on ocsf_devices_unique_active_ip_idx.
          ip:
            fragment(
              """
              CASE
                WHEN ? IS NOT NULL THEN
                  CASE WHEN btrim(EXCLUDED.ip) = '' THEN NULL ELSE EXCLUDED.ip END
                WHEN EXCLUDED.ip IS NULL THEN ?
                WHEN btrim(EXCLUDED.ip) = '' THEN NULL
                WHEN ? IS NULL THEN EXCLUDED.ip
                WHEN platform.sr_address_strength(EXCLUDED.ip) > platform.sr_address_strength(?)
                  THEN EXCLUDED.ip
                WHEN (? || chr(31) || ?) = ANY(?::text[])
                     AND platform.sr_address_strength(EXCLUDED.ip) > 0
                     AND (platform.sr_address_strength(EXCLUDED.ip) / 100 >=
                            platform.sr_address_strength(?) / 100
                          OR ? IS NULL OR ? < ?)
                  THEN EXCLUDED.ip
                ELSE ?
              END
              """,
              d.deleted_at,
              d.ip,
              d.ip,
              d.ip,
              d.uid,
              d.ip,
              ^absent,
              d.ip,
              d.ip_seen_at,
              d.ip_seen_at,
              type(^cutoff, :utc_datetime_usec),
              d.ip
            ),
          # The source that recorded the primary, and when it last sighted it.
          # Both follow the ip expression above branch for branch; a stored
          # primary its recording source re-sighted (`resighted`) refreshes the
          # sighting time, and a row with no recorded source adopts the source
          # that re-sighted it.
          ip_source:
            fragment(
              """
              CASE
                WHEN ? IS NOT NULL THEN
                  CASE WHEN NULLIF(btrim(EXCLUDED.ip), '') IS NULL THEN NULL ELSE EXCLUDED.ip_source END
                WHEN EXCLUDED.ip IS NULL THEN ?
                WHEN btrim(EXCLUDED.ip) = '' THEN NULL
                WHEN ? IS NULL THEN EXCLUDED.ip_source
                WHEN platform.sr_address_strength(EXCLUDED.ip) > platform.sr_address_strength(?)
                  THEN EXCLUDED.ip_source
                WHEN (? || chr(31) || ?) = ANY(?::text[])
                     AND platform.sr_address_strength(EXCLUDED.ip) > 0
                     AND (platform.sr_address_strength(EXCLUDED.ip) / 100 >=
                            platform.sr_address_strength(?) / 100
                          OR ? IS NULL OR ? < ?)
                  THEN EXCLUDED.ip_source
                WHEN (? || chr(31) || ?) = ANY(?::text[]) THEN COALESCE(?, EXCLUDED.ip_source)
                ELSE ?
              END
              """,
              d.deleted_at,
              d.ip_source,
              d.ip,
              d.ip,
              d.uid,
              d.ip,
              ^absent,
              d.ip,
              d.ip_seen_at,
              d.ip_seen_at,
              type(^cutoff, :utc_datetime_usec),
              d.uid,
              d.ip,
              ^resighted,
              d.ip_source,
              d.ip_source
            ),
          ip_seen_at:
            fragment(
              """
              CASE
                WHEN ? IS NOT NULL THEN
                  CASE WHEN NULLIF(btrim(EXCLUDED.ip), '') IS NULL THEN NULL ELSE EXCLUDED.ip_seen_at END
                WHEN EXCLUDED.ip IS NULL THEN ?
                WHEN btrim(EXCLUDED.ip) = '' THEN NULL
                WHEN ? IS NULL THEN EXCLUDED.ip_seen_at
                WHEN platform.sr_address_strength(EXCLUDED.ip) > platform.sr_address_strength(?)
                  THEN EXCLUDED.ip_seen_at
                WHEN (? || chr(31) || ?) = ANY(?::text[])
                     AND platform.sr_address_strength(EXCLUDED.ip) > 0
                     AND (platform.sr_address_strength(EXCLUDED.ip) / 100 >=
                            platform.sr_address_strength(?) / 100
                          OR ? IS NULL OR ? < ?)
                  THEN EXCLUDED.ip_seen_at
                WHEN (? || chr(31) || ?) = ANY(?::text[])
                  THEN GREATEST(?, EXCLUDED.ip_seen_at)
                ELSE ?
              END
              """,
              d.deleted_at,
              d.ip_seen_at,
              d.ip,
              d.ip,
              d.uid,
              d.ip,
              ^absent,
              d.ip,
              d.ip_seen_at,
              d.ip_seen_at,
              type(^cutoff, :utc_datetime_usec),
              d.uid,
              d.ip,
              ^resighted,
              d.ip_seen_at,
              d.ip_seen_at
            ),
          mac: fragment("COALESCE(EXCLUDED.mac, ?)", d.mac),
          # name, hostname, vendor_name, model, type, type_id, metadata
          # device_role and metadata integration_type are RANKED, not
          # last-writer-wins: each write carries the source and evidence strength
          # of the groups it writes in EXCLUDED.attribute_provenance
          # (DeviceRecords, AttributeStrength), and
          # platform.sr_attribute_write_accepted/4 decides each group against the
          # strength the stored row recorded. Before this, a hostname-less passive
          # census sighting renamed an SNMP-named device to its address and an
          # OUI vendor replaced the SNMP vendor every two minutes, and the mapper
          # wrote them back: every flip re-versioned the agent configs compiled
          # from them. A group is accepted or rejected as one value; a field of
          # an accepted group the write does not carry stays stored.
          # DeviceRecords.merge_records_by_uid/1 applies the same rule in-batch,
          # and an address-fallback name follows the address the device keeps
          # (follow_kept_address_names/1).
          hostname:
            fragment(
              """
              CASE
                WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'name',
                       NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?), '') IS NOT NULL)
                  THEN COALESCE(NULLIF(EXCLUDED.hostname, ''), ?)
                ELSE ?
              END
              """,
              d.attribute_provenance,
              d.name,
              d.hostname,
              d.hostname,
              d.hostname
            ),
          name:
            fragment(
              """
              CASE
                WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'name',
                       NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?), '') IS NOT NULL)
                  THEN COALESCE(NULLIF(EXCLUDED.name, ''), ?)
                ELSE ?
              END
              """,
              d.attribute_provenance,
              d.name,
              d.hostname,
              d.name,
              d.name
            ),
          # Classification ownership is separate from discovery provenance:
          # an untyped manual duplicate must not freeze the survivor's inference.
          # An explicit false marker overrides legacy manual-source fallback;
          # absent markers retain compatibility with older manually typed rows.
          # Read ownership from the pre-update row, before provenance is unioned.
          # Keep type and type_id under the same guard so they cannot disagree.
          type:
            fragment(
              """
              CASE
                WHEN COALESCE(?->'type_manually_set' = 'true'::jsonb,
                     'manual' = ANY(COALESCE(?, ARRAY[]::text[])))
                     AND NOT ('manual' = ANY(COALESCE(EXCLUDED.discovery_sources, ARRAY[]::text[])))
                     AND lower(COALESCE(NULLIF(btrim(?), ''), 'unknown')) <> 'unknown'
                  THEN ?
                WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'type',
                       NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?->>'device_role'), '') IS NOT NULL)
                  THEN COALESCE(NULLIF(EXCLUDED.type, ''), ?)
                ELSE ?
              END
              """,
              d.metadata,
              d.discovery_sources,
              d.type,
              d.type,
              d.attribute_provenance,
              d.type,
              d.metadata,
              d.type,
              d.type
            ),
          type_id:
            fragment(
              """
              CASE
                WHEN COALESCE(?->'type_manually_set' = 'true'::jsonb,
                     'manual' = ANY(COALESCE(?, ARRAY[]::text[])))
                     AND NOT ('manual' = ANY(COALESCE(EXCLUDED.discovery_sources, ARRAY[]::text[])))
                     AND lower(COALESCE(NULLIF(btrim(?), ''), 'unknown')) <> 'unknown'
                  THEN ?
                WHEN EXCLUDED.type_id IS NOT NULL AND EXCLUDED.type_id > 0
                     AND platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'type',
                       NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?->>'device_role'), '') IS NOT NULL)
                  THEN EXCLUDED.type_id
                ELSE ?
              END
              """,
              d.metadata,
              d.discovery_sources,
              d.type,
              d.type_id,
              d.attribute_provenance,
              d.type,
              d.metadata,
              d.type_id
            ),
          vendor_name:
            fragment(
              """
              CASE
                WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'vendor',
                       NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?), '') IS NOT NULL)
                  THEN COALESCE(NULLIF(EXCLUDED.vendor_name, ''), ?)
                ELSE ?
              END
              """,
              d.attribute_provenance,
              d.vendor_name,
              d.model,
              d.vendor_name,
              d.vendor_name
            ),
          model:
            fragment(
              """
              CASE
                WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'vendor',
                       NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?), '') IS NOT NULL)
                  THEN COALESCE(NULLIF(EXCLUDED.model, ''), ?)
                ELSE ?
              END
              """,
              d.attribute_provenance,
              d.vendor_name,
              d.model,
              d.model,
              d.model
            ),
          os:
            fragment(
              "COALESCE(?, '{}'::jsonb) || COALESCE(EXCLUDED.os, '{}'::jsonb)",
              d.os
            ),
          hw_info:
            fragment(
              "COALESCE(?, '{}'::jsonb) || COALESCE(EXCLUDED.hw_info, '{}'::jsonb)",
              d.hw_info
            ),
          network_interfaces:
            fragment(
              "CASE WHEN EXCLUDED.network_interfaces IS NOT NULL AND array_length(EXCLUDED.network_interfaces, 1) > 0 THEN EXCLUDED.network_interfaces ELSE ? END",
              d.network_interfaces
            ),
          is_available: fragment("COALESCE(EXCLUDED.is_available, ?)", d.is_available),
          owner: fragment("COALESCE(EXCLUDED.owner, ?)", d.owner),
          # The ranked metadata keys follow their group's decision: the OUI
          # provenance keys follow the kept vendor, device_role the kept type
          # (manual type ownership included), integration_type its own rank. An
          # owned key (AttributeStrength.owned_metadata_keys/0) is replaced only
          # by its owning source; any other writer only fills it when absent.
          metadata:
            fragment(
              """
              (COALESCE(?, '{}'::jsonb) - 'classification_source' - 'classification_rule_id' - 'classification_confidence' - 'classification_reason'
                 - CASE WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'vendor',
                          NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?), '') IS NOT NULL)
                     THEN ARRAY['mac_vendor', 'mac_vendor_source', 'mac_vendor_oui_prefix', 'mac_vendor_oui_snapshot_id']
                     ELSE ARRAY[]::text[] END)
              || (COALESCE(EXCLUDED.metadata, '{}'::jsonb)
                 - CASE WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'vendor',
                          NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?), '') IS NOT NULL)
                     THEN ARRAY[]::text[]
                     ELSE ARRAY['mac_vendor', 'mac_vendor_source', 'mac_vendor_oui_prefix', 'mac_vendor_oui_snapshot_id'] END
                 - CASE WHEN NOT (COALESCE(?->'type_manually_set' = 'true'::jsonb,
                                    'manual' = ANY(COALESCE(?, ARRAY[]::text[])))
                                  AND NOT ('manual' = ANY(COALESCE(EXCLUDED.discovery_sources, ARRAY[]::text[])))
                                  AND lower(COALESCE(NULLIF(btrim(?), ''), 'unknown')) <> 'unknown')
                         AND platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'type',
                          NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?->>'device_role'), '') IS NOT NULL)
                     THEN ARRAY[]::text[]
                     ELSE ARRAY['device_role'] END
                 - CASE WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'integration_type',
                          NULLIF(btrim(?->>'integration_type'), '') IS NOT NULL)
                     THEN ARRAY[]::text[]
                     ELSE ARRAY['integration_type'] END
                 - CASE WHEN 'hypervisor_enrichment' = ANY(COALESCE(EXCLUDED.discovery_sources, ARRAY[]::text[]))
                     THEN ARRAY[]::text[]
                     ELSE ARRAY(SELECT k FROM jsonb_object_keys(COALESCE(?, '{}'::jsonb)) AS k
                                WHERE k IN ('hypervisor_provider_ref', 'proxmox_node', 'proxmox_cluster',
                                            'hypervisor_guest_type', 'hypervisor_vmid', 'proxmox_base_url')) END
                 - CASE WHEN 'mapper' = ANY(COALESCE(EXCLUDED.discovery_sources, ARRAY[]::text[]))
                     THEN ARRAY[]::text[]
                     ELSE ARRAY(SELECT k FROM jsonb_object_keys(COALESCE(?, '{}'::jsonb)) AS k
                                WHERE k IN ('proxmox_candidate', 'proxmox_tls_sans_recorded', 'proxmox_tls_san_ips')) END)
              ||
              jsonb_build_object('type_manually_set',
                CASE
                  WHEN 'manual' = ANY(COALESCE(EXCLUDED.discovery_sources, ARRAY[]::text[]))
                       AND NULLIF(EXCLUDED.type, '') IS NOT NULL
                    THEN lower(COALESCE(NULLIF(btrim(EXCLUDED.type), ''), 'unknown')) <> 'unknown'
                  ELSE COALESCE(?->'type_manually_set' = 'true'::jsonb,
                         'manual' = ANY(COALESCE(?, ARRAY[]::text[])))
                       AND lower(COALESCE(NULLIF(btrim(?), ''), 'unknown')) <> 'unknown'
                END)
              """,
              # stored side: classification strip, vendor decision
              d.metadata,
              d.attribute_provenance,
              d.vendor_name,
              d.model,
              # incoming side: vendor decision
              d.attribute_provenance,
              d.vendor_name,
              d.model,
              # incoming side: manual type guard, then type decision
              d.metadata,
              d.discovery_sources,
              d.type,
              d.attribute_provenance,
              d.type,
              d.metadata,
              # incoming side: integration_type decision
              d.attribute_provenance,
              d.metadata,
              # incoming side: owned keys
              d.metadata,
              d.metadata,
              # type_manually_set
              d.metadata,
              d.discovery_sources,
              d.type
            ),
          attribute_provenance:
            fragment(
              """
              COALESCE(?, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
                'name',
                CASE WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'name',
                       NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?), '') IS NOT NULL)
                  THEN EXCLUDED.attribute_provenance->'name' END,
                'vendor',
                CASE WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'vendor',
                       NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?), '') IS NOT NULL)
                  THEN EXCLUDED.attribute_provenance->'vendor' END,
                'type',
                CASE WHEN NOT (COALESCE(?->'type_manually_set' = 'true'::jsonb,
                                 'manual' = ANY(COALESCE(?, ARRAY[]::text[])))
                               AND NOT ('manual' = ANY(COALESCE(EXCLUDED.discovery_sources, ARRAY[]::text[])))
                               AND lower(COALESCE(NULLIF(btrim(?), ''), 'unknown')) <> 'unknown')
                      AND platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'type',
                       NULLIF(btrim(?), '') IS NOT NULL OR NULLIF(btrim(?->>'device_role'), '') IS NOT NULL)
                  THEN EXCLUDED.attribute_provenance->'type' END,
                'integration_type',
                CASE WHEN platform.sr_attribute_write_accepted(?, EXCLUDED.attribute_provenance, 'integration_type',
                       NULLIF(btrim(?->>'integration_type'), '') IS NOT NULL)
                  THEN EXCLUDED.attribute_provenance->'integration_type' END
              ))
              """,
              d.attribute_provenance,
              d.attribute_provenance,
              d.name,
              d.hostname,
              d.attribute_provenance,
              d.vendor_name,
              d.model,
              d.metadata,
              d.discovery_sources,
              d.type,
              d.attribute_provenance,
              d.type,
              d.metadata,
              d.attribute_provenance,
              d.metadata
            ),
          identity_revision:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN ? + 1 ELSE ? END",
              d.deleted_at,
              d.identity_revision,
              d.identity_revision
            ),
          deleted_at: nil,
          deleted_by: nil,
          deleted_reason: nil,
          discovery_sources:
            fragment(
              "(SELECT array_agg(DISTINCT src) FROM unnest(array_cat(COALESCE(?, ARRAY[]::text[]), EXCLUDED.discovery_sources)) AS src WHERE src IS NOT NULL AND src <> '')",
              d.discovery_sources
            ),
          # The last identity-bearing observation only moves forward, and a
          # write that carries none (NULL) leaves it as it is.
          identity_observed_at:
            fragment("GREATEST(EXCLUDED.identity_observed_at, ?)", d.identity_observed_at),
          last_seen_time: fragment("EXCLUDED.last_seen_time"),
          modified_time: fragment("EXCLUDED.modified_time")
        ]
      ]
    )
  end
end
