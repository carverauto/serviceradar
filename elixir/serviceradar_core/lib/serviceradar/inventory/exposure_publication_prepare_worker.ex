defmodule ServiceRadar.Inventory.ExposurePublicationPrepareWorker do
  @moduledoc """
  Prepares missing source publications in bounded, restartable pages.

  Each page and its Oban cursor commit together. A completed pass is preparation
  evidence, not snapshot readiness: rows created behind the cursor, pending
  restores, delivery journals and warehouse reconciliation still need checking
  by the snapshot coordinator. Retired assessments wait for authorized restore.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  import Ecto.Query

  alias ServiceRadar.Repo

  @page_size 500
  @outbox_limit 10_000

  @impl Oban.Worker
  def perform(%Oban.Job{id: id}) when is_integer(id) do
    case Repo.transaction(fn -> prepare_page(id) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_page(id) do
    Repo.query!("SET LOCAL statement_timeout = '30s'")
    Repo.query!("SET LOCAL lock_timeout = '2s'")
    job = Repo.one!(from(j in Oban.Job, where: j.id == ^id, lock: "FOR UPDATE"))

    if outbox_full?() do
      {:snooze, 30}
    else
      stage = Map.get(job.args, "stage", "lifecycle")
      {rows, next_stage} = page(stage, job.args)
      results = Enum.frequencies_by(rows, &prepare(stage, &1))
      prepared = Map.get(results, :prepared, 0)
      deferred = Map.get(results, :deferred, 0)

      args =
        job.args
        |> Map.put("stage", if(rows == [], do: next_stage, else: stage))
        |> Map.put("cursor", if(rows == [], do: nil, else: cursor(stage, List.last(rows))))
        |> Map.update("prepared", prepared, &(&1 + prepared))
        |> Map.update("deferred", deferred, &(&1 + deferred))

      Repo.update_all(from(j in Oban.Job, where: j.id == ^id), set: [args: args])

      :telemetry.execute(
        [:serviceradar, :exposure, :publication, :preparation],
        %{scanned: length(rows), prepared: prepared, deferred: deferred},
        %{stage: stage}
      )

      if args["stage"] == "done", do: :ok, else: {:snooze, 1}
    end
  end

  defp outbox_full? do
    [[count]] =
      Repo.query!("""
      SELECT count(*) FROM (
        (SELECT 1 FROM platform.exposure_transition_outbox LIMIT #{@outbox_limit})
        UNION ALL
        (SELECT 1 FROM platform.exposure_dimension_outbox LIMIT #{@outbox_limit})
      ) pending
      """).rows

    count >= @outbox_limit
  end

  defp page("lifecycle", args) do
    rows =
      Repo.query!(
        """
        SELECT ordinal, uid, tombstoned AND lifecycle_seq = 0
        FROM platform.device_fleet_ordinals
        WHERE ordinal > $1 AND ($2::text IS NULL OR uid = $2)
        ORDER BY ordinal LIMIT #{@page_size}
        """,
        [args["cursor"] || 0, args["device_uid"]]
      ).rows

    {rows, "assessments"}
  end

  defp page("assessments", args) do
    after_id = Ecto.UUID.dump!(args["cursor"] || "00000000-0000-0000-0000-000000000000")

    rows =
      Repo.query!(
        """
        SELECT id::text, device_uid, package_identity_key, cve_id,
          last_exposure_publication IS NULL OR
          NOT EXISTS (SELECT 1 FROM platform.device_fleet_ordinals o WHERE o.uid = a.device_uid
            AND o.ordinal = (a.last_exposure_publication->>'device_ord')::bigint) OR
          NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind = 'cve'
            AND d.ordinal = (a.last_exposure_publication->>'cve_ord')::bigint) OR
          NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind = 'package'
            AND d.ordinal = (a.last_exposure_publication->>'pkgver_ord')::bigint)
        FROM platform.endpoint_vulnerability_assessments a
        WHERE id > $1 AND ($2::text IS NULL OR device_uid = $2)
        ORDER BY id LIMIT #{@page_size}
        """,
        [after_id, args["device_uid"]]
      ).rows

    {rows, "watermarks"}
  end

  defp page("watermarks", args) do
    [uid, package, cve] = args["cursor"] || ["", "", ""]

    rows =
      Repo.query!(
        """
        SELECT device_uid, package_identity_key, cve_id, payload IS NULL OR
          NOT EXISTS (SELECT 1 FROM platform.device_fleet_ordinals o WHERE o.uid = w.device_uid
            AND o.ordinal = (w.payload->>'device_ord')::bigint) OR
          NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind = 'cve'
            AND d.ordinal = (w.payload->>'cve_ord')::bigint) OR
          NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind = 'package'
            AND d.ordinal = (w.payload->>'pkgver_ord')::bigint)
        FROM platform.exposure_fact_watermarks w
        WHERE (device_uid, package_identity_key, cve_id) > ($1, $2, $3)
          AND ($4::text IS NULL OR device_uid = $4)
        ORDER BY device_uid, package_identity_key, cve_id LIMIT #{@page_size}
        """,
        [uid, package, cve, args["device_uid"]]
      ).rows

    {rows, "done"}
  end

  defp page("done", _args), do: {[], "done"}

  defp prepare("lifecycle", [_ordinal, uid, true]) do
    result =
      Repo.query!(
        "UPDATE platform.device_fleet_ordinals SET tombstoned = tombstoned WHERE uid = $1 AND tombstoned AND lifecycle_seq = 0",
        [uid]
      )

    if result.num_rows > 0, do: :prepared, else: :unchanged
  end

  defp prepare("assessments", [_id, uid, package, cve, true]), do: repair(uid, package, cve)

  defp prepare("watermarks", [uid, package, cve, true]), do: repair(uid, package, cve)
  defp prepare(_stage, _row), do: :unchanged

  defp repair(uid, package, cve) do
    [[payload]] =
      Repo.query!("SELECT platform.exposure_prepare_snapshot_publication($1, $2, $3)", [
        uid,
        package,
        cve
      ]).rows

    if is_nil(payload), do: :deferred, else: :prepared
  end

  defp cursor("watermarks", [uid, package, cve, _missing]), do: [uid, package, cve]
  defp cursor(_stage, [key | _]), do: key
end
