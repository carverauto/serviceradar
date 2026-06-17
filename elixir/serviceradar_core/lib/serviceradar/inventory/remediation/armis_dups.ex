defmodule ServiceRadar.Inventory.Remediation.ArmisDups do
  @moduledoc """
  Collapses Armis duplicate device rows created when sync batches carried
  the same real Armis identity (`metadata.armis_device_id` or an
  `armis_device_id` row in `device_identifiers`).

  Legacy Armis rows that only carry `source_device_id` / generic
  `integration_id` are intentionally reported but not merged here. Live data has
  shown `source_device_id` is not a one-to-one Armis object key, so using it as a
  merge key can collapse unrelated devices.
  """

  import Ecto.Query

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Remediation.Manifest
  alias ServiceRadar.Repo

  require Logger

  @step "armis-dups"
  @merge_reason "manual_remediation"
  @sample_limit 50

  @doc false
  def run(mode, opts, manifest, actor) do
    sample_limit = Keyword.get(opts, :armis_plan_sample_limit, @sample_limit)
    soft_delete_batch_size = Keyword.get(opts, :armis_soft_delete_batch_size, 5_000)
    plan = build_plan()

    base = %{
      armis_device_groups: map_size(plan.canonical_by_armis_id),
      duplicate_rows: length(plan.duplicates),
      planned_merges: length(plan.duplicates),
      identifier_repairs: length(plan.identifier_repairs),
      legacy_unkeyed_rows: plan.legacy_unkeyed_rows,
      legacy_orphan_rows: length(plan.legacy_orphans),
      planned_soft_deletes: length(plan.legacy_orphans),
      merge_plan: Enum.take(Enum.map(plan.duplicates, &merge_plan_entry/1), sample_limit),
      soft_delete_plan:
        Enum.take(Enum.map(plan.legacy_orphans, &legacy_orphan_plan_entry/1), sample_limit),
      identifier_repair_plan:
        Enum.take(
          Enum.map(plan.identifier_repairs, &identifier_repair_plan_entry/1),
          sample_limit
        ),
      merge_plan_sample_limit: sample_limit
    }

    case mode do
      :dry_run ->
        base

      :execute ->
        {repaired, repair_failed} = execute_identifier_repairs(plan.identifier_repairs, manifest)
        {merged, merge_failed} = execute_merges(plan.duplicates, manifest, actor)

        {soft_deleted, soft_delete_failed} =
          soft_delete_legacy_orphans(
            plan.legacy_orphans,
            soft_delete_batch_size,
            manifest,
            actor
          )

        Map.merge(base, %{
          repaired_identifiers: repaired,
          identifier_repair_failures: repair_failed,
          merged: merged,
          merge_failures: merge_failed,
          soft_deleted_legacy_orphans: soft_deleted,
          soft_delete_failures: soft_delete_failed
        })
    end
  end

  defp build_plan do
    ranked_rows = ranked_armis_rows()
    canonical_by_armis_id = canonical_by_armis_id(ranked_rows)

    duplicates =
      ranked_rows
      |> Enum.reject(&(&1.rank == 1))
      |> Enum.map(fn row ->
        Map.put(row, :canonical_uid, canonical_by_armis_id[row.armis_device_id])
      end)
      |> Enum.reject(&is_nil(&1.canonical_uid))

    %{
      canonical_by_armis_id: canonical_by_armis_id,
      duplicates: duplicates,
      identifier_repairs: identifier_repairs(canonical_by_armis_id),
      legacy_unkeyed_rows: legacy_unkeyed_rows(),
      legacy_orphans: legacy_orphan_rows()
    }
  end

  defp ranked_armis_rows do
    %{rows: rows} =
      query!(
        """
        WITH protected AS (
          SELECT DISTINCT device_uid
          FROM platform.ocsf_agents
          WHERE device_uid IS NOT NULL
            AND status IN ('connected', 'connecting', 'degraded')
        ),
        armis_rows AS (
          SELECT DISTINCT ON (d.uid, COALESCE(NULLIF(d.metadata->>'armis_device_id', ''), di.identifier_value))
            d.uid,
            COALESCE(NULLIF(d.metadata->>'armis_device_id', ''), di.identifier_value) AS armis_device_id,
            d.hostname,
            d.ip,
            d.created_time,
            d.last_seen_time
          FROM platform.ocsf_devices d
          LEFT JOIN platform.device_identifiers di
            ON di.device_id = d.uid
           AND di.identifier_type = 'armis_device_id'
          WHERE d.deleted_at IS NULL
            AND (
              'armis' = ANY(d.discovery_sources)
              OR COALESCE(d.metadata->>'integration_type', '') = 'armis'
            )
            AND COALESCE(NULLIF(d.metadata->>'armis_device_id', ''), di.identifier_value) IS NOT NULL
        )
        SELECT
          r.uid,
          r.armis_device_id,
          r.hostname,
          r.ip,
          r.created_time,
          r.last_seen_time,
          ROW_NUMBER() OVER (
            PARTITION BY r.armis_device_id
            ORDER BY
              CASE WHEN p.device_uid IS NOT NULL THEN 0 ELSE 1 END,
              CASE WHEN NULLIF(r.ip, '') IS NOT NULL THEN 0 ELSE 1 END,
              r.last_seen_time DESC NULLS LAST,
              r.created_time ASC NULLS LAST,
              r.uid ASC
          ) AS rank
        FROM armis_rows r
        LEFT JOIN protected p ON p.device_uid = r.uid
        ORDER BY r.armis_device_id, rank
        """,
        []
      )

    Enum.map(rows, fn [uid, armis_device_id, hostname, ip, created, last_seen, rank] ->
      %{
        uid: uid,
        armis_device_id: armis_device_id,
        hostname: hostname,
        ip: ip,
        created_time: to_datetime(created),
        last_seen_time: to_datetime(last_seen),
        rank: rank
      }
    end)
  end

  defp canonical_by_armis_id(rows) do
    rows
    |> Enum.filter(&(&1.rank == 1))
    |> Map.new(fn row -> {row.armis_device_id, row.uid} end)
  end

  defp identifier_repairs(canonical_by_armis_id) do
    armis_ids = Map.keys(canonical_by_armis_id)

    armis_ids
    |> Enum.chunk_every(5_000)
    |> Enum.flat_map(fn chunk ->
      %{rows: rows} =
        query!(
          """
          SELECT id, identifier_value, device_id
          FROM platform.device_identifiers
          WHERE identifier_type = 'armis_device_id'
            AND partition = 'default'
            AND identifier_value = ANY($1)
          """,
          [chunk]
        )

      Enum.flat_map(rows, fn [id, source_id, current_owner] ->
        desired_owner = canonical_by_armis_id[source_id]

        if desired_owner in [nil, current_owner] do
          []
        else
          [
            %{
              id: id,
              armis_device_id: source_id,
              from: current_owner,
              to: desired_owner
            }
          ]
        end
      end)
    end)
  end

  defp legacy_unkeyed_rows do
    %{rows: [[count]]} =
      query!(
        """
        SELECT count(*)
        FROM platform.ocsf_devices d
        WHERE d.deleted_at IS NULL
          AND (
            'armis' = ANY(d.discovery_sources)
            OR COALESCE(d.metadata->>'integration_type', '') = 'armis'
          )
          AND NULLIF(d.metadata->>'armis_device_id', '') IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM platform.device_identifiers di
            WHERE di.device_id = d.uid
              AND di.identifier_type = 'armis_device_id'
          )
        """,
        []
      )

    count
  end

  defp legacy_orphan_rows do
    %{rows: rows} =
      query!(
        """
        SELECT d.uid, d.hostname, d.ip, d.metadata->>'source_device_id'
        FROM platform.ocsf_devices d
        WHERE d.deleted_at IS NULL
          AND d.discovery_sources = ARRAY['armis']::text[]
          AND NULLIF(d.metadata->>'armis_device_id', '') IS NULL
          AND NOT EXISTS (
            SELECT 1
            FROM platform.device_identifiers di
            WHERE di.device_id = d.uid
              AND di.identifier_type = 'armis_device_id'
          )
          AND NOT EXISTS (
            SELECT 1
            FROM platform.ocsf_agents a
            WHERE a.device_uid = d.uid
              AND a.status IN ('connected', 'connecting', 'degraded')
          )
        ORDER BY d.uid
        """,
        []
      )

    Enum.map(rows, fn [uid, hostname, ip, source_device_id] ->
      %{uid: uid, hostname: hostname, ip: ip, source_device_id: source_device_id}
    end)
  end

  defp execute_identifier_repairs(repairs, manifest) do
    Enum.reduce(repairs, {0, 0}, fn repair, {repaired, failed} ->
      case repair_identifier_owner(repair) do
        {1, _} ->
          Manifest.record(
            manifest,
            @step,
            :reassign_identifier,
            "platform.device_identifiers",
            [repair.id],
            %{
              identifier_type: "armis_device_id",
              identifier_value: repair.armis_device_id,
              from: repair.from,
              to: repair.to
            }
          )

          {repaired + 1, failed}

        other ->
          Logger.warning(
            "ArmisDups: identifier repair #{inspect(repair)} returned #{inspect(other)}"
          )

          {repaired, failed + 1}
      end
    end)
  end

  defp repair_identifier_owner(repair) do
    Repo.update_all(
      from(di in DeviceIdentifier,
        where:
          di.id == ^repair.id and di.identifier_type == :armis_device_id and
            di.identifier_value == ^repair.armis_device_id
      ),
      set: [device_id: repair.to]
    )
  rescue
    e ->
      Logger.warning("ArmisDups: identifier repair failed: #{inspect(e)}")
      {:error, e}
  end

  defp execute_merges(merges, manifest, actor) do
    Enum.reduce(merges, {0, 0}, fn duplicate, {merged, failed} ->
      case IdentityReconciler.merge_devices(duplicate.uid, duplicate.canonical_uid,
             actor: actor,
             reason: @merge_reason,
             details: %{
               step: @step,
               source: "dire_remediation",
               armis_device_id: duplicate.armis_device_id,
               duplicate_hostname: duplicate.hostname,
               duplicate_ip: duplicate.ip
             }
           ) do
        :ok ->
          Manifest.record(
            manifest,
            @step,
            :merge_device,
            "platform.ocsf_devices",
            [duplicate.uid],
            %{
              into: duplicate.canonical_uid,
              armis_device_id: duplicate.armis_device_id,
              reason: @merge_reason
            }
          )

          {merged + 1, failed}

        {:error, error} ->
          Logger.warning(
            "ArmisDups: merge #{duplicate.uid} -> #{duplicate.canonical_uid} " <>
              "(armis_device_id=#{duplicate.armis_device_id}) failed: #{inspect(error)}"
          )

          {merged, failed + 1}
      end
    end)
  end

  defp soft_delete_legacy_orphans([], _batch_size, _manifest, _actor), do: {0, 0}

  defp soft_delete_legacy_orphans(orphan_rows, batch_size, manifest, actor) do
    orphan_rows
    |> Enum.map(& &1.uid)
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce({0, 0}, fn batch, {deleted, failed} ->
      case Device.bulk_soft_delete(batch, "dire_remediation_armis_legacy_unkeyed", actor: actor) do
        :ok ->
          Manifest.record(
            manifest,
            @step,
            :soft_delete_legacy_unkeyed_devices,
            "platform.ocsf_devices",
            batch,
            %{reason: "dire_remediation_armis_legacy_unkeyed"}
          )

          {deleted + length(batch), failed}

        {:ok, :ok} ->
          Manifest.record(
            manifest,
            @step,
            :soft_delete_legacy_unkeyed_devices,
            "platform.ocsf_devices",
            batch,
            %{reason: "dire_remediation_armis_legacy_unkeyed"}
          )

          {deleted + length(batch), failed}

        error ->
          Logger.warning(
            "ArmisDups: failed to soft-delete legacy unkeyed batch: #{inspect(error)}"
          )

          {deleted, failed + length(batch)}
      end
    end)
  end

  defp merge_plan_entry(duplicate) do
    %{
      from: duplicate.uid,
      to: duplicate.canonical_uid,
      armis_device_id: duplicate.armis_device_id,
      hostname: duplicate.hostname,
      ip: duplicate.ip
    }
  end

  defp legacy_orphan_plan_entry(orphan) do
    %{
      uid: orphan.uid,
      hostname: orphan.hostname,
      ip: orphan.ip,
      source_device_id: orphan.source_device_id
    }
  end

  defp identifier_repair_plan_entry(repair) do
    %{
      id: repair.id,
      armis_device_id: repair.armis_device_id,
      from: repair.from,
      to: repair.to
    }
  end

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
  defp to_datetime(_), do: nil

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
