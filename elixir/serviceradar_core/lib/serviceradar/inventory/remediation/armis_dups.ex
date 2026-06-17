defmodule ServiceRadar.Inventory.Remediation.ArmisDups do
  @moduledoc """
  Collapses Armis duplicate device rows created when sync batches carried
  legacy Armis identity metadata (`source_device_id` / generic
  `integration_id`) but the bulk ingest path did not resolve through
  `armis_device_id`.

  The source of truth for this cleanup is the Armis source-device group:
  every active Armis row with the same `metadata.source_device_id` represents
  one Armis device. The step first repairs the `armis_device_id` identifier
  owner to the selected group canonical row, then merges duplicate rows within
  that same group. This avoids preserving older bad identifier ownership that
  may already point several Armis IDs at one unrelated device.
  """

  import Ecto.Query

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
    plan = build_plan()

    base = %{
      source_device_groups: map_size(plan.canonical_by_source_id),
      duplicate_rows: length(plan.duplicates),
      planned_merges: length(plan.duplicates),
      identifier_repairs: length(plan.identifier_repairs),
      merge_plan: Enum.take(Enum.map(plan.duplicates, &merge_plan_entry/1), sample_limit),
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

        Map.merge(base, %{
          repaired_identifiers: repaired,
          identifier_repair_failures: repair_failed,
          merged: merged,
          merge_failures: merge_failed
        })
    end
  end

  defp build_plan do
    ranked_rows = ranked_armis_rows()
    canonical_by_source_id = canonical_by_source_id(ranked_rows)

    duplicates =
      ranked_rows
      |> Enum.reject(&(&1.rank == 1))
      |> Enum.map(fn row ->
        Map.put(row, :canonical_uid, canonical_by_source_id[row.armis_device_id])
      end)
      |> Enum.reject(&is_nil(&1.canonical_uid))

    %{
      canonical_by_source_id: canonical_by_source_id,
      duplicates: duplicates,
      identifier_repairs: identifier_repairs(canonical_by_source_id)
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
        )
        SELECT
          d.uid,
          d.metadata->>'source_device_id' AS armis_device_id,
          d.hostname,
          d.ip,
          d.created_time,
          d.last_seen_time,
          ROW_NUMBER() OVER (
            PARTITION BY d.metadata->>'source_device_id'
            ORDER BY
              CASE WHEN p.device_uid IS NOT NULL THEN 0 ELSE 1 END,
              CASE WHEN NULLIF(d.ip, '') IS NOT NULL THEN 0 ELSE 1 END,
              d.last_seen_time DESC NULLS LAST,
              d.created_time ASC NULLS LAST,
              d.uid ASC
          ) AS rank
        FROM platform.ocsf_devices d
        LEFT JOIN protected p ON p.device_uid = d.uid
        WHERE d.deleted_at IS NULL
          AND 'armis' = ANY(d.discovery_sources)
          AND NULLIF(d.metadata->>'source_device_id', '') IS NOT NULL
        ORDER BY d.metadata->>'source_device_id', rank
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

  defp canonical_by_source_id(rows) do
    rows
    |> Enum.filter(&(&1.rank == 1))
    |> Map.new(fn row -> {row.armis_device_id, row.uid} end)
  end

  defp identifier_repairs(canonical_by_source_id) do
    source_ids = Map.keys(canonical_by_source_id)

    source_ids
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
        desired_owner = canonical_by_source_id[source_id]

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

  defp merge_plan_entry(duplicate) do
    %{
      from: duplicate.uid,
      to: duplicate.canonical_uid,
      armis_device_id: duplicate.armis_device_id,
      hostname: duplicate.hostname,
      ip: duplicate.ip
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
