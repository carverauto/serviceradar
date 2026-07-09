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
  MAC (`Decisions.plan_armis_unmerge/2` — co-occurrence provenance is lost, so
  multi-NIC hosts are conservatively over-split and the standing veto
  re-consolidates them on next ingest). The **survivor** class keeps the existing
  device (adopting a live one, restoring a tombstoned ghost) and its
  `armis_device_id`; every other class gets a fresh device with the deterministic
  UID a veto-gated ingest would mint and receives that class's MAC identifier rows
  via the audited, TTL-resetting `DeviceIdentifier :reassign_device` — which is
  simultaneously the reassign-before-delete rescue for the ~389k sole-copy MAC
  rows orphaned onto `armis_source_device_id_ghost_cleanup` tombstones.

  Two candidate populations:

    * live Armis-keyed devices with >= 2 distinct universal MACs (over-merged), and
    * ghost tombstones (`deleted_reason = 'armis_source_device_id_ghost_cleanup'`)
      holding any universal MAC (orphaned hardware to re-home).

  Idempotent (re-runs converge: a split device drops to one universal MAC and is
  no longer a candidate), dry-run by default, and every mutation is
  `Manifest.record`ed. One `merge_audit` `reason: "unmerge"` row per split arms
  the per-pair re-collapse cooldown.

  NOTE (faker / demo): distinct-MAC count is not a reliable over-merge signal on
  faker-heavy data (the demo faker mints many MACs per device by design). This
  step is registered dormant — dry-run runnable, but excluded from the default
  execute order — until the live scoping (proposal Task 1) confirms the
  population and excludes the faker fleet.
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

    devices = detect_candidates(candidate_limit)

    planned =
      Enum.map(devices, fn device ->
        {device, Decisions.plan_armis_unmerge(device, device.mac_rows)}
      end)

    splits = for {device, {:split, plan}} <- planned, do: {device, plan}
    skips = for {_device, {:skip, reason}} <- planned, do: to_string(reason)

    base = %{
      candidate_devices: length(devices),
      planned_splits: length(splits),
      planned_new_devices: sum_by(splits, fn {_d, p} -> length(p.splits) end),
      planned_identifier_reassignments:
        sum_by(splits, fn {_d, p} -> sum_by(p.splits, &length(&1.row_ids)) end),
      skipped: Enum.frequencies(skips),
      split_plan: splits |> Enum.take(sample_limit) |> Enum.map(&plan_sample/1)
    }

    case mode do
      :dry_run ->
        base

      :execute ->
        {applied, failed, reassigned, created} = execute_splits(splits, manifest, actor)

        Map.merge(base, %{
          applied_splits: applied,
          split_failures: failed,
          applied_new_devices: created,
          applied_identifier_reassignments: reassigned
        })
    end
  end

  # -- detection ------------------------------------------------------------

  defp detect_candidates(limit) do
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
               universal.n AS universal_mac_count
        FROM platform.ocsf_devices d
        JOIN universal ON universal.device_id = d.uid
        LEFT JOIN LATERAL (
          SELECT identifier_value
          FROM platform.device_identifiers
          WHERE device_id = d.uid AND identifier_type = 'armis_device_id'
          LIMIT 1
        ) di ON true
        WHERE (
          d.deleted_at IS NULL
          AND ('armis' = ANY(d.discovery_sources)
               OR COALESCE(d.metadata->>'integration_type', '') = 'armis')
          AND universal.n >= 2
        )
        OR (d.deleted_reason = 'armis_source_device_id_ghost_cleanup' AND universal.n >= 1)
        ORDER BY universal.n DESC, d.uid
        LIMIT $1
        """,
        [limit]
      )

    uids = Enum.map(rows, fn [uid | _] -> uid end)
    mac_rows_by_device = load_universal_mac_rows(uids)

    Enum.map(rows, fn [uid, armis_id, device_mac, tombstoned, _n] ->
      mac_rows = Map.get(mac_rows_by_device, uid, [])

      %{
        uid: uid,
        mac: device_mac,
        armis_device_id: normalize_string(armis_id),
        partition: dominant_partition(mac_rows),
        tombstoned?: tombstoned,
        mac_rows: Enum.map(mac_rows, &Map.take(&1, [:id, :value, :last_seen]))
      }
    end)
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

  # No wrapping transaction: every op is deterministic and idempotent (a split
  # device drops to one universal MAC and stops being a candidate), so a partial
  # failure is recovered by re-running — matching the other remediation steps.
  defp apply_split(device, plan, manifest, actor) do
    with :ok <- ensure_survivor(plan, manifest, actor),
         {:ok, _touched} <- touch_survivor_rows(plan, manifest, actor) do
      Enum.reduce_while(plan.splits, {:ok, %{reassigned: 0, created: 0}}, fn split, {:ok, acc} ->
        case apply_one_split(device, plan, split, manifest, actor) do
          {:ok, c} ->
            {:cont,
             {:ok, %{reassigned: acc.reassigned + c.reassigned, created: acc.created + c.created}}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
    end
  end

  defp ensure_survivor(%{survivor: %{action: :adopt}}, _manifest, _actor), do: :ok

  defp ensure_survivor(%{survivor: %{action: :restore, uid: uid}}, manifest, actor) do
    restore_device(uid, manifest, actor, "survivor")
  end

  # Survivor-class rows are not reassigned, so they get no :reassign_device
  # last_seen bump. Touch them so their TTL clock resets with the disposition —
  # a restored ghost's sole-copy MAC would otherwise be GC-eligible the moment
  # :restore nulls the deleted_reason guard while last_seen stays pinned to the
  # cleanup date.
  defp touch_survivor_rows(%{survivor: %{row_ids: []}}, _manifest, _actor), do: {:ok, 0}

  defp touch_survivor_rows(%{survivor: %{uid: uid, row_ids: row_ids}}, manifest, actor) do
    with {:ok, identifiers} <- load_identifiers(row_ids, actor),
         {:ok, touched} <- do_touch(identifiers, actor) do
      if touched != [] do
        Manifest.record(
          manifest,
          @step,
          :touch_identifier,
          "platform.device_identifiers",
          touched,
          %{device_uid: uid, role: "survivor"}
        )
      end

      {:ok, length(touched)}
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

  defp apply_one_split(device, plan, split, manifest, actor) do
    with {:ok, created} <- ensure_split_device(split, plan, manifest, actor),
         {:ok, reassigned} <- reassign_rows(split.row_ids, split.new_uid, manifest, actor),
         :ok <- record_unmerge_audit(device.uid, split, plan, actor) do
      {:ok, %{reassigned: reassigned, created: created}}
    end
  end

  defp ensure_split_device(split, _plan, manifest, actor) do
    case load_device_state(split.new_uid) do
      :live ->
        {:ok, 0}

      :tombstoned ->
        with :ok <- restore_device(split.new_uid, manifest, actor, "split"), do: {:ok, 0}

      :absent ->
        create_split_device(split.new_uid, manifest, actor)
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

  defp restore_device(uid, manifest, actor, role) do
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
        Manifest.record(manifest, @step, :restore_device, "platform.ocsf_devices", [uid], %{
          role: role
        })

        :ok

      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  defp create_split_device(uid, manifest, actor) do
    case Device |> Ash.Changeset.for_create(:create, %{uid: uid}) |> Ash.create(actor: actor) do
      {:ok, device} ->
        Manifest.record(manifest, @step, :create_device, "platform.ocsf_devices", [device.uid], %{
          role: "split"
        })

        {:ok, 1}

      {:error, _} = err ->
        err
    end
  end

  defp reassign_rows([], _target, _manifest, _actor), do: {:ok, 0}

  defp reassign_rows(row_ids, target_uid, manifest, actor) do
    with {:ok, identifiers} <- load_identifiers(row_ids, actor),
         {:ok, moved} <- do_reassign(identifiers, target_uid, actor) do
      if moved != [] do
        Manifest.record(
          manifest,
          @step,
          :reassign_identifier,
          "platform.device_identifiers",
          moved,
          %{to: target_uid}
        )
      end

      {:ok, length(moved)}
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
             from_device_id: from_uid,
             to_device_id: split.new_uid,
             reason: "unmerge",
             source: "dire_remediation",
             details: %{step: @step, armis_device_id: plan.armis_device_id, mac: split.mac}
           },
           actor: actor
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # -- report ---------------------------------------------------------------

  defp plan_sample({device, plan}) do
    %{
      device_uid: device.uid,
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

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
