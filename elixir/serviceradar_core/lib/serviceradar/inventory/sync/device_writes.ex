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
    {prepared_records, remap} = prepare_active_ip_claims(records, strong_uids, :precheck)

    insert_devices(prepared_records, update_query, refresh_rollups?)
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
    {recovered_records, remap} = prepare_active_ip_claims(records, strong_uids, :retry)

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

    case do_bulk_upsert_devices_once(recovered_records, update_query, refresh_rollups?) do
      :ok -> {:ok, remap}
      {:error, _} = error -> error
    end
  end

  defp do_bulk_upsert_devices_once(records, update_query, refresh_rollups?) do
    insert_devices(records, update_query, refresh_rollups?)
    :ok
  rescue
    error ->
      Logger.warning("Bulk device upsert retry failed: #{inspect(error)}")
      {:error, error}
  end

  defp insert_devices(records, update_query, true) do
    with_inventory_rollup_bypassed(fn -> insert_devices(records, update_query, false) end)
  end

  defp insert_devices(records, update_query, false) do
    Repo.insert_all(
      Device,
      records,
      on_conflict: update_query,
      conflict_target: [:uid]
    )
  end

  # Apply the same active-IP policy used by conflict recovery *before* insert so
  # recurring sync batches do not pay a unique_violation + retry every cycle.
  # Returns `{prepared_records, remap}` where `remap` is `original_uid =>
  # canonical_uid` for weak records rewritten onto the current IP owner.
  defp prepare_active_ip_claims(records, strong_uids, reason) do
    {remapped_records, remap} = remap_records_to_existing_ip(records, strong_uids)
    prepared_records = DeviceRecords.merge_records_by_uid(remapped_records)

    if map_size(remap) > 0 or active_ip_claims_changed?(records, prepared_records) do
      Logger.info(
        "SyncIngestor: #{active_ip_prepare_label(reason)} active-IP claims " <>
          "(uid_remaps=#{map_size(remap)}, records=#{length(records)}->" <>
          "#{length(prepared_records)})"
      )
    end

    {prepared_records, remap}
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

  # Returns `{remapped_records, remap}` where `remap` is a map of
  # `original_uid => canonical_uid` for every record whose uid was rewritten to
  # match an existing active device sharing the same IP. Callers must apply the
  # same mapping to any other record set referencing those uids (identifier
  # rows, alias-state updates) before issuing dependent inserts.
  defp remap_records_to_existing_ip(records, strong_uids) do
    ips =
      records
      |> Enum.map(&Map.get(&1, :ip))
      |> Enum.filter(&SourcePolicy.valid_ip?/1)
      |> Enum.uniq()

    existing_by_ip =
      if ips == [] do
        %{}
      else
        query =
          from(d in Device,
            where: d.ip in ^ips and is_nil(d.deleted_at),
            select: {d.ip, %{uid: d.uid, metadata: d.metadata}}
          )

        query |> Repo.all() |> Map.new()
      end

    anchored_uids = anchored_device_uids(existing_by_ip)
    incoming_ip_owners = incoming_ip_owners(records)

    {remapped_records, {remap, conflicts}} =
      Enum.map_reduce(records, {%{}, []}, fn record, {remap, conflicts} ->
        ip = Map.get(record, :ip)

        case Map.get(existing_by_ip, ip) do
          nil ->
            drop_batch_conflicting_ip(record, incoming_ip_owners, strong_uids, remap, conflicts)

          %{uid: existing_uid} when existing_uid == record.uid ->
            {record, {remap, conflicts}}

          %{uid: existing_uid} = existing ->
            if MapSet.member?(strong_uids, record.uid) do
              if provisional_ip_seed?(existing, anchored_uids) do
                {Map.put(record, :uid, existing_uid),
                 {Map.put(remap, record.uid, existing_uid), conflicts}}
              else
                # Strong identities never adopt an arbitrary IP owner. A
                # truly provisional seed is the sole exception and is safe
                # only while it has no registered identity anchor.
                Logger.info(
                  "SyncIngestor: dropping conflicting IP #{ip} from strong-identified " <>
                    "device #{record.uid} (held by #{existing_uid})"
                )

                conflict = SourceIdentityDrift.build_active_ip_conflict(record, existing_uid, ip)

                {Map.put(record, :ip, nil), {remap, prepend_conflict(conflicts, conflict)}}
              end
            else
              {Map.put(record, :uid, existing_uid),
               {Map.put(remap, record.uid, existing_uid), conflicts}}
            end
        end
      end)

    # One batched diagnostic write instead of an insert per IP collision.
    _ = SourceIdentityDrift.record_conflicts(Enum.reverse(conflicts))

    {remapped_records, remap}
  end

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

  defp provisional_ip_seed?(%{uid: uid, metadata: metadata}, anchored_uids) do
    is_map(metadata) and metadata["identity_state"] == "provisional" and
      not MapSet.member?(anchored_uids, uid)
  end

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
          ip: fragment("COALESCE(EXCLUDED.ip, ?)", d.ip),
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
              "(COALESCE(?, '{}'::jsonb) - 'classification_source' - 'classification_rule_id' - 'classification_confidence' - 'classification_reason') || COALESCE(EXCLUDED.metadata, '{}'::jsonb)",
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
