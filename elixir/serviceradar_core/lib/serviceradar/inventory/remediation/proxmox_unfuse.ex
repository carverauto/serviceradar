defmodule ServiceRadar.Inventory.Remediation.ProxmoxUnfuse do
  @moduledoc """
  Step `proxmox-unfuse` — disposition of the Proxmox cross-cluster over-merge
  (GitHub #4051).

  Before the name-key guard existed, resolve-time lookups on legacy
  name-keyed bridges (`proxmox:vm:<name>`, `proxmox:container:<name>`,
  `proxmox:hypervisor:<node>`) collapsed updates from different Proxmox
  clusters onto one row, which then accumulated every cluster's
  `proxmox:v2:<cluster>:<kind>:<ref>` identifiers. That collapse happened at
  resolve time, not via `merge_devices`, so there is no reversible
  `merge_audit` — the split grouping is reconstructed from current state (the
  cluster segment of the registered v2 rows), planned by the pure
  `Decisions.plan_proxmox_unfuse/3`.

  Per candidate: the earliest-registered cluster keeps the existing device;
  every other cluster gets a fresh device and receives that cluster's v2
  identifier rows plus its source-attributed MAC rows via the audited,
  TTL-resetting `DeviceIdentifier :reassign_device`. One `merge_audit`
  `reason: "unmerge"` row per split arms the symmetric per-pair re-collapse
  cooldown. A synced write-ahead manifest records every candidate and
  mutation.

  MAC placement is fail-closed: a MAC row moves only when its registration
  provenance (`metadata.sync_service_id`) matches exactly one cluster
  group's sources. Anything unattributable skips the whole candidate — a MAC
  left on the survivor while its cluster moves away re-fires the
  cross-device conflict on the next sync and re-fuses past the cooldown. The
  dry-run report lists every MAC assignment (value and source per cluster)
  so the operator verifies attribution against the live clusters before
  allowlisting.

  NOTE (faker / demo): cluster-span detection is not a reliable over-merge
  signal on faker-heavy data. This step is registered dormant — dry-run
  runnable, but excluded from the default execute order. Execution is also
  disabled inside this module unless `:proxmox_unfuse_execute_enabled` is
  true. Live candidates additionally require `:proxmox_unfuse_include_live`,
  membership in `:proxmox_unfuse_live_device_uids`, and membership of their
  sync source in `:proxmox_unfuse_live_source_ids`. Recognized faker sources
  are never eligible.
  """

  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.Inventory.Remediation.Decisions
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Ash.Query
  require Logger

  @step "proxmox-unfuse"
  @default_plan_sample_limit 50
  @default_dry_run_candidate_limit 5_000
  @default_execute_candidate_limit 25
  @transaction_resources [Device, DeviceIdentifier, MergeAudit]

  # Atomic stored MAC identifier rows (uppercase, no separators — the
  # canonical `DeviceIdentifier` MAC format). Locally-administered and
  # universal alike: placement is decided by registration provenance, not by
  # the local bit.
  @atomic_mac_pattern ~r/^[0-9A-F]{12}$/

  @doc false
  def run(mode, opts, manifest, actor) do
    sample_limit =
      Keyword.get(opts, :proxmox_unfuse_plan_sample_limit, @default_plan_sample_limit)

    default_candidate_limit =
      if mode == :execute,
        do: @default_execute_candidate_limit,
        else: @default_dry_run_candidate_limit

    candidate_limit = Keyword.get(opts, :proxmox_unfuse_candidate_limit, default_candidate_limit)

    devices = detect_candidates(candidate_limit, mode, opts)

    planned =
      Enum.map(devices, fn device ->
        {device, Decisions.plan_proxmox_unfuse(device, device.v2_rows, device.mac_rows)}
      end)

    splits = for {device, {:split, plan}} <- planned, do: {device, plan}
    skips = for {device, {:skip, reason}} <- planned, do: {device, to_string(reason)}

    skipped_counts =
      skips
      |> Enum.map(&elem(&1, 1))
      |> Enum.frequencies()

    skipped_device_sample =
      skips
      |> Enum.sort_by(fn {device, reason} -> {reason, device.uid} end)
      |> Enum.map(fn {device, reason} -> %{device_uid: device.uid, reason: reason} end)
      |> Enum.take(sample_limit)

    execution_splits = execution_splits(splits, opts)

    base = %{
      candidate_devices: length(devices),
      cluster_count_distribution:
        devices
        |> Enum.map(&length(&1.clusters))
        |> Enum.frequencies()
        |> Map.new(fn {count, frequency} -> {to_string(count), frequency} end),
      detected_planned_splits: length(splits),
      detected_split_plan: splits |> Enum.take(sample_limit) |> Enum.map(&plan_sample(&1, opts)),
      planned_splits: length(execution_splits),
      planned_new_devices: sum_by(execution_splits, fn {_d, p} -> length(p.splits) end),
      planned_identifier_reassignments:
        sum_by(execution_splits, fn {_d, p} ->
          sum_by(p.splits, &(length(&1.row_ids) + length(&1.mac_row_ids)))
        end),
      skipped: skipped_counts,
      skipped_device_sample: skipped_device_sample
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
        if execute_enabled?(opts) do
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
        else
          blocked_execution_report(base, :proxmox_unfuse_execute_disabled)
        end
    end
  end

  # -- detection ------------------------------------------------------------

  defp detect_candidates(limit, mode, opts) do
    {scope_filter, order_by, scope_params} = detection_scope(mode, opts)

    %{rows: rows} =
      query!(
        """
        WITH clustered AS (
          SELECT device_id,
                 split_part(identifier_value, ':', 3) AS cluster
          FROM platform.device_identifiers
          WHERE identifier_type = 'integration_id'
            AND identifier_value LIKE 'proxmox:v2:%'
          GROUP BY device_id, split_part(identifier_value, ':', 3)
        ),
        fused AS (
          SELECT device_id
          FROM clustered
          GROUP BY device_id
          HAVING count(*) > 1
        )
        SELECT d.uid,
               d.hostname,
               d.partition,
               (d.deleted_at IS NOT NULL) AS tombstoned,
               d.deleted_reason,
               NULLIF(d.metadata->>'sync_service_id', '') AS sync_service_id,
               NULLIF(d.metadata->>'integration_type', '') AS integration_type,
               COALESCE(d.discovery_sources, ARRAY[]::text[]) AS discovery_sources,
               src.source_type::text,
               src.name,
               src.endpoint,
               (SELECT count(*) FROM clustered c WHERE c.device_id = d.uid) AS cluster_count,
               (SELECT array_agg(c.cluster ORDER BY c.cluster) FROM clustered c WHERE c.device_id = d.uid) AS clusters
        FROM platform.ocsf_devices d
        JOIN fused f ON f.device_id = d.uid
        LEFT JOIN platform.integration_sources src
          ON src.id::text = NULLIF(d.metadata->>'sync_service_id', '')
        WHERE d.deleted_at IS NULL
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
                        hostname,
                        partition,
                        tombstoned,
                        deleted_reason,
                        sync_service_id,
                        integration_type,
                        discovery_sources,
                        source_type,
                        source_name,
                        source_endpoint,
                        _cluster_count,
                        clusters
                      ] ->
      identifier_rows = Map.get(identifier_rows_by_device, uid, [])

      {v2_rows, unparsed_v2_rows} =
        identifier_rows
        |> Enum.filter(
          &(&1.type == "integration_id" and String.starts_with?(&1.value, "proxmox:v2:"))
        )
        |> Enum.split_with(&(IntegrationIdentity.parse_v2(&1.value) != :error))

      mac_rows =
        Enum.filter(identifier_rows, fn row ->
          row.type == "mac" and Regex.match?(@atomic_mac_pattern, row.value)
        end)

      %{
        uid: uid,
        hostname: normalize_string(hostname),
        partition: normalize_string(partition) || "default",
        tombstoned?: tombstoned,
        deleted_reason: normalize_string(deleted_reason),
        sync_service_id: normalize_string(sync_service_id),
        integration_type: normalize_string(integration_type),
        discovery_sources: normalize_string_list(discovery_sources),
        source_type: normalize_string(source_type),
        source_name: normalize_string(source_name),
        source_endpoint: normalize_string(source_endpoint),
        faker_source?:
          faker_hostname?(hostname) or faker_text?(source_name) or
            faker_endpoint?(source_endpoint),
        clusters: clusters || [],
        unparsed_v2_row_count: length(unparsed_v2_rows),
        v2_rows: v2_rows,
        mac_rows: mac_rows
      }
    end)
  end

  # Execute detection scopes by explicit device allowlist plus the faker
  # guard only. Source safety lives in `execution_exclusion_reason/2`, which
  # requires every v2/MAC row's registration provenance to be allowlisted: a
  # fused device spans sources by definition, so its device-level
  # `sync_service_id` (last writer wins) cannot gate row moves.
  defp detection_scope(:execute, opts) do
    include_live? = Keyword.get(opts, :proxmox_unfuse_include_live, false)
    device_uids = allowlist_values(opts, :proxmox_unfuse_live_device_uids, include_live?)

    filter = """
    AND (
      d.uid = ANY($2::text[])
      AND upper(COALESCE(d.hostname, '')) NOT LIKE 'FAKER-%'
      AND lower(COALESCE(src.name, '')) NOT LIKE '%faker%'
      AND lower(COALESCE(src.endpoint, '')) NOT LIKE '%serviceradar-faker%'
    )
    """

    {filter, "d.uid", [device_uids]}
  end

  defp detection_scope(:dry_run, opts) do
    device_uids = allowlist_values(opts, :proxmox_unfuse_live_device_uids, true)

    if Keyword.get(opts, :proxmox_unfuse_include_live, false) and device_uids != [] do
      {"", "CASE WHEN d.uid = ANY($2::text[]) THEN 0 ELSE 1 END, d.uid", [device_uids]}
    else
      {"", "d.uid", []}
    end
  end

  defp detection_scope(_mode, _opts), do: {"", "d.uid", []}

  defp allowlist_values(opts, key, true) do
    opts
    |> Keyword.get(key, [])
    |> normalize_allowlist()
    |> MapSet.to_list()
  end

  defp allowlist_values(_opts, _key, false), do: []

  defp execute_enabled?(opts) do
    runtime_enabled? =
      :serviceradar_core
      |> Application.get_env(ServiceRadar.Inventory.Remediation.DireRemediation, [])
      |> Keyword.get(:enable_proxmox_unfuse_execute, false)

    runtime_enabled? and Keyword.get(opts, :proxmox_unfuse_execute_enabled, false)
  end

  defp load_candidate_identifier_rows([]), do: %{}

  defp load_candidate_identifier_rows(uids) do
    %{rows: rows} =
      query!(
        """
        SELECT id, device_id, identifier_type::text, identifier_value, partition,
               first_seen,
               NULLIF(metadata->>'sync_service_id', '')
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
       Enum.map(device_rows, fn [id, _dev, type, value, partition, first_seen, source_id] ->
         %{
           id: id,
           type: type,
           value: value,
           partition: partition,
           first_seen: first_seen,
           source_id: normalize_string(source_id)
         }
       end)}
    end)
  end

  defp execution_splits(splits, opts) do
    Enum.filter(splits, &is_nil(execution_exclusion_reason(&1, opts)))
  end

  defp execution_exclusion_reason({device, _plan}, opts) do
    include_live? = Keyword.get(opts, :proxmox_unfuse_include_live, false)

    allowed_device_uids =
      opts
      |> Keyword.get(:proxmox_unfuse_live_device_uids, [])
      |> normalize_allowlist()

    allowed_source_ids =
      opts
      |> Keyword.get(:proxmox_unfuse_live_source_ids, [])
      |> normalize_allowlist()

    # Source gating is row-unanimous, not device-level: a fused device spans
    # clusters by definition, and its row metadata carries each cluster's own
    # registration provenance. Every v2 and MAC row that would move must come
    # from an allowlisted sync source; a row with missing or foreign
    # provenance excludes the whole candidate fail-closed.
    row_sources =
      (device.v2_rows ++ device.mac_rows)
      |> Enum.map(& &1[:source_id])
      |> Enum.uniq()

    cond do
      not include_live? -> :live_execution_not_enabled
      device.faker_source? -> :faker_source_forbidden
      not MapSet.member?(allowed_device_uids, device.uid) -> :device_not_allowlisted
      not unanimous_sources?(row_sources, allowed_source_ids) -> :source_not_allowlisted
      true -> nil
    end
  end

  defp unanimous_sources?([], _allowed), do: true

  defp unanimous_sources?(sources, allowed) do
    Enum.all?(sources, &MapSet.member?(allowed, &1))
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
              "ProxmoxUnfuse: manifest preflight for #{device.uid} failed: #{inspect(error)}"
            )

            {:halt, {applied, failed + 1, reassigns, created, manifest_failures + 1}}

          {:committed_manifest_error, %{reassigned: r, created: c}, error} ->
            Logger.error(
              "ProxmoxUnfuse: split of #{device.uid} committed but manifest marker failed: #{inspect(error)}"
            )

            {:halt, {applied + 1, failed + 1, reassigns + r, created + c, manifest_failures + 1}}

          {:error, {:manifest_prepare_failed, error}} ->
            Logger.warning(
              "ProxmoxUnfuse: prepared manifest for #{device.uid} failed: #{inspect(error)}"
            )

            {:halt, {applied, failed + 1, reassigns, created, manifest_failures + 1}}

          {:error, error} ->
            if manifest_prepare_failure?(error) do
              Logger.warning(
                "ProxmoxUnfuse: prepared manifest for #{device.uid} failed: #{inspect(error)}"
              )

              {:halt, {applied, failed + 1, reassigns, created, manifest_failures + 1}}
            else
              Logger.warning("ProxmoxUnfuse: split of #{device.uid} failed: #{inspect(error)}")
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

        Logger.warning("ProxmoxUnfuse: database timeout for #{device.uid}: #{inspect(reason)}")

        {:error, {:database_timeout, reason}}
      else
        reraise error, __STACKTRACE__
      end
  catch
    :exit, {:timeout, _detail} = reason ->
      Logger.warning(
        "ProxmoxUnfuse: database operation for #{device.uid} exited on timeout: #{inspect(reason)}"
      )

      {:error, {:database_timeout, %{kind: :exit, reason: inspect(reason)}}}

    kind, reason ->
      Logger.error(
        "ProxmoxUnfuse: unexpected #{kind} while applying #{device.uid}: #{inspect(reason)}"
      )

      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp apply_split(device, plan, manifest, actor) do
    candidate_token = Ecto.UUID.generate()

    with :ok <- Manifest.ensure_writable(manifest),
         :ok <- record_candidate_preflight(manifest, candidate_token, device, plan) do
      @transaction_resources
      |> Ash.transaction(fn ->
        result =
          with :ok <- lock_and_revalidate_candidate(device, plan),
               {:ok, bump_entries} <- bump_survivor_revision(plan, actor),
               {:ok, split_result} <- apply_all_splits(device, plan, actor),
               manifest_entries = bump_entries ++ split_result.manifest_entries,
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

  defp apply_one_split(device, plan, split, actor) do
    row_ids = split.row_ids ++ split.mac_row_ids

    with {:ok, created, device_entries} <- ensure_split_device(device, plan, split, actor),
         {:ok, reassigned, identifier_entries} <- reassign_rows(row_ids, split.new_uid, actor),
         {:ok, audit_entries} <- record_unmerge_audit(device.uid, split, plan, actor) do
      {:ok,
       %{
         reassigned: reassigned,
         created: created,
         manifest_entries: device_entries ++ identifier_entries ++ audit_entries
       }}
    end
  end

  defp ensure_split_device(device, plan, split, actor) do
    params = maybe_put_hostname(%{uid: split.new_uid, partition: plan.partition}, device.hostname)

    case Device
         |> Ash.Changeset.for_create(:create, params)
         |> Ash.create(actor: actor) do
      {:ok, created} ->
        entries =
          manifest_entry(:create_device, "platform.ocsf_devices", [created.uid], %{
            role: "split",
            cluster: split.cluster
          })

        {:ok, 1, entries}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_put_hostname(params, hostname) when is_binary(hostname) do
    if String.trim(hostname) == "", do: params, else: Map.put(params, :hostname, hostname)
  end

  defp maybe_put_hostname(params, _hostname), do: params

  # The survivor loses identifier rows, so its composition changed: bump the
  # identity revision inside the candidate transaction (a bump that outlived
  # rollback would claim a transition that never happened).
  defp bump_survivor_revision(plan, actor) do
    with {:ok, %Device{} = device} <- Device.get_by_uid(plan.survivor.uid, false, actor: actor),
         {:ok, _bumped} <- Device.bump_identity_revision(device, actor: actor) do
      {:ok,
       manifest_entry(
         :bump_device_identity_revision,
         "platform.ocsf_devices",
         [plan.survivor.uid],
         %{
           role: "survivor",
           cluster: plan.survivor.cluster
         }
       )}
    else
      {:error, _} = error -> error
      other -> {:error, {:identity_revision_bump_failed, plan.survivor.uid, other}}
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

  defp record_unmerge_audit(from_uid, split, _plan, actor) do
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
               cluster: split.cluster,
               v2_values: split.v2_values
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

  # -- revalidation ---------------------------------------------------------

  defp lock_and_revalidate_candidate(device, plan) do
    with :ok <- validate_plan_shape(device, plan),
         :ok <- acquire_owner_mutation_barrier(),
         {:ok, current_device} <- lock_source_device(device.uid),
         :ok <- validate_source_state(device, plan, current_device),
         :ok <- lock_and_validate_identifier_ownership(device, plan) do
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
    row_ids = plan.survivor.row_ids ++ Enum.flat_map(plan.splits, &(&1.row_ids ++ &1.mac_row_ids))

    cond do
      plan.device_uid != device.uid or plan.survivor.uid != device.uid ->
        {:error, :stale_source_device}

      Enum.any?(split_uids, &(&1 == device.uid)) ->
        {:error, :self_target_split}

      length(split_uids) != length(Enum.uniq(split_uids)) ->
        {:error, :duplicate_split_target}

      length(row_ids) != length(Enum.uniq(row_ids)) ->
        {:error, :duplicate_identifier_assignment}

      device.partition != plan.partition ->
        {:error, :source_partition_mismatch}

      true ->
        :ok
    end
  end

  defp lock_source_device(uid) do
    %{rows: rows} =
      query!(
        """
        SELECT (deleted_at IS NOT NULL), deleted_reason, hostname, partition,
               NULLIF(metadata->>'sync_service_id', '')
        FROM platform.ocsf_devices
        WHERE uid = $1
        FOR UPDATE
        """,
        [uid]
      )

    case rows do
      [[tombstoned, deleted_reason, hostname, partition, sync_service_id]] ->
        {:ok,
         %{
           tombstoned?: tombstoned,
           deleted_reason: normalize_string(deleted_reason),
           hostname: normalize_string(hostname),
           partition: normalize_string(partition),
           sync_service_id: normalize_string(sync_service_id)
         }}

      _ ->
        {:error, :source_device_missing}
    end
  end

  defp validate_source_state(device, plan, current) do
    cond do
      current.tombstoned? ->
        {:error, :source_device_tombstoned}

      current.deleted_reason != device.deleted_reason ->
        {:error, :source_deleted_reason_changed}

      current.partition != plan.partition ->
        {:error, :source_partition_mismatch}

      true ->
        :ok
    end
  end

  defp lock_and_validate_identifier_ownership(device, plan) do
    expected =
      Enum.sort(
        plan.survivor.row_ids ++ Enum.flat_map(plan.splits, &(&1.row_ids ++ &1.mac_row_ids))
      )

    %{rows: rows} =
      query!(
        """
        SELECT id, identifier_value, partition
        FROM platform.device_identifiers
        WHERE id = ANY($1::bigint[])
          AND device_id = $2
        FOR UPDATE
        """,
        [expected, device.uid]
      )

    owned =
      rows
      |> Enum.map(fn [id, _value, _partition] -> id end)
      |> Enum.sort()

    if owned == expected, do: :ok, else: {:error, :identifier_ownership_changed}
  end

  defp lock_and_validate_targets(plan) do
    target_uids = Enum.map(plan.splits, & &1.new_uid)

    %{rows: [[device_count]]} =
      query!("SELECT count(*) FROM platform.ocsf_devices WHERE uid = ANY($1::text[])", [
        target_uids
      ])

    %{rows: [[identifier_count]]} =
      query!(
        "SELECT count(*) FROM platform.device_identifiers WHERE device_id = ANY($1::text[])",
        [
          target_uids
        ]
      )

    cond do
      count_to_integer(device_count) != 0 -> {:error, :split_target_device_exists}
      count_to_integer(identifier_count) != 0 -> {:error, :split_target_identifiers_exist}
      true -> :ok
    end
  end

  # -- manifest -------------------------------------------------------------

  defp manifest_entry(_action, _table, [], _extra), do: []

  defp manifest_entry(action, table, ids, extra) do
    [%{action: action, table: table, ids: ids, extra: extra}]
  end

  defp record_candidate_preflight(manifest, candidate_token, device, plan) do
    assignments =
      [%{action: "retain", target_uid: plan.survivor.uid, row_ids: plan.survivor.row_ids}] ++
        Enum.map(plan.splits, fn split ->
          %{
            action: "create_and_reassign",
            target_uid: split.new_uid,
            row_ids: split.row_ids ++ split.mac_row_ids
          }
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
    mac_values = mac_values_by_id(device)

    %{
      device_uid: device.uid,
      hostname: device.hostname,
      clusters: device.clusters,
      unparsed_v2_row_count: device.unparsed_v2_row_count,
      sync_service_id: device.sync_service_id,
      faker_source: device.faker_source?,
      execution_eligible: is_nil(exclusion_reason),
      execution_exclusion_reason: exclusion_reason && to_string(exclusion_reason),
      survivor_cluster: plan.survivor.cluster,
      new_device_count: length(plan.splits),
      new_devices:
        Enum.map(plan.splits, fn s ->
          %{
            cluster: s.cluster,
            uid: s.new_uid,
            v2_values: s.v2_values,
            identifiers: length(s.row_ids) + length(s.mac_row_ids),
            macs: Enum.map(s.mac_row_ids, &Map.get(mac_values, &1))
          }
        end)
    }
  end

  defp mac_values_by_id(device) do
    Map.new(device.mac_rows, &{&1.id, %{value: &1.value, source_id: &1.source_id}})
  end

  # -- helpers --------------------------------------------------------------

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

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_values), do: []

  defp faker_hostname?(hostname) when is_binary(hostname),
    do: hostname |> String.upcase() |> String.starts_with?("FAKER-")

  defp faker_hostname?(_hostname), do: false

  defp faker_text?(value) when is_binary(value),
    do: value |> String.downcase() |> String.contains?("faker")

  defp faker_text?(_value), do: false

  defp faker_endpoint?(value) when is_binary(value),
    do: value |> String.downcase() |> String.contains?("serviceradar-faker")

  defp faker_endpoint?(_value), do: false

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

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
