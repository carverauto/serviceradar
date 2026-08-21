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
  keeps the existing source device (or restores that source when it is a ghost)
  and its `armis_device_id`; every other class requires an absent, remediation-
  stable target UID, gets a fresh device, and receives that class's MAC identifier rows
  via the audited, TTL-resetting `DeviceIdentifier :reassign_device` — which is
  simultaneously the reassign-before-delete rescue for the ~389k sole-copy MAC
  rows orphaned onto `armis_source_device_id_ghost_cleanup` tombstones.

  Two candidate populations:

    * live Armis-keyed devices with >= 2 distinct universal MACs (over-merged), and
    * ghost tombstones (`deleted_reason = 'armis_source_device_id_ghost_cleanup'`)
      holding any universal MAC (orphaned hardware to re-home).

  Each candidate is applied in one database transaction after locking and
  revalidating the source device, its complete identifier set, and every global
  MAC/Armis owner. Existing split targets, stale plans, and partial failures roll
  back the whole candidate. A durable manifest preflight and prepared action set
  are synced before commit, followed by a synced committed marker. One `merge_audit`
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
  alias ServiceRadar.Inventory.Identity.Mac
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @step "armis-unmerge"
  @default_plan_sample_limit 50
  @default_dry_run_candidate_limit 5_000
  @default_execute_candidate_limit 25
  @transaction_resources [Device, DeviceIdentifier, MergeAudit]

  # Atomic, universally-administered MAC identifier rows (2nd hex char of a
  # universal MAC is never in the locally-administered set). Kept in one place so
  # detection cannot drift from `Identity.Mac.universal_macs/1`.
  @canonical_mac_pattern ~r/^[0-9A-F]{12}$/
  @universal_mac_filter "identifier_type = 'mac' " <>
                          "AND identifier_value ~ '^[0-9A-F]{12}$' " <>
                          "AND substr(upper(identifier_value), 2, 1) " <>
                          "NOT IN ('2','3','6','7','A','B','E','F')"

  @doc false
  def run(mode, opts, manifest, actor) do
    sample_limit = Keyword.get(opts, :armis_unmerge_plan_sample_limit, @default_plan_sample_limit)

    default_candidate_limit =
      if mode == :execute,
        do: @default_execute_candidate_limit,
        else: @default_dry_run_candidate_limit

    candidate_limit = Keyword.get(opts, :armis_unmerge_candidate_limit, default_candidate_limit)

    devices = detect_candidates(candidate_limit, mode, opts)
    preconditions = detect_preconditions(candidate_limit, mode, opts)

    {unsplittable_count, unsplittable_sample} =
      detect_unsplittable_summary(sample_limit, mode, opts)

    planned =
      Enum.map(devices, fn device ->
        {device, Decisions.plan_armis_unmerge(device, device.mac_rows)}
      end)

    splits = for {device, {:split, plan}} <- planned, do: {device, plan}
    skips = for {device, {:skip, reason}} <- planned, do: {device, to_string(reason)}

    skipped_counts =
      skips
      |> Enum.map(&elem(&1, 1))
      |> Enum.frequencies()
      |> Map.update(
        "no_universal_mac",
        unsplittable_count,
        &max(&1, unsplittable_count)
      )

    planner_skip_sample =
      skips
      |> Enum.sort_by(fn {device, reason} -> {reason, device.uid} end)
      |> Enum.map(fn {device, reason} -> %{device_uid: device.uid, reason: reason} end)

    skipped_device_sample =
      (unsplittable_sample ++ planner_skip_sample)
      |> Enum.uniq_by(&{&1.device_uid, &1.reason})
      |> Enum.take(sample_limit)

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
      skipped: skipped_counts,
      skipped_device_sample: skipped_device_sample,
      unsplittable_devices: unsplittable_count,
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
            {applied, failed, reassigned, created, manifest_failures} =
              execute_splits(execution_splits, manifest, actor)

            Map.merge(base, %{
              execution_blocked: false,
              applied_splits: applied,
              split_failures: failed,
              manifest_failures: manifest_failures,
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
               NULLIF(d.metadata->>'armis_device_id', '') AS metadata_armis_device_id,
               d.mac AS device_mac,
               (d.deleted_at IS NOT NULL) AS tombstoned,
               d.deleted_reason,
               universal.n AS universal_mac_count,
               d.hostname,
               NULLIF(d.metadata->>'sync_service_id', '') AS sync_service_id,
               NULLIF(d.metadata->>'integration_type', '') AS integration_type,
               COALESCE(d.discovery_sources, ARRAY[]::text[]) AS discovery_sources,
               src.source_type::text,
               src.name,
               src.endpoint,
               src.partition
        FROM platform.ocsf_devices d
        JOIN universal ON universal.device_id = d.uid
        LEFT JOIN platform.integration_sources src
          ON src.id::text = NULLIF(d.metadata->>'sync_service_id', '')
        WHERE (
          (
            d.deleted_at IS NULL
            AND COALESCE(d.metadata->>'integration_type', '') = 'armis'
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
    identifier_rows_by_device = load_candidate_identifier_rows(uids)

    Enum.map(rows, fn [
                        uid,
                        metadata_armis_id,
                        device_mac,
                        tombstoned,
                        deleted_reason,
                        universal_mac_count,
                        hostname,
                        sync_service_id,
                        integration_type,
                        discovery_sources,
                        source_type,
                        source_name,
                        source_endpoint,
                        source_partition
                      ] ->
      identifier_rows = Map.get(identifier_rows_by_device, uid, [])
      typed_armis_rows = Enum.filter(identifier_rows, &(&1.type == "armis_device_id"))
      integration_rows = Enum.filter(identifier_rows, &(&1.type == "integration_id"))
      all_mac_rows = Enum.filter(identifier_rows, &(&1.type == "mac"))
      mac_rows = Enum.filter(all_mac_rows, &canonical_universal_mac_row?/1)
      sync_service_id = normalize_string(sync_service_id)

      typed_armis_id =
        case typed_armis_rows do
          [%{value: value}] -> normalize_string(value)
          _ -> nil
        end

      integration_ids =
        integration_rows
        |> Enum.filter(&identifier_matches_armis_source?(&1, sync_service_id))
        |> Enum.map(&normalize_string(&1.value))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      metadata_armis_id = normalize_string(metadata_armis_id)
      hostname = normalize_string(hostname)

      armis_provenance_valid? =
        tombstoned or
          case typed_armis_rows do
            [row] -> identifier_matches_armis_source?(row, sync_service_id)
            _ -> false
          end

      %{
        uid: uid,
        mac: device_mac,
        armis_device_id: typed_armis_id,
        metadata_armis_device_id: metadata_armis_id,
        typed_armis_rows: typed_armis_rows,
        armis_provenance_valid?: armis_provenance_valid?,
        hostname: hostname,
        sync_service_id: sync_service_id,
        integration_type: normalize_string(integration_type),
        discovery_sources: normalize_string_list(discovery_sources),
        source_type: normalize_string(source_type),
        source_name: normalize_string(source_name),
        source_endpoint: normalize_string(source_endpoint),
        source_partition: canonical_partition(source_partition),
        deleted_reason: normalize_string(deleted_reason),
        faker_source?:
          faker_hostname?(hostname) or faker_text?(source_name) or
            faker_endpoint?(source_endpoint),
        live_overmerge_verified?:
          tombstoned or (length(integration_ids) >= 2 and source_type == "armis"),
        integration_ids: integration_ids,
        universal_mac_count: universal_mac_count,
        tombstoned?: tombstoned,
        identifier_snapshot:
          Enum.map(identifier_rows, &Map.take(&1, [:id, :type, :value, :partition])),
        mac_rows: Enum.map(mac_rows, &Map.take(&1, [:id, :value, :partition]))
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

  defp detect_unsplittable_summary(sample_limit, mode, opts) do
    {scope_filter, scope_params} = remediation_report_scope(mode, opts)
    sample_param = "$#{length(scope_params) + 1}"

    %{rows: [[count, uids]]} =
      query!(
        """
        WITH unsplittable AS (
          SELECT d.uid
          FROM platform.ocsf_devices d
          LEFT JOIN platform.integration_sources src
            ON src.id::text = NULLIF(d.metadata->>'sync_service_id', '')
          WHERE (
            (
              d.deleted_at IS NULL
              AND COALESCE(d.metadata->>'integration_type', '') = 'armis'
            )
            OR d.deleted_reason = 'armis_source_device_id_ghost_cleanup'
          )
          #{scope_filter}
          AND NOT EXISTS (
            SELECT 1
            FROM platform.device_identifiers di
            WHERE di.device_id = d.uid
              AND #{@universal_mac_filter}
          )
        )
        SELECT count(*)::bigint,
               COALESCE(
                 (
                   SELECT array_agg(sample.uid ORDER BY sample.uid)
                   FROM (
                     SELECT uid
                     FROM unsplittable
                     ORDER BY uid
                     LIMIT #{sample_param}
                   ) sample
                 ),
                 ARRAY[]::text[]
               )
        FROM unsplittable
        """,
        scope_params ++ [sample_limit]
      )

    sample = Enum.map(uids, &%{device_uid: &1, reason: "no_universal_mac"})
    {count_to_integer(count), sample}
  end

  defp remediation_report_scope(mode, opts) do
    scoped? = mode == :execute or Keyword.get(opts, :armis_unmerge_include_live, false)

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
       """, [device_uids, source_ids]}
    else
      {"", []}
    end
  end

  defp detect_preconditions(limit, mode, opts) do
    {scope_filter, scope_params} = remediation_report_scope(mode, opts)

    {limit_clause, query_params} =
      case scope_params do
        [] -> {"ORDER BY d.uid LIMIT $1", [limit]}
        _scoped -> {"", scope_params}
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
              AND COALESCE(d.metadata->>'integration_type', '') = 'armis'
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
                     AND di.identifier_value !~ '^[0-9A-F]{12}$'
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
        query_params
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

  defp load_candidate_identifier_rows([]), do: %{}

  defp load_candidate_identifier_rows(uids) do
    %{rows: rows} =
      query!(
        """
        SELECT id, device_id, identifier_type::text, identifier_value, partition,
               NULLIF(metadata->>'sync_service_id', ''),
               NULLIF(metadata->>'integration_type', '')
        FROM platform.device_identifiers
        WHERE device_id = ANY($1)
        ORDER BY device_id, identifier_type, id
        """,
        [uids]
      )

    rows
    |> Enum.group_by(fn [_id, device_id | _] -> device_id end)
    |> Map.new(fn {device_id, device_rows} ->
      {device_id,
       Enum.map(device_rows, fn [id, _dev, type, value, partition, source_id, integration_type] ->
         %{
           id: id,
           type: type,
           value: value,
           partition: partition,
           source_id: normalize_string(source_id),
           integration_type: normalize_string(integration_type)
         }
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
      manifest_failures: 0,
      applied_new_devices: 0,
      applied_identifier_reassignments: 0
    })
  end

  # -- execute --------------------------------------------------------------

  defp execute_splits(splits, manifest, actor) do
    Enum.reduce_while(
      splits,
      {0, 0, 0, 0, 0},
      fn {device, plan}, {applied, failed, reassigns, created, manifest_failures} ->
        case apply_split_safely(device, plan, manifest, actor) do
          {:ok, %{reassigned: r, created: c}} ->
            {:cont, {applied + 1, failed, reassigns + r, created + c, manifest_failures}}

          {:error, {:manifest_preflight_failed, error}} ->
            Logger.warning(
              "ArmisUnmerge: manifest preflight for #{device.uid} failed: #{inspect(error)}"
            )

            {:halt, {applied, failed + 1, reassigns, created, manifest_failures + 1}}

          {:committed_manifest_error, %{reassigned: r, created: c}, error} ->
            Logger.error(
              "ArmisUnmerge: split of #{device.uid} committed but manifest marker failed: #{inspect(error)}"
            )

            {:halt, {applied + 1, failed + 1, reassigns + r, created + c, manifest_failures + 1}}

          {:error, {:manifest_prepare_failed, error}} ->
            Logger.warning(
              "ArmisUnmerge: prepared manifest for #{device.uid} failed: #{inspect(error)}"
            )

            {:halt, {applied, failed + 1, reassigns, created, manifest_failures + 1}}

          {:error, error} ->
            if manifest_prepare_failure?(error) do
              Logger.warning(
                "ArmisUnmerge: prepared manifest for #{device.uid} failed: #{inspect(error)}"
              )

              {:halt, {applied, failed + 1, reassigns, created, manifest_failures + 1}}
            else
              Logger.warning("ArmisUnmerge: split of #{device.uid} failed: #{inspect(error)}")
              {:cont, {applied, failed + 1, reassigns, created, manifest_failures}}
            end
        end
      end
    )
  end

  defp apply_split_safely(device, plan, manifest, actor) do
    apply_split(device, plan, manifest, actor)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      if database_timeout_exception?(error) do
        reason = database_timeout_reason(error)

        Logger.warning("ArmisUnmerge: database timeout for #{device.uid}: #{inspect(reason)}")

        {:error, {:database_timeout, reason}}
      else
        reraise error, __STACKTRACE__
      end
  catch
    :exit, {:timeout, _detail} = reason ->
      Logger.warning(
        "ArmisUnmerge: database operation for #{device.uid} exited on timeout: #{inspect(reason)}"
      )

      {:error, {:database_timeout, %{kind: :exit, reason: inspect(reason)}}}

    kind, reason ->
      Logger.error(
        "ArmisUnmerge: unexpected #{kind} while applying #{device.uid}: #{inspect(reason)}"
      )

      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp lock_and_revalidate_candidate(device, plan) do
    with :ok <- validate_plan_shape(device, plan),
         :ok <- acquire_owner_mutation_barrier(),
         {:ok, current_device} <- lock_source_device(device.uid),
         :ok <- validate_source_state(device, plan, current_device),
         :ok <- validate_live_source(device, plan, current_device),
         :ok <- lock_and_validate_identifier_ownership(device, plan),
         :ok <- lock_and_validate_global_mac_owners(device.uid, plan) do
      lock_and_validate_targets(plan)
    end
  end

  # Ordinary ingest does not participate in this step's advisory locks. These
  # short maintenance locks conflict with INSERT/UPDATE/DELETE on both owner
  # tables, making the subsequent global absence predicates a real barrier.
  defp acquire_owner_mutation_barrier do
    query!("SELECT set_config('lock_timeout', $1, true)", ["5s"])
    query!("SELECT set_config('statement_timeout', $1, true)", ["30s"])

    query!(
      "LOCK TABLE platform.ocsf_devices, platform.device_identifiers " <>
        "IN SHARE ROW EXCLUSIVE MODE",
      []
    )

    :ok
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

      not device.tombstoned? and device.source_partition != plan.partition ->
        {:error, :source_partition_mismatch}

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
        SELECT (deleted_at IS NOT NULL), deleted_reason, hostname, mac,
               NULLIF(metadata->>'sync_service_id', ''),
               NULLIF(metadata->>'armis_device_id', ''),
               NULLIF(metadata->>'integration_type', ''),
               COALESCE(discovery_sources, ARRAY[]::text[])
        FROM platform.ocsf_devices
        WHERE uid = $1
        FOR UPDATE
        """,
        [uid]
      )

    case rows do
      [
        [
          tombstoned,
          deleted_reason,
          hostname,
          mac,
          sync_service_id,
          metadata_armis_device_id,
          integration_type,
          discovery_sources
        ]
      ] ->
        {:ok,
         %{
           tombstoned?: tombstoned,
           deleted_reason: normalize_string(deleted_reason),
           hostname: normalize_string(hostname),
           mac: mac,
           sync_service_id: normalize_string(sync_service_id),
           metadata_armis_device_id: normalize_string(metadata_armis_device_id),
           integration_type: normalize_string(integration_type),
           discovery_sources: normalize_string_list(discovery_sources)
         }}

      _ ->
        {:error, :source_device_missing}
    end
  end

  defp validate_source_state(device, plan, current) do
    expected_tombstoned? = device.tombstoned? and plan.survivor.action == :restore

    cond do
      current.tombstoned? != expected_tombstoned? ->
        {:error, :source_device_state_changed}

      current.deleted_reason != device.deleted_reason ->
        {:error, :source_deleted_reason_changed}

      current.mac != device.mac ->
        {:error, :source_display_mac_changed}

      current.metadata_armis_device_id != device.metadata_armis_device_id ->
        {:error, :source_armis_metadata_changed}

      current.integration_type != device.integration_type ->
        {:error, :source_integration_type_changed}

      current.discovery_sources != device.discovery_sources ->
        {:error, :source_discovery_sources_changed}

      true ->
        :ok
    end
  end

  defp validate_live_source(%{tombstoned?: true}, _plan, _current), do: :ok

  defp validate_live_source(device, plan, current) do
    cond do
      current.sync_service_id != device.sync_service_id ->
        {:error, :source_identity_changed}

      current.integration_type != "armis" ->
        {:error, :noncanonical_armis_integration}

      faker_hostname?(current.hostname) ->
        {:error, :faker_source_forbidden}

      is_nil(current.sync_service_id) ->
        {:error, :live_source_missing}

      true ->
        lock_and_validate_integration_source(device, plan, current.sync_service_id)
    end
  end

  defp lock_and_validate_integration_source(device, plan, source_id) do
    %{rows: rows} =
      query!(
        """
        SELECT source_type::text, name, endpoint, partition
        FROM platform.integration_sources
        WHERE id::text = $1
        FOR UPDATE
        """,
        [source_id]
      )

    case rows do
      [[source_type, name, endpoint, partition]] ->
        partition = canonical_partition(partition)

        cond do
          source_type != "armis" ->
            {:error, :non_armis_integration_source}

          normalize_string(source_type) != device.source_type or
            normalize_string(name) != device.source_name or
              normalize_string(endpoint) != device.source_endpoint ->
            {:error, :integration_source_changed}

          partition != device.source_partition ->
            {:error, :integration_source_partition_changed}

          partition != plan.partition ->
            {:error, :source_partition_mismatch}

          faker_text?(name) or faker_endpoint?(endpoint) ->
            {:error, :faker_source_forbidden}

          true ->
            :ok
        end

      _ ->
        {:error, :live_source_missing}
    end
  end

  defp lock_and_validate_identifier_ownership(device, plan) do
    %{rows: rows} =
      query!(
        """
        SELECT id, identifier_type::text, identifier_value, partition,
               NULLIF(metadata->>'sync_service_id', ''),
               NULLIF(metadata->>'integration_type', '')
        FROM platform.device_identifiers
        WHERE device_id = $1
        ORDER BY identifier_type, id
        FOR UPDATE
        """,
        [device.uid]
      )

    actual =
      Enum.map(rows, fn [id, type, value, partition, source_id, integration_type] ->
        %{
          id: id,
          type: type,
          value: value,
          partition: partition,
          source_id: normalize_string(source_id),
          integration_type: normalize_string(integration_type)
        }
      end)

    actual_snapshot = Enum.map(actual, &Map.take(&1, [:id, :type, :value, :partition]))

    typed_armis_rows = Enum.filter(actual, &(&1.type == "armis_device_id"))

    integration_ids =
      actual
      |> Enum.filter(&(&1.type == "integration_id"))
      |> Enum.filter(&identifier_matches_armis_source?(&1, device.sync_service_id))
      |> Enum.map(&normalize_string(&1.value))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    mac_rows = Enum.filter(actual, &(&1.type == "mac"))
    universal_rows = Enum.filter(mac_rows, &canonical_universal_mac_row?/1)
    actual_by_id = Map.new(universal_rows, &{&1.id, &1.value})
    actual_ids = MapSet.new(Map.keys(actual_by_id))

    expected_ids =
      plan.survivor.row_ids
      |> Kernel.++(Enum.flat_map(plan.splits, & &1.row_ids))
      |> MapSet.new()

    cond do
      actual_snapshot != device.identifier_snapshot ->
        {:error, :source_identifier_snapshot_changed}

      length(typed_armis_rows) != 1 or hd(typed_armis_rows).value != plan.armis_device_id ->
        {:error, :ambiguous_typed_armis_identity}

      not device.tombstoned? and
          not identifier_matches_armis_source?(hd(typed_armis_rows), device.sync_service_id) ->
        {:error, :unproven_armis_identity_source}

      not is_nil(device.metadata_armis_device_id) and
          device.metadata_armis_device_id != hd(typed_armis_rows).value ->
        {:error, :armis_identity_mismatch}

      not device.tombstoned? and length(integration_ids) < 2 ->
        {:error, :missing_live_overmerge_signal}

      integration_ids != device.integration_ids ->
        {:error, :integration_identity_changed}

      Enum.any?(mac_rows, &(not canonical_mac_row?(&1))) ->
        {:error, :noncanonical_mac_identifier}

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

  defp lock_and_validate_global_mac_owners(source_uid, plan) do
    macs =
      [plan.survivor.mac | Enum.map(plan.splits, & &1.mac)]
      |> Enum.uniq()
      |> Enum.sort()

    Enum.each(macs, fn mac ->
      query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [mac])
    end)

    %{rows: canonical_identifier_owners} =
      query!(
        """
        SELECT device_id, identifier_value
        FROM platform.device_identifiers
        WHERE identifier_type = 'mac'
          AND device_id <> $1
          AND identifier_value = ANY($2::text[])
        FOR UPDATE
        """,
        [source_uid, macs]
      )

    %{rows: legacy_identifier_owners} =
      query!(
        """
        SELECT device_id, identifier_value
        FROM platform.device_identifiers
        WHERE identifier_type = 'mac'
          AND device_id <> $1
          AND identifier_value !~ '^[0-9A-F]{12}$'
          AND regexp_split_to_array(
                upper(translate(identifier_value, ':-.', '')),
                '[,;[:space:]]+'
              ) && $2::text[]
        FOR UPDATE
        """,
        [source_uid, macs]
      )

    identifier_owners = canonical_identifier_owners ++ legacy_identifier_owners

    %{rows: display_owners} =
      query!(
        """
        SELECT uid, mac
        FROM platform.ocsf_devices d
        WHERE d.uid <> $1
          AND d.mac IS NOT NULL
          AND regexp_split_to_array(
                upper(translate(d.mac, ':-.', '')),
                '[,;[:space:]]+'
              ) && $2::text[]
        FOR UPDATE
        """,
        [source_uid, macs]
      )

    %{rows: armis_owners} =
      query!(
        """
        SELECT device_id, id
        FROM platform.device_identifiers
        WHERE identifier_type = 'armis_device_id'
          AND identifier_value = $1
          AND device_id <> $2
        FOR UPDATE
        """,
        [plan.armis_device_id, source_uid]
      )

    cond do
      armis_owners != [] -> {:error, :armis_identity_has_alternate_owner}
      identifier_owners != [] -> {:error, :split_mac_has_alternate_identifier_owner}
      display_owners != [] -> {:error, :split_mac_has_alternate_display_owner}
      true -> :ok
    end
  end

  defp lock_and_validate_targets(%{splits: []}), do: :ok

  defp lock_and_validate_targets(plan) do
    target_uids = Enum.map(plan.splits, & &1.new_uid)

    %{rows: existing_targets} =
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

    cond do
      existing_targets != [] -> {:error, :split_target_exists}
      identifier_rows != [] -> {:error, :split_target_has_universal_mac}
      true -> :ok
    end
  end

  defp apply_split(device, plan, manifest, actor) do
    candidate_token = Ecto.UUID.generate()

    with :ok <- Manifest.ensure_writable(manifest),
         :ok <- record_candidate_preflight(manifest, candidate_token, device, plan) do
      @transaction_resources
      |> Ash.transaction(fn ->
        result =
          with :ok <- lock_and_revalidate_candidate(device, plan),
               {:ok, survivor_entries} <- ensure_survivor(plan, actor),
               {:ok, _touched, touch_entries} <- touch_survivor_rows(plan, actor),
               {:ok, split_result} <- apply_all_splits(device, plan, actor),
               manifest_entries =
                 survivor_entries ++ touch_entries ++ split_result.manifest_entries,
               :ok <-
                 record_manifest_entries(
                   manifest,
                   manifest_entries,
                   candidate_token,
                   "prepared"
                 ) do
            %{
              reassigned: split_result.reassigned,
              created: split_result.created
            }
          end

        case result do
          {:error, reason} -> Ash.DataLayer.rollback(@transaction_resources, reason)
          success -> success
        end
      end)
      |> case do
        {:ok, result} ->
          case record_candidate_committed(manifest, candidate_token, device.uid) do
            :ok -> {:ok, result}
            {:error, reason} -> {:committed_manifest_error, result, reason}
          end

        {:error, reason} ->
          {:error, reason}

        {:error, reason, _stacktrace} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, {:manifest_preflight_failed, reason}}
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

  # An adopt survivor stays live but loses every split class's identifier rows in
  # apply_all_splits/3, so which identifiers it owns changes and the fence has to
  # move. Nothing else here carries that: set_device_mac/4 returns {:ok, []}
  # without touching ocsf_devices at all when the display MAC already equals the
  # survivor MAC -- the common case -- and its :update action does not bump when
  # it does write. The :restore clause below needs no equivalent, because it goes
  # through Device's :restore action, which does.
  #
  # Once per candidate, not once per reassigned row: a 40-MAC candidate would
  # otherwise fire 40 updates on one device row inside one transaction.
  defp ensure_survivor(%{survivor: %{action: :adopt, uid: uid, mac: mac}}, actor) do
    with {:ok, mac_entries} <- set_device_mac(uid, mac, actor, "survivor"),
         {:ok, bump_entries} <- bump_survivor_revision(uid, actor, "survivor") do
      {:ok, mac_entries ++ bump_entries}
    end
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
         {:ok, audit_entries} <- record_unmerge_audit(device.uid, split, plan, actor) do
      {:ok,
       %{
         reassigned: reassigned,
         created: created,
         manifest_entries: device_entries ++ identifier_entries ++ audit_entries
       }}
    end
  end

  defp ensure_split_device(split, actor) do
    create_split_device(split.new_uid, split.mac, actor)
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

  # Runs inside the candidate transaction (Device is already in
  # @transaction_resources), so the bump and the reassignments commit or roll back
  # together. A bump that outlived Ash.DataLayer.rollback/2 would claim a
  # transition that never happened.
  #
  # The single-record interface is safe here specifically because :adopt implies
  # the device is live -- a tombstoned candidate takes the :restore path -- and
  # validate_source_state/3 has already revalidated that under FOR UPDATE. It
  # targets a row this transaction already holds, so it introduces no new lock.
  defp bump_survivor_revision(uid, actor, role) do
    with {:ok, %Device{} = device} <- Device.get_by_uid(uid, false, actor: actor),
         {:ok, _bumped} <- Device.bump_identity_revision(device, actor: actor) do
      {:ok,
       manifest_entry(:bump_device_identity_revision, "platform.ocsf_devices", [uid], %{
         role: role
       })}
    else
      # get_by_uid answers {:ok, nil} for a missing or tombstoned row, which would
      # otherwise fall out of the `with` as {:ok, nil} and blow up on `++`. An
      # :adopt survivor that is not live violates an invariant this transaction
      # already checked, so fail the candidate rather than continue.
      {:error, _} = error -> error
      other -> {:error, {:identity_revision_bump_failed, uid, other}}
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
      {:ok, audit} ->
        {:ok,
         manifest_entry(:create_merge_audit, "platform.merge_audit", [audit.event_id], %{
           from_device_uid: split.new_uid,
           to_device_uid: from_uid,
           reason: "unmerge"
         })}

      {:error, _} = err ->
        err
    end
  end

  defp manifest_entry(_action, _table, [], _extra), do: []

  defp manifest_entry(action, table, ids, extra) do
    [%{action: action, table: table, ids: ids, extra: extra}]
  end

  defp record_candidate_preflight(manifest, candidate_token, device, plan) do
    assignments =
      [%{action: "retain", target_uid: plan.survivor.uid, row_ids: plan.survivor.row_ids}] ++
        Enum.map(plan.splits, fn split ->
          %{action: "create_and_reassign", target_uid: split.new_uid, row_ids: split.row_ids}
        end)

    row_ids = Enum.flat_map(assignments, & &1.row_ids)

    Manifest.record(
      manifest,
      @step,
      :candidate_preflight,
      "platform.device_identifiers",
      row_ids,
      %{
        phase: "preflight",
        candidate_token: candidate_token,
        source_uid: device.uid,
        target_uids: Enum.map(plan.splits, & &1.new_uid),
        assignments: assignments
      }
    )
  end

  defp record_manifest_entries(manifest, entries, candidate_token, phase) do
    entries =
      Enum.map(entries, fn entry ->
        %{
          entry
          | extra: Map.merge(entry.extra, %{candidate_token: candidate_token, phase: phase})
        }
      end)

    case Manifest.record_batch(manifest, @step, entries) do
      :ok -> :ok
      {:error, reason} -> {:error, {:manifest_prepare_failed, reason}}
    end
  end

  defp record_candidate_committed(manifest, candidate_token, source_uid) do
    Manifest.record(
      manifest,
      @step,
      :candidate_committed,
      "platform.ocsf_devices",
      [source_uid],
      %{
        phase: "committed",
        candidate_token: candidate_token,
        source_uid: source_uid
      }
    )
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

  defp canonical_mac_row?(%{value: value}) when is_binary(value),
    do: Regex.match?(@canonical_mac_pattern, value)

  defp canonical_mac_row?(_row), do: false

  defp canonical_universal_mac_row?(%{value: value} = row) do
    canonical_mac_row?(row) and Mac.universal_macs(value) == MapSet.new([value])
  end

  defp canonical_universal_mac_row?(_row), do: false

  # Ash wraps transaction rollback reasons in its error classes. Preserve the
  # durable-manifest failure tag through that wrapper so execution still halts.
  defp manifest_prepare_failure?({:manifest_prepare_failed, _reason}), do: true

  defp manifest_prepare_failure?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &manifest_prepare_failure?/1)

  defp manifest_prepare_failure?(%{error: error, value: value}),
    do: manifest_prepare_failure?(error) or manifest_prepare_failure?(value)

  defp manifest_prepare_failure?(%{error: error}), do: manifest_prepare_failure?(error)
  defp manifest_prepare_failure?(%{value: value}), do: manifest_prepare_failure?(value)

  defp manifest_prepare_failure?(errors) when is_list(errors),
    do: Enum.any?(errors, &manifest_prepare_failure?/1)

  defp manifest_prepare_failure?(_error), do: false

  defp database_timeout_exception?(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    postgres[:code] in [:lock_not_available, :query_canceled] or
      postgres[:pg_code] in ["55P03", "57014"]
  end

  defp database_timeout_exception?(%DBConnection.ConnectionError{} = error) do
    Regex.match?(~r/\b(?:timeout|timed out)\b/i, Exception.message(error))
  end

  defp database_timeout_reason(%Postgrex.Error{postgres: postgres} = error) do
    %{
      kind: :postgres,
      code: postgres[:code] || postgres[:pg_code],
      message: Exception.message(error)
    }
  end

  defp database_timeout_reason(%DBConnection.ConnectionError{} = error) do
    %{kind: :connection, message: Exception.message(error)}
  end

  defp sum_by(list, fun), do: list |> Enum.map(fun) |> Enum.sum()

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

  defp canonical_partition(value) when is_binary(value) do
    if value != "" and String.trim(value) == value, do: value
  end

  defp canonical_partition(_value), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_values), do: []

  defp identifier_matches_armis_source?(row, source_id) when is_binary(source_id) do
    row[:source_id] == source_id and row[:integration_type] == "armis"
  end

  defp identifier_matches_armis_source?(_row, _source_id), do: false

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
