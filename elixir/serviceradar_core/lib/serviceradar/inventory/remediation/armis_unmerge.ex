defmodule ServiceRadar.Inventory.Remediation.ArmisUnmerge do
  @moduledoc """
  Step `armis-unmerge` — the inverse of `armis-dups`, disposition of the Armis
  over-merge (OpenSpec `remediate-armis-overmerge-disposition`).

  Before the ingest-time distinct-MAC veto existed, `BatchResolver` resolved
  every strong-identified update carrying a shared `armis_device_id` to the same
  canonical device, collapsing distinct hardware (distinct universally-administered
  MACs) onto one "mega-device". That collapse happened at resolve time, not via
  `merge_devices`, so there is no reversible `merge_audit` — the target grouping
  is reconstructed from **current state** (the universal MAC identifier rows now
  on the device), reusing the veto's own `Identity.Mac.universal_macs/1` so the
  split is provably the inverse of prevention.

  Per candidate: group the universal MAC identifiers into one class per distinct
  MAC (`Decisions.plan_armis_unmerge/2`). Co-occurrence provenance is lost, so
  multi-NIC hosts are conservatively over-split. Identifier ownership is stable
  by design, so later multi-MAC ingest does not automatically rejoin those
  classes; live execution therefore requires an explicit source and device
  allowlist backed by independent operator evidence. The **survivor** class
  keeps the existing device (adopting a live one, restoring a tombstoned ghost)
  and its `armis_device_id`; every other class gets a fresh device with the deterministic
  UID a veto-gated ingest would mint and receives that class's MAC identifier rows
  via the audited, TTL-resetting `DeviceIdentifier :reassign_device` — which is
  simultaneously the reassign-before-delete rescue for the ~389k sole-copy MAC
  rows orphaned onto `armis_source_device_id_ghost_cleanup` tombstones.

  Two candidate populations:

    * live Armis-keyed devices with >= 2 distinct universal MACs (over-merged), and
    * ghost tombstones (`deleted_reason = 'armis_source_device_id_ghost_cleanup'`)
      holding any universal MAC (orphaned hardware to re-home).

  Each candidate is applied in one database transaction after locking and
  revalidating the source device, its complete universal-MAC row set, and every
  existing target. A stale plan or partial failure rolls back the whole
  candidate. Manifest entries are written only after commit. One `merge_audit`
  `reason: "unmerge"` row per split arms the symmetric per-pair re-collapse
  cooldown without creating a survivor-to-split canonical redirect.

  NOTE (faker / demo): distinct-MAC count is not a reliable over-merge signal on
  faker-heavy data (the demo faker mints many MACs per device by design). This
  step is registered dormant — dry-run runnable, but excluded from the default
  execute order. Execution is also disabled inside this module unless
  `:armis_unmerge_execute_enabled` is true. Live candidates additionally require
  `:armis_unmerge_include_live`, membership in
  `:armis_unmerge_live_device_uids`, and membership of their sync source in
  `:armis_unmerge_live_source_ids`. Recognized faker sources are never eligible.
  """

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @step "armis-unmerge"
  @default_plan_sample_limit 50
  @default_candidate_limit 5_000
  @transaction_resources [Device, DeviceIdentifier, MergeAudit]

  # Atomic, universally-administered MAC identifier rows (2nd hex char of a
  # universal MAC is never in the locally-administered set). Kept in one place so
  # detection cannot drift from `Identity.Mac.universal_macs/1`.
  @universal_mac_filter "identifier_type = 'mac' " <>
                          "AND identifier_value ~ '^[0-9A-Fa-f]{12}$' " <>
                          "AND substr(upper(identifier_value), 2, 1) " <>
                          "NOT IN ('2','3','6','7','A','B','E','F')"

  @doc false
  def run(mode, opts, manifest, actor) do
    sample_limit = Keyword.get(opts, :armis_unmerge_plan_sample_limit, @default_plan_sample_limit)
    candidate_limit = Keyword.get(opts, :armis_unmerge_candidate_limit, @default_candidate_limit)

    devices = detect_candidates(candidate_limit, mode, opts)
    preconditions = detect_preconditions(candidate_limit, mode, opts)

    planned =
      Enum.map(devices, fn device ->
        {device, Decisions.plan_armis_unmerge(device, device.mac_rows)}
      end)

    splits = for {device, {:split, plan}} <- planned, do: {device, plan}
    skips = for {_device, {:skip, reason}} <- planned, do: to_string(reason)

    execution_splits = execution_splits(splits, opts)

    base = %{
      candidate_devices: length(devices),
      universal_mac_count_distribution:
        devices
        |> Enum.map(& &1.universal_mac_count)
        |> Enum.frequencies()
        |> Map.new(fn {count, frequency} -> {to_string(count), frequency} end),
      detected_planned_splits: length(splits),
      detected_split_plan: splits |> Enum.take(sample_limit) |> Enum.map(&plan_sample(&1, opts)),
      planned_splits: length(execution_splits),
      planned_new_devices: sum_by(execution_splits, fn {_d, p} -> length(p.splits) end),
      planned_identifier_reassignments:
        sum_by(execution_splits, fn {_d, p} -> sum_by(p.splits, &length(&1.row_ids)) end),
      skipped: Enum.frequencies(skips),
      split_plan: execution_splits |> Enum.take(sample_limit) |> Enum.map(&plan_sample(&1, opts)),
      execution_split_plan:
        execution_splits |> Enum.take(sample_limit) |> Enum.map(&plan_sample(&1, opts)),
      preconditions: preconditions
    }

    live_split_count = Enum.count(splits, fn {device, _plan} -> not device.tombstoned? end)

    eligible_live_count =
      Enum.count(execution_splits, fn {device, _plan} -> not device.tombstoned? end)

    base =
      Map.merge(base, %{
        execution_eligible_splits: length(execution_splits),
        excluded_live_splits: live_split_count - eligible_live_count
      })

    case mode do
      :dry_run ->
        base

      :execute ->
        cond do
          not execute_enabled?(opts) ->
            blocked_execution_report(base, :armis_unmerge_execute_disabled)

          preconditions.invalid_mac_rows > 0 ->
            blocked_execution_report(base, :blob_purge_precondition_failed)

          true ->
            {applied, failed, reassigned, created} =
              execute_splits(execution_splits, manifest, actor)

            Map.merge(base, %{
              execution_blocked: false,
              applied_splits: applied,
              split_failures: failed,
              applied_new_devices: created,
              applied_identifier_reassignments: reassigned
            })
        end
    end
  end

  # -- detection ------------------------------------------------------------

  defp detect_candidates(limit, mode, opts) do
    {scope_filter, order_by, scope_params} = detection_scope(mode, opts)

    %{rows: rows} =
      query!(
        """
        WITH universal AS (
          SELECT device_id, count(DISTINCT upper(identifier_value)) AS n
          FROM platform.device_identifiers
          WHERE #{@universal_mac_filter}
          GROUP BY device_id
        )
        SELECT d.uid,
               COALESCE(NULLIF(d.metadata->>'armis_device_id', ''), di.identifier_value) AS armis_device_id,
               d.mac AS device_mac,
               (d.deleted_at IS NOT NULL) AS tombstoned,
               universal.n AS universal_mac_count,
               d.hostname,
               NULLIF(d.metadata->>'sync_service_id', '') AS sync_service_id,
               COALESCE(integration_ids.n, 0) AS integration_id_count,
               (
                 upper(COALESCE(d.hostname, '')) LIKE 'FAKER-%'
                 OR lower(COALESCE(src.name, '')) LIKE '%faker%'
                 OR lower(COALESCE(src.endpoint, '')) LIKE '%serviceradar-faker%'
               ) AS faker_source
        FROM platform.ocsf_devices d
        JOIN universal ON universal.device_id = d.uid
        LEFT JOIN LATERAL (
          SELECT identifier_value
          FROM platform.device_identifiers
          WHERE device_id = d.uid AND identifier_type = 'armis_device_id'
          LIMIT 1
        ) di ON true
        LEFT JOIN LATERAL (
          SELECT count(DISTINCT identifier_value) AS n
          FROM platform.device_identifiers
          WHERE device_id = d.uid AND identifier_type = 'integration_id'
        ) integration_ids ON true
        LEFT JOIN platform.integration_sources src
          ON src.id::text = NULLIF(d.metadata->>'sync_service_id', '')
        WHERE (
          (
            d.deleted_at IS NULL
            AND ('armis' = ANY(d.discovery_sources)
                 OR COALESCE(d.metadata->>'integration_type', '') = 'armis')
            AND universal.n >= 2
          )
          OR (d.deleted_reason = 'armis_source_device_id_ghost_cleanup' AND universal.n >= 1)
        )
        #{scope_filter}
        ORDER BY #{order_by}
        LIMIT $1
        """,
        [limit | scope_params]
      )

    uids = Enum.map(rows, fn [uid | _] -> uid end)
    mac_rows_by_device = load_universal_mac_rows(uids)

    Enum.map(rows, fn [
                        uid,
                        armis_id,
                        device_mac,
                        tombstoned,
                        universal_mac_count,
                        hostname,
                        sync_service_id,
                        integration_id_count,
                        faker_source
                      ] ->
      mac_rows = Map.get(mac_rows_by_device, uid, [])

      %{
        uid: uid,
        mac: device_mac,
        armis_device_id: normalize_string(armis_id),
        hostname: normalize_string(hostname),
        sync_service_id: normalize_string(sync_service_id),
        faker_source?: faker_source,
        live_overmerge_verified?: tombstoned or integration_id_count >= 2,
        universal_mac_count: universal_mac_count,
        partition: dominant_partition(mac_rows),
        tombstoned?: tombstoned,
        mac_rows: Enum.map(mac_rows, &Map.take(&1, [:id, :value, :last_seen, :partition]))
      }
    end)
  end

  defp detection_scope(:execute, opts) do
    include_live? = Keyword.get(opts, :armis_unmerge_include_live, false)
    device_uids = allowlist_values(opts, :armis_unmerge_live_device_uids, include_live?)
    source_ids = allowlist_values(opts, :armis_unmerge_live_source_ids, include_live?)

    filter = """
    AND (
      d.deleted_reason = 'armis_source_device_id_ghost_cleanup'
      OR (
        d.deleted_at IS NULL
        AND d.uid = ANY($2::text[])
        AND NULLIF(d.metadata->>'sync_service_id', '') = ANY($3::text[])
        AND upper(COALESCE(d.hostname, '')) NOT LIKE 'FAKER-%'
        AND lower(COALESCE(src.name, '')) NOT LIKE '%faker%'
        AND lower(COALESCE(src.endpoint, '')) NOT LIKE '%serviceradar-faker%'
      )
    )
    """

    {filter, "CASE WHEN d.uid = ANY($2::text[]) THEN 0 ELSE 1 END, universal.n DESC, d.uid",
     [device_uids, source_ids]}
  end

  defp detection_scope(:dry_run, opts) do
    device_uids = allowlist_values(opts, :armis_unmerge_live_device_uids, true)
    source_ids = allowlist_values(opts, :armis_unmerge_live_source_ids, true)

    if Keyword.get(opts, :armis_unmerge_include_live, false) and device_uids != [] and
         source_ids != [] do
      {"",
       "CASE WHEN d.uid = ANY($2::text[]) AND NULLIF(d.metadata->>'sync_service_id', '') = ANY($3::text[]) THEN 0 ELSE 1 END, universal.n DESC, d.uid",
       [device_uids, source_ids]}
    else
      {"", "universal.n DESC, d.uid", []}
    end
  end

  defp detection_scope(_mode, _opts), do: {"", "universal.n DESC, d.uid", []}

  defp allowlist_values(opts, key, true) do
    opts
    |> Keyword.get(key, [])
    |> normalize_allowlist()
    |> MapSet.to_list()
  end

  defp allowlist_values(_opts, _key, false), do: []

  defp detect_preconditions(limit, mode, opts) do
    scoped? = mode == :execute or Keyword.get(opts, :armis_unmerge_include_live, false)

    {scope_filter, limit_clause, scope_params} =
      if scoped? do
        device_uids = allowlist_values(opts, :armis_unmerge_live_device_uids, true)
        source_ids = allowlist_values(opts, :armis_unmerge_live_source_ids, true)

        {"""
         AND (
           d.deleted_reason = 'armis_source_device_id_ghost_cleanup'
           OR (
             d.deleted_at IS NULL
             AND d.uid = ANY($1::text[])
             AND NULLIF(d.metadata->>'sync_service_id', '') = ANY($2::text[])
             AND upper(COALESCE(d.hostname, '')) NOT LIKE 'FAKER-%'
             AND lower(COALESCE(src.name, '')) NOT LIKE '%faker%'
             AND lower(COALESCE(src.endpoint, '')) NOT LIKE '%serviceradar-faker%'
           )
         )
         """, "", [device_uids, source_ids]}
      else
        {"", "ORDER BY d.uid LIMIT $1", [limit]}
      end

    %{rows: [[invalid_rows, invalid_devices, macless_devices, local_only_devices]]} =
      query!(
        """
        WITH candidate_devices AS (
          SELECT d.uid
          FROM platform.ocsf_devices d
          LEFT JOIN platform.integration_sources src
            ON src.id::text = NULLIF(d.metadata->>'sync_service_id', '')
          WHERE (
            (
              d.deleted_at IS NULL
              AND ('armis' = ANY(d.discovery_sources)
                   OR COALESCE(d.metadata->>'integration_type', '') = 'armis')
            )
            OR d.deleted_reason = 'armis_source_device_id_ghost_cleanup'
          )
          #{scope_filter}
          #{limit_clause}
        ), per_device AS (
          SELECT cd.uid,
                 count(di.id) FILTER (WHERE di.identifier_type = 'mac') AS mac_rows,
                 count(di.id) FILTER (
                   WHERE di.identifier_type = 'mac'
                     AND di.identifier_value !~ '^[0-9A-Fa-f]{12}$'
                 ) AS invalid_rows,
                 count(di.id) FILTER (WHERE #{@universal_mac_filter}) AS universal_rows
          FROM candidate_devices cd
          LEFT JOIN platform.device_identifiers di ON di.device_id = cd.uid
          GROUP BY cd.uid
        )
        SELECT COALESCE(sum(invalid_rows), 0),
               count(*) FILTER (WHERE invalid_rows > 0),
               count(*) FILTER (WHERE mac_rows = 0),
               count(*) FILTER (WHERE mac_rows > 0 AND universal_rows = 0)
        FROM per_device
        """,
        scope_params
      )

    invalid_rows = count_to_integer(invalid_rows)
    invalid_devices = count_to_integer(invalid_devices)
    macless_devices = count_to_integer(macless_devices)
    local_only_devices = count_to_integer(local_only_devices)

    %{
      blob_purge_ready: invalid_rows == 0,
      invalid_mac_rows: invalid_rows,
      invalid_mac_devices: invalid_devices,
      macless_devices: macless_devices,
      local_only_devices: local_only_devices
    }
  end

  defp execute_enabled?(opts) do
    runtime_enabled? =
      :serviceradar_core
      |> Application.get_env(ServiceRadar.Inventory.Remediation.DireRemediation, [])
      |> Keyword.get(:enable_armis_unmerge_execute, false)

    runtime_enabled? and Keyword.get(opts, :armis_unmerge_execute_enabled, false)
  end

  defp load_universal_mac_rows([]), do: %{}

  defp load_universal_mac_rows(uids) do
    %{rows: rows} =
      query!(
        """
        SELECT id, device_id, upper(identifier_value) AS mac, last_seen, partition
        FROM platform.device_identifiers
        WHERE device_id = ANY($1) AND #{@universal_mac_filter}
        """,
        [uids]
      )

    rows
    |> Enum.group_by(fn [_id, device_id | _] -> device_id end)
    |> Map.new(fn {device_id, device_rows} ->
      {device_id,
       Enum.map(device_rows, fn [id, _dev, mac, last_seen, partition] ->
         %{id: id, value: mac, last_seen: to_datetime(last_seen), partition: partition}
       end)}
    end)
  end

  defp execution_splits(splits, opts) do
    Enum.filter(splits, &is_nil(execution_exclusion_reason(&1, opts)))
  end

  defp execution_exclusion_reason({%{tombstoned?: true}, _plan}, _opts), do: nil

  defp execution_exclusion_reason({device, _plan}, opts) do
    include_live? = Keyword.get(opts, :armis_unmerge_include_live, false)

    allowed_device_uids =
      opts
      |> Keyword.get(:armis_unmerge_live_device_uids, [])
      |> normalize_allowlist()

    allowed_source_ids =
      opts
      |> Keyword.get(:armis_unmerge_live_source_ids, [])
      |> normalize_allowlist()

    cond do
      not include_live? -> :live_execution_not_enabled
      device.faker_source? -> :faker_source_forbidden
      not MapSet.member?(allowed_device_uids, device.uid) -> :device_not_allowlisted
      not MapSet.member?(allowed_source_ids, device.sync_service_id) -> :source_not_allowlisted
      true -> nil
    end
  end

  defp normalize_allowlist(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp normalize_allowlist(_values), do: MapSet.new()

  defp blocked_execution_report(base, reason) do
    Map.merge(base, %{
      execution_blocked: true,
      execution_blocked_reason: to_string(reason),
      applied_splits: 0,
      split_failures: 0,
      applied_new_devices: 0,
      applied_identifier_reassignments: 0
    })
  end

  # -- execute --------------------------------------------------------------

  defp execute_splits(splits, manifest, actor) do
    Enum.reduce(splits, {0, 0, 0, 0}, fn {device, plan}, {applied, failed, reassigns, created} ->
      case apply_split(device, plan, manifest, actor) do
        {:ok, %{reassigned: r, created: c}} ->
          {applied + 1, failed, reassigns + r, created + c}

        {:error, error} ->
          Logger.warning("ArmisUnmerge: split of #{device.uid} failed: #{inspect(error)}")
          {applied, failed + 1, reassigns, created}
      end
    end)
  end

  defp lock_and_revalidate_candidate(device, plan) do
    with :ok <- validate_plan_shape(device, plan),
         {:ok, current_device} <- lock_source_device(device.uid),
         :ok <- validate_source_state(device, plan, current_device),
         :ok <- validate_live_source(device, current_device),
         :ok <- lock_and_validate_identifier_ownership(device.uid, plan) do
      lock_and_validate_targets(plan)
    end
  end

  defp validate_plan_shape(device, plan) do
    split_uids = Enum.map(plan.splits, & &1.new_uid)
    row_ids = plan.survivor.row_ids ++ Enum.flat_map(plan.splits, & &1.row_ids)

    cond do
      plan.device_uid != device.uid or plan.survivor.uid != device.uid ->
        {:error, :stale_source_device}

      Enum.any?(split_uids, &(&1 == device.uid)) ->
        {:error, :self_target_split}

      length(split_uids) != length(Enum.uniq(split_uids)) ->
        {:error, :duplicate_split_target}

      length(row_ids) != length(Enum.uniq(row_ids)) ->
        {:error, :duplicate_identifier_assignment}

      true ->
        :ok
    end
  end

  defp lock_source_device(uid) do
    # `device_identifiers.device_id` has a foreign key to this row. PostgreSQL
    # takes a KEY SHARE lock for a concurrent child insert/reparent, which
    # conflicts with this FOR UPDATE lock. Inserts that began first are visible
    # to the exact-set validation below; later inserts wait until commit.
    %{rows: rows} =
      query!(
        """
        SELECT (deleted_at IS NOT NULL), hostname,
               NULLIF(metadata->>'sync_service_id', '')
        FROM platform.ocsf_devices
        WHERE uid = $1
        FOR UPDATE
        """,
        [uid]
      )

    case rows do
      [[tombstoned, hostname, sync_service_id]] ->
        {:ok,
         %{
           tombstoned?: tombstoned,
           hostname: normalize_string(hostname),
           sync_service_id: normalize_string(sync_service_id)
         }}

      _ ->
        {:error, :source_device_missing}
    end
  end

  defp validate_source_state(device, plan, current) do
    expected_tombstoned? = device.tombstoned? and plan.survivor.action == :restore

    if current.tombstoned? == expected_tombstoned? do
      :ok
    else
      {:error, :source_device_state_changed}
    end
  end

  defp validate_live_source(%{tombstoned?: true}, _current), do: :ok

  defp validate_live_source(device, current) do
    cond do
      current.sync_service_id != device.sync_service_id ->
        {:error, :source_identity_changed}

      faker_hostname?(current.hostname) ->
        {:error, :faker_source_forbidden}

      is_nil(current.sync_service_id) ->
        {:error, :live_source_missing}

      true ->
        lock_and_validate_integration_source(current.sync_service_id)
    end
  end

  defp lock_and_validate_integration_source(source_id) do
    %{rows: rows} =
      query!(
        """
        SELECT name, endpoint
        FROM platform.integration_sources
        WHERE id::text = $1
        FOR UPDATE
        """,
        [source_id]
      )

    case rows do
      [[name, endpoint]] ->
        if faker_text?(name) or faker_endpoint?(endpoint),
          do: {:error, :faker_source_forbidden},
          else: :ok

      _ ->
        {:error, :live_source_missing}
    end
  end

  defp lock_and_validate_identifier_ownership(source_uid, plan) do
    %{rows: rows} =
      query!(
        """
        SELECT id, upper(identifier_value)
        FROM platform.device_identifiers
        WHERE device_id = $1 AND #{@universal_mac_filter}
        ORDER BY id
        FOR UPDATE
        """,
        [source_uid]
      )

    actual_by_id = Map.new(rows, fn [id, mac] -> {id, mac} end)
    actual_ids = actual_by_id |> Map.keys() |> MapSet.new()

    expected_ids =
      plan.survivor.row_ids
      |> Kernel.++(Enum.flat_map(plan.splits, & &1.row_ids))
      |> MapSet.new()

    cond do
      actual_ids != expected_ids ->
        {:error, :identifier_ownership_changed}

      Enum.any?(plan.splits, fn split ->
        Enum.any?(split.row_ids, &(Map.get(actual_by_id, &1) != split.mac))
      end) ->
        {:error, :identifier_value_changed}

      true ->
        :ok
    end
  end

  defp lock_and_validate_targets(%{splits: []}), do: :ok

  defp lock_and_validate_targets(plan) do
    target_uids = Enum.map(plan.splits, & &1.new_uid)

    _locked =
      query!(
        "SELECT uid FROM platform.ocsf_devices WHERE uid = ANY($1) FOR UPDATE",
        [target_uids]
      )

    %{rows: identifier_rows} =
      query!(
        """
        SELECT device_id, id
        FROM platform.device_identifiers
        WHERE device_id = ANY($1) AND #{@universal_mac_filter}
        FOR UPDATE
        """,
        [target_uids]
      )

    case identifier_rows do
      [] -> :ok
      _ -> {:error, :split_target_has_universal_mac}
    end
  end

  defp apply_split(device, plan, manifest, actor) do
    @transaction_resources
    |> Ash.transaction(fn ->
      result =
        with :ok <- lock_and_revalidate_candidate(device, plan),
             {:ok, survivor_entries} <- ensure_survivor(plan, actor),
             {:ok, _touched, touch_entries} <- touch_survivor_rows(plan, actor),
             {:ok, split_result} <- apply_all_splits(device, plan, actor) do
          %{
            reassigned: split_result.reassigned,
            created: split_result.created,
            manifest_entries: survivor_entries ++ touch_entries ++ split_result.manifest_entries
          }
        end

      case result do
        {:error, reason} -> Ash.DataLayer.rollback(@transaction_resources, reason)
        success -> success
      end
    end)
    |> case do
      {:ok, result} ->
        record_manifest_entries(manifest, result.manifest_entries)
        {:ok, Map.delete(result, :manifest_entries)}

      {:error, reason} ->
        {:error, reason}

      {:error, reason, _stacktrace} ->
        {:error, reason}
    end
  end

  defp apply_all_splits(device, plan, actor) do
    Enum.reduce_while(plan.splits, {:ok, %{reassigned: 0, created: 0, manifest_entries: []}}, fn
      split, {:ok, acc} ->
        case apply_one_split(device, plan, split, actor) do
          {:ok, current} ->
            {:cont,
             {:ok,
              %{
                reassigned: acc.reassigned + current.reassigned,
                created: acc.created + current.created,
                manifest_entries: acc.manifest_entries ++ current.manifest_entries
              }}}

          {:error, _} = error ->
            {:halt, error}
        end
    end)
  end

  defp ensure_survivor(%{survivor: %{action: :adopt, uid: uid, mac: mac}}, actor) do
    set_device_mac(uid, mac, actor, "survivor")
  end

  defp ensure_survivor(%{survivor: %{action: :restore, uid: uid, mac: mac}}, actor) do
    with {:ok, restore_entries} <- restore_device(uid, actor, "survivor"),
         {:ok, mac_entries} <- set_device_mac(uid, mac, actor, "survivor") do
      {:ok, restore_entries ++ mac_entries}
    end
  end

  # Survivor-class rows are not reassigned, so they get no :reassign_device
  # last_seen bump. Touch them so their TTL clock resets with the disposition —
  # a restored ghost's sole-copy MAC would otherwise be GC-eligible the moment
  # :restore nulls the deleted_reason guard while last_seen stays pinned to the
  # cleanup date.
  defp touch_survivor_rows(%{survivor: %{row_ids: []}}, _actor), do: {:ok, 0, []}

  defp touch_survivor_rows(%{survivor: %{uid: uid, row_ids: row_ids}}, actor) do
    with {:ok, identifiers} <- load_identifiers(row_ids, actor),
         {:ok, touched} <- do_touch(identifiers, actor) do
      entries =
        manifest_entry(:touch_identifier, "platform.device_identifiers", touched, %{
          device_uid: uid,
          role: "survivor"
        })

      {:ok, length(touched), entries}
    end
  end

  defp do_touch(identifiers, actor) do
    identifiers
    |> Enum.reduce_while({:ok, []}, fn identifier, {:ok, acc} ->
      case identifier
           |> Ash.Changeset.for_update(:touch, %{})
           |> Ash.update(actor: actor) do
        {:ok, _} -> {:cont, {:ok, [identifier.id | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      other -> other
    end
  end

  defp apply_one_split(device, plan, split, actor) do
    with {:ok, created, device_entries} <- ensure_split_device(split, actor),
         {:ok, reassigned, identifier_entries} <-
           reassign_rows(split.row_ids, split.new_uid, actor),
         :ok <- record_unmerge_audit(device.uid, split, plan, actor) do
      {:ok,
       %{
         reassigned: reassigned,
         created: created,
         manifest_entries: device_entries ++ identifier_entries
       }}
    end
  end

  defp ensure_split_device(split, actor) do
    case load_device_state(split.new_uid) do
      :live ->
        with {:ok, entries} <- set_device_mac(split.new_uid, split.mac, actor, "split"),
             do: {:ok, 0, entries}

      :tombstoned ->
        with {:ok, restore_entries} <- restore_device(split.new_uid, actor, "split"),
             {:ok, mac_entries} <- set_device_mac(split.new_uid, split.mac, actor, "split") do
          {:ok, 0, restore_entries ++ mac_entries}
        end

      :absent ->
        create_split_device(split.new_uid, split.mac, actor)
    end
  end

  defp load_device_state(uid) do
    %{rows: rows} =
      query!(
        "SELECT (deleted_at IS NOT NULL) FROM platform.ocsf_devices WHERE uid = $1 LIMIT 1",
        [uid]
      )

    case rows do
      [[true]] -> :tombstoned
      [[false]] -> :live
      _ -> :absent
    end
  end

  defp restore_device(uid, actor, role) do
    result =
      Device
      |> Ash.Query.for_read(:by_uid, %{uid: uid, include_deleted: true})
      |> Ash.bulk_update(:restore, %{},
        actor: actor,
        return_errors?: true,
        strategy: [:atomic, :stream]
      )

    case result do
      %Ash.BulkResult{status: :success} ->
        {:ok, manifest_entry(:restore_device, "platform.ocsf_devices", [uid], %{role: role})}

      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  defp create_split_device(uid, mac, actor) do
    case Device
         |> Ash.Changeset.for_create(:create, %{uid: uid, mac: mac})
         |> Ash.create(actor: actor) do
      {:ok, device} ->
        entries =
          manifest_entry(:create_device, "platform.ocsf_devices", [device.uid], %{role: "split"})

        {:ok, 1, entries}

      {:error, _} = err ->
        err
    end
  end

  defp set_device_mac(uid, mac, actor, role) do
    with {:ok, device} <- Device.get_by_uid(uid, true, actor: actor) do
      if device.mac == mac do
        {:ok, []}
      else
        case device
             |> Ash.Changeset.for_update(:update, %{mac: mac})
             |> Ash.update(actor: actor) do
          {:ok, _updated} ->
            {:ok,
             manifest_entry(:update_device_mac, "platform.ocsf_devices", [uid], %{
               role: role,
               mac: mac
             })}

          {:error, _} = error ->
            error
        end
      end
    end
  end

  defp reassign_rows([], _target, _actor), do: {:ok, 0, []}

  defp reassign_rows(row_ids, target_uid, actor) do
    with {:ok, identifiers} <- load_identifiers(row_ids, actor),
         {:ok, moved} <- do_reassign(identifiers, target_uid, actor) do
      entries =
        manifest_entry(:reassign_identifier, "platform.device_identifiers", moved, %{
          to: target_uid
        })

      {:ok, length(moved), entries}
    end
  end

  defp load_identifiers(row_ids, actor) do
    DeviceIdentifier
    |> Ash.Query.filter(id in ^row_ids)
    |> Ash.read(actor: actor)
    |> Page.unwrap()
  end

  defp do_reassign(identifiers, target_uid, actor) do
    identifiers
    |> Enum.reduce_while({:ok, []}, fn identifier, {:ok, acc} ->
      case identifier
           |> Ash.Changeset.for_update(:reassign_device, %{device_id: target_uid})
           |> Ash.update(actor: actor) do
        {:ok, _} -> {:cont, {:ok, [identifier.id | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      other -> other
    end
  end

  defp record_unmerge_audit(from_uid, split, plan, actor) do
    case MergeAudit.record(
           %{
             # Cooldown matching is symmetric. Keeping the split as `from`
             # also preserves the merge-audit direction invariant: the
             # survivor must never canonical-follow to one arbitrary split.
             from_device_id: split.new_uid,
             to_device_id: from_uid,
             reason: "unmerge",
             source: "dire_remediation",
             details: %{
               step: @step,
               split_from_device_id: from_uid,
               armis_device_id: plan.armis_device_id,
               mac: split.mac
             }
           },
           actor: actor
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp manifest_entry(_action, _table, [], _extra), do: []

  defp manifest_entry(action, table, ids, extra) do
    [%{action: action, table: table, ids: ids, extra: extra}]
  end

  defp record_manifest_entries(manifest, entries) do
    Enum.each(entries, fn entry ->
      Manifest.record(manifest, @step, entry.action, entry.table, entry.ids, entry.extra)
    end)
  end

  # -- report ---------------------------------------------------------------

  defp plan_sample({device, plan} = candidate, opts) do
    exclusion_reason = execution_exclusion_reason(candidate, opts)

    %{
      device_uid: device.uid,
      hostname: device.hostname,
      sync_service_id: device.sync_service_id,
      faker_source: device.faker_source?,
      live_overmerge_verified: device.live_overmerge_verified?,
      universal_mac_count: device.universal_mac_count,
      execution_eligible: is_nil(exclusion_reason),
      execution_exclusion_reason: exclusion_reason && to_string(exclusion_reason),
      armis_device_id: plan.armis_device_id,
      tombstoned: plan.tombstoned?,
      survivor_mac: plan.survivor.mac,
      survivor_action: to_string(plan.survivor.action),
      new_device_count: length(plan.splits),
      new_devices:
        Enum.map(plan.splits, fn s ->
          %{mac: s.mac, uid: s.new_uid, identifiers: length(s.row_ids)}
        end)
    }
  end

  # -- helpers --------------------------------------------------------------

  defp dominant_partition([]), do: "default"

  defp dominant_partition(mac_rows) do
    mac_rows
    |> Enum.map(& &1.partition)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_partition, count} -> count end, fn -> {"default", 0} end)
    |> elem(0)
  end

  defp sum_by(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp to_datetime(_), do: nil

  defp count_to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp count_to_integer(value) when is_integer(value), do: value
  defp count_to_integer(_value), do: 0

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp faker_hostname?(hostname) when is_binary(hostname),
    do: hostname |> String.upcase() |> String.starts_with?("FAKER-")

  defp faker_hostname?(_hostname), do: false

  defp faker_text?(value) when is_binary(value),
    do: value |> String.downcase() |> String.contains?("faker")

  defp faker_text?(_value), do: false

  defp faker_endpoint?(value) when is_binary(value),
    do: value |> String.downcase() |> String.contains?("serviceradar-faker")

  defp faker_endpoint?(_value), do: false

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
