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

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SourceIdentityDrift
  alias ServiceRadar.Inventory.Sync.DeviceRecords
  alias ServiceRadar.Inventory.Sync.SourcePolicy
  alias ServiceRadar.Repo

  require Logger

  @inventory_rollup_refresh_lock_key 20_240_306
  @default_inventory_rollup_bulk_refresh_threshold 100
  # Concurrent cross-handoffs can deadlock on per-row release UPDATEs; retry a
  # few times after locking UIDs in a deterministic order.
  @deadlock_retries 3
  @identity_anchor_types [
    :agent_id,
    :armis_device_id,
    :integration_id,
    :netbox_device_id,
    :hardware_serial,
    :mac
  ]

  # DB connection's search_path determines the schema
  def bulk_upsert_devices(records, strong_uids \\ MapSet.new()) do
    update_query = device_upsert_update_query()
    refresh_rollups? = inventory_rollup_bulk_refresh_required?(length(records))
    do_bulk_upsert_devices(records, update_query, strong_uids, refresh_rollups?)
  rescue
    e ->
      Logger.warning("Bulk device upsert failed: #{inspect(e)}")
      {:error, e}
  end

  defp do_bulk_upsert_devices(records, update_query, strong_uids, refresh_rollups?) do
    # Resolve predictable active-IP collisions up front so the first insert
    # succeeds. Reactive recovery below only covers concurrent writers that
    # land between this prepare step and insert_all.
    {prepared_records, remap, releases} =
      prepare_active_ip_claims(records, strong_uids, :precheck)

    # Test-only barrier point (Application env :device_writes_test_hooks).
    run_test_hook(:after_active_ip_precheck)

    insert_devices_with_releases(prepared_records, releases, update_query, refresh_rollups?)
    {:ok, remap}
  rescue
    e in Postgrex.Error ->
      if ip_unique_conflict?(e) do
        recover_ip_conflict_and_retry(records, update_query, strong_uids, e, refresh_rollups?)
      else
        Logger.warning("Bulk device upsert failed: #{inspect(e)}")
        {:error, e}
      end
  end

  defp recover_ip_conflict_and_retry(
         records,
         update_query,
         strong_uids,
         original_error,
         refresh_rollups?
       ) do
    {recovered_records, remap, releases} =
      prepare_active_ip_claims(records, strong_uids, :retry)

    run_test_hook(:after_active_ip_precheck)

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
           update_query,
           refresh_rollups?
         ) do
      :ok -> {:ok, remap}
      {:error, _} = error -> error
    end
  end

  defp do_bulk_upsert_devices_once(records, releases, update_query, refresh_rollups?) do
    insert_devices_with_releases(records, releases, update_query, refresh_rollups?)
    :ok
  rescue
    error ->
      Logger.warning("Bulk device upsert retry failed: #{inspect(error)}")
      {:error, error}
  end

  # When a batch moves device A off IP X while device B claims X, multi-row
  # INSERT ... ON CONFLICT can still trip the unique index depending on row
  # order. Clear the relinquished IPs first, then apply the final claims, in
  # one transaction so a failed upsert cannot leave owners IP-less.
  defp insert_devices_with_releases(records, releases, update_query, refresh_rollups?) do
    with_deadlock_retry(fn ->
      do_insert_devices_with_releases(records, releases, update_query, refresh_rollups?)
    end)
  end

  defp do_insert_devices_with_releases(records, [], update_query, refresh_rollups?) do
    insert_devices(records, update_query, refresh_rollups?)
  end

  defp do_insert_devices_with_releases(records, releases, update_query, true) do
    with_inventory_rollup_bypassed(fn ->
      lock_and_clear_for_upsert(records, releases)
      insert_devices(records, update_query, false)
    end)
  end

  defp do_insert_devices_with_releases(records, releases, update_query, false) do
    Repo.transaction(
      fn ->
        lock_and_clear_for_upsert(records, releases)
        insert_devices(records, update_query, false)
      end,
      timeout: :infinity
    )
  end

  defp insert_devices(records, update_query, true) do
    with_inventory_rollup_bypassed(fn -> insert_devices(records, update_query, false) end)
  end

  defp insert_devices(records, update_query, false) do
    Repo.insert_all(
      Device,
      jsonb_safe(records),
      on_conflict: update_query,
      conflict_target: [:uid]
    )
  end

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
  defp lock_and_clear_for_upsert(_records, []), do: :ok

  defp lock_and_clear_for_upsert(records, releases) do
    releases =
      releases
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

    {uids_col, ips_col} = Enum.unzip(releases)

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
            )
      ),
      set: [ip: nil]
    )
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
  # Returns `{prepared_records, remap, releases}` where `remap` is
  # `original_uid => canonical_uid` and `releases` is a list of
  # `{owner_uid, ip}` pairs that this batch moves off an IP (staged before
  # insert so same-batch handoffs are atomic).
  defp prepare_active_ip_claims(records, strong_uids, reason) do
    {remapped_records, remap, releases} = remap_records_to_existing_ip(records, strong_uids)
    prepared_records = DeviceRecords.merge_records_by_uid(remapped_records)

    if map_size(remap) > 0 or active_ip_claims_changed?(records, prepared_records) or
         releases != [] do
      Logger.info(
        "SyncIngestor: #{active_ip_prepare_label(reason)} active-IP claims " <>
          "(uid_remaps=#{map_size(remap)}, releases=#{length(releases)}, " <>
          "records=#{length(records)}->#{length(prepared_records)})"
      )
    end

    {prepared_records, remap, releases}
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

  # Returns `{remapped_records, remap, releases}` where `remap` is a map of
  # `original_uid => canonical_uid` for every record whose uid was rewritten to
  # match an existing active device sharing the same IP, and `releases` lists
  # `{owner_uid, ip}` for owners that this batch moves onto a different IP.
  # Callers must apply the same mapping to any other record set referencing
  # those uids (identifier rows, alias-state updates) before issuing dependent
  # inserts.
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

    {remapped_records, {remap, conflicts, _anchors}} =
      Enum.map_reduce(records, {%{}, [], :not_loaded}, fn record, acc ->
        resolve_record_active_ip(
          record,
          strong_uids,
          active_holders,
          existing_by_ip,
          incoming_ip_owners,
          acc
        )
      end)

    # One batched diagnostic write instead of an insert per IP collision.
    _ = SourceIdentityDrift.record_conflicts(Enum.reverse(conflicts))

    {remapped_records, remap, Enum.uniq(releases)}
  end

  # Match the partial unique index predicate exactly so Postgres can use
  # ocsf_devices_unique_active_ip_idx (index-only) instead of a sequential scan.
  defp load_active_ip_owners([]), do: %{}

  defp load_active_ip_owners(ips) do
    from(d in Device,
      where: d.ip in ^ips and is_nil(d.deleted_at) and not is_nil(d.ip) and d.ip != "",
      select: {d.ip, %{uid: d.uid, metadata: d.metadata, hostname: d.hostname, mac: d.mac}}
    )
    |> Repo.all()
    |> Map.new()
  end

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
    Enum.reduce(existing_by_ip, {%{}, []}, fn {ip, holder}, {keepers, releases} ->
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
            {Map.put(keepers, ip, holder), releases}
          end

        :error ->
          {Map.put(keepers, ip, holder), releases}
      end
    end)
  end

  defp resolve_record_active_ip(
         record,
         strong_uids,
         active_holders,
         existing_by_ip,
         incoming_ip_owners,
         {remap, conflicts, anchors}
       ) do
    ip = Map.get(record, :ip)

    case Map.get(active_holders, ip) do
      nil ->
        {resolved, {remap, conflicts}} =
          drop_batch_conflicting_ip(record, incoming_ip_owners, strong_uids, remap, conflicts)

        {resolved, {remap, conflicts, anchors}}

      %{uid: existing_uid} when existing_uid == record.uid ->
        {record, {remap, conflicts, anchors}}

      %{uid: existing_uid} = existing ->
        if MapSet.member?(strong_uids, record.uid) do
          # Defer identifier-anchor lookup until a strong identity actually
          # collides with a different active owner (provisional-seed path).
          {anchors, anchored_uids} = ensure_anchored_uids(anchors, existing_by_ip)

          if provisional_ip_seed?(existing, anchored_uids) do
            {Map.put(record, :uid, existing_uid),
             {Map.put(remap, record.uid, existing_uid), conflicts, anchors}}
          else
            # Strong identities never adopt an arbitrary IP owner. A
            # truly provisional seed is the sole exception and is safe
            # only while it has no registered identity anchor.
            Logger.info(
              "SyncIngestor: dropping conflicting IP #{ip} from strong-identified " <>
                "device #{record.uid} (held by #{existing_uid})"
            )

            conflict = SourceIdentityDrift.build_active_ip_conflict(record, existing_uid, ip)

            {Map.put(record, :ip, nil), {remap, prepend_conflict(conflicts, conflict), anchors}}
          end
        else
          {Map.put(record, :uid, existing_uid),
           {Map.put(remap, record.uid, existing_uid), conflicts, anchors}}
        end
    end
  end

  defp ensure_anchored_uids(:not_loaded, existing_by_ip) do
    set = anchored_device_uids(existing_by_ip)
    {set, set}
  end

  defp ensure_anchored_uids(%MapSet{} = set, _existing_by_ip), do: {set, set}

  defp anchored_device_uids(existing_by_ip) do
    uids = existing_by_ip |> Map.values() |> Enum.map(& &1.uid) |> Enum.uniq()

    if uids == [] do
      MapSet.new()
    else
      DeviceIdentifier
      |> where([identifier], identifier.device_id in ^uids)
      |> where([identifier], identifier.identifier_type in ^@identity_anchor_types)
      |> select([identifier], identifier.device_id)
      |> Repo.all()
      |> MapSet.new()
    end
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
  # Case 2 is deliberately narrow. Treating every unanchored holder as a seed
  # covers 6,906 rows on the deployment surveyed, of which 6,749 carry a
  # hostname or MAC and are precisely what "a strong identity never adopts an IP
  # owner" exists to protect; only 157 are true IP-only seeds. A hostname is
  # evidence; an IP by itself is not, because IPs move.
  #
  # Adoption does not discard the seed. The incoming record takes the *existing*
  # uid, so an operator-added "something is at this IP" row survives and gains
  # the discovered identity, which is what lets importing and manual entry
  # coexist.
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

  # A failed INSERT can be caused by two previously-unseen records in the same
  # bulk statement sharing an IP. There is no database owner to find in that
  # case, so the old recovery path retried the exact same conflict. Never pick
  # one source identity as the winner based on record order: remove the
  # contested IP from every distinct UID and retain their stronger identities.
  defp incoming_ip_owners(records) do
    records
    |> Enum.filter(&SourcePolicy.valid_ip?(Map.get(&1, :ip)))
    |> Enum.group_by(&Map.get(&1, :ip), &Map.fetch!(&1, :uid))
    |> Map.new(fn {ip, uids} -> {ip, Enum.uniq(uids)} end)
  end

  defp drop_batch_conflicting_ip(record, incoming_ip_owners, strong_uids, remap, conflicts) do
    ip = Map.get(record, :ip)
    conflicting_uids = Map.get(incoming_ip_owners, ip, [])

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

  defp with_inventory_rollup_bypassed(fun) when is_function(fun, 0) do
    Repo.transaction(
      fn ->
        Repo.query!("SET LOCAL platform.skip_inventory_rollup = 'on'")
        fun.()
      end,
      timeout: :infinity
    )
  end

  defp refresh_inventory_rollups do
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

  defp device_upsert_update_query do
    from(d in Device,
      update: [
        set: [
          # nil EXCLUDED.ip = omit (keep current). Blank EXCLUDED.ip = explicit
          # clear to NULL (vacates ocsf_devices_unique_active_ip_idx). A bare
          # COALESCE would treat '' as present and store empty strings, which
          # diverged from the release classifier and broke blank-IP handoffs.
          #
          # The rank guard is NEVER-DOWNGRADE, deliberately not "only promote".
          # An equal-ranked address must still win, because that is a host
          # genuinely changing address (192.168.2.243 -> 192.168.1.171) and
          # refusing it would freeze every device at its first address. What it
          # blocks is a WORSE address overwriting a good one: an NDP census
          # sighting carries a `fe80::` link-local, and before this guard that
          # silently replaced a routable primary -- 25 of 126 live devices on one
          # deployment (GitHub #3905).
          #
          # A device whose only known address is link-local keeps it: its current
          # rank is then equal, not higher, so the incoming value still applies.
          #
          # LEAST(rank, 40) collapses global and private into ONE routable tier
          # for this comparison. Both are legitimate primary addresses, and a
          # host re-addressed from a public to an RFC1918 address is a real move,
          # not noise -- comparing the fine-grained ranks would refuse it and
          # freeze the device on a stale public address. The finer ranking still
          # applies where it belongs, in Identity.Address.best/1, which chooses
          # among addresses known at the SAME time.
          #
          # What stays blocked is what this guard is for: ULA (30) and link-local
          # (20) cannot overwrite anything routable, and nothing can overwrite
          # with an address that is never a primary (0).
          ip:
            fragment(
              """
              CASE
                WHEN EXCLUDED.ip IS NULL THEN ?
                WHEN btrim(EXCLUDED.ip) = '' THEN NULL
                WHEN ? IS NULL THEN EXCLUDED.ip
                WHEN LEAST(platform.sr_address_rank(EXCLUDED.ip), 40)
                     >= LEAST(platform.sr_address_rank(?), 40)
                  THEN EXCLUDED.ip
                ELSE ?
              END
              """,
              d.ip,
              d.ip,
              d.ip,
              d.ip
            ),
          mac: fragment("COALESCE(EXCLUDED.mac, ?)", d.mac),
          hostname: fragment("COALESCE(EXCLUDED.hostname, ?)", d.hostname),
          name: fragment("COALESCE(EXCLUDED.name, ?)", d.name),
          type:
            fragment(
              "COALESCE(NULLIF(EXCLUDED.type, ''), ?)",
              d.type
            ),
          type_id:
            fragment(
              "CASE WHEN EXCLUDED.type_id IS NOT NULL AND EXCLUDED.type_id > 0 THEN EXCLUDED.type_id ELSE ? END",
              d.type_id
            ),
          vendor_name: fragment("COALESCE(EXCLUDED.vendor_name, ?)", d.vendor_name),
          model: fragment("COALESCE(EXCLUDED.model, ?)", d.model),
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
          metadata:
            fragment(
              "(COALESCE(?, '{}'::jsonb) - 'classification_source' - 'classification_rule_id' - 'classification_confidence' - 'classification_reason' - 'mac_vendor' - 'mac_vendor_source' - 'mac_vendor_oui_prefix' - 'mac_vendor_oui_snapshot_id') || COALESCE(EXCLUDED.metadata, '{}'::jsonb)",
              d.metadata
            ),
          deleted_at: nil,
          deleted_by: nil,
          deleted_reason: nil,
          discovery_sources:
            fragment(
              "(SELECT array_agg(DISTINCT src) FROM unnest(array_cat(COALESCE(?, ARRAY[]::text[]), EXCLUDED.discovery_sources)) AS src WHERE src IS NOT NULL AND src <> '')",
              d.discovery_sources
            ),
          last_seen_time: fragment("EXCLUDED.last_seen_time"),
          modified_time: fragment("EXCLUDED.modified_time")
        ]
      ]
    )
  end
end
