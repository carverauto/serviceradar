defmodule ServiceRadar.ExposureAudit.Readiness do
  @moduledoc "Fresh grouped readiness; the production status function remains the differential oracle."
  alias ServiceRadar.ExposureAudit.State
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.Repo.DirectSession

  def status_many!(ordinals) do
    devices =
      "SELECT ordinal,uid FROM platform.device_fleet_ordinals WHERE ordinal=ANY($1)"
      |> State.query!([ordinals])
      |> Map.new(fn [ordinal, uid] -> {ordinal, uid} end)

    buckets =
      Enum.map(ordinals, fn ordinal ->
        case devices[ordinal] do
          nil ->
            nil

          uid ->
            uid
            |> ExposureTransitionRelay.subject()
            |> String.split(".")
            |> List.last()
            |> String.to_integer()
        end
      end)

    DirectSession.run(fn session ->
      {:ok, rows} =
        Postgrex.transaction(
          session,
          fn reader ->
            Postgrex.query!(
              reader,
              "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
              []
            )

            Postgrex.query!(reader, "SET LOCAL statement_timeout='30s'", [])
            Postgrex.query!(reader, sql(), [ordinals, buckets], timeout: 30_000).rows
          end,
          timeout: 60_000
        )

      Map.new(rows, fn [ordinal | blockers] ->
        names = [
          :snapshot_missing,
          :comparison_pending,
          :source_preparation,
          :delivery_recovery,
          :snapshot_recovery,
          :outbox_stale
        ]

        reasons =
          names
          |> Enum.zip(blockers)
          |> Enum.flat_map(fn {name, blocked} -> if blocked, do: [name], else: [] end)

        {ordinal, %{ready: reasons == [], reasons: reasons}}
      end)
    end)
  end

  defp sql do
    """
    WITH scopes AS MATERIALIZED (SELECT * FROM unnest($1::bigint[],$2::integer[]) AS s(ordinal,bucket)),
    publications AS MATERIALIZED (
      SELECT o.ordinal,a.last_exposure_publication payload FROM scopes s
      JOIN platform.device_fleet_ordinals o ON o.ordinal=s.ordinal
      JOIN platform.endpoint_vulnerability_assessments a ON a.device_uid=o.uid WHERE NOT o.tombstoned
      UNION ALL
      SELECT o.ordinal,w.payload FROM scopes s
      JOIN platform.device_fleet_ordinals o ON o.ordinal=s.ordinal
      JOIN platform.exposure_fact_watermarks w ON w.device_uid=o.uid WHERE NOT o.tombstoned
    ), unprepared AS MATERIALIZED (
      SELECT DISTINCT p.ordinal FROM publications p WHERE payload IS NULL
        OR (payload->>'device_ord')::bigint IS DISTINCT FROM p.ordinal
        OR NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind='cve' AND d.ordinal=(payload->>'cve_ord')::bigint)
        OR NOT EXISTS (SELECT 1 FROM platform.exposure_dimension_state d WHERE d.kind='package' AND d.ordinal=(payload->>'pkgver_ord')::bigint)
    ), stale_dimensions AS MATERIALIZED (
      SELECT EXISTS(SELECT 1 FROM platform.exposure_dimension_outbox WHERE inserted_at<now()-interval '10 minutes') AS stale
    )
    SELECT s.ordinal,
      g.id IS NULL,
      (g.id IS NULL OR c.device_ord IS NULL OR c.status<>'matched' OR c.checked_at IS NULL
        OR c.checked_at<now()-interval '1 day' OR c.control->>'started_at' IS NULL
        OR (c.control->>'started_at')::timestamp<g.updated_at
        OR COALESCE((c.control->>'generation_floor')::bigint,0)>=g.id),
      (EXISTS(SELECT 1 FROM unprepared p WHERE p.ordinal=s.ordinal)
        OR EXISTS(SELECT 1 FROM platform.device_fleet_ordinals o WHERE o.ordinal=s.ordinal
          AND ((o.tombstoned AND o.lifecycle_seq=0) OR EXISTS(
            SELECT 1 FROM platform.exposure_device_refreshes r WHERE r.device_uid=o.uid)))),
      EXISTS(SELECT 1 FROM platform.exposure_delivery_batches b WHERE phase<>'complete' AND (s.bucket IS NULL OR b.bucket=s.bucket)),
      (COALESCE(jsonb_array_length(c.control->'repairs'),0)>0 OR EXISTS(
        SELECT 1 FROM platform.exposure_snapshot_generations r
        WHERE (r.control->>'scope' IS NULL OR (r.control->>'scope')::bigint=s.ordinal)
          AND (r.control->'pending'<>'{}'::jsonb OR jsonb_array_length(r.control->'repairs')>0
            OR (r.status<>'complete' AND r.id>COALESCE(g.id,0))))),
      (sd.stale OR EXISTS(SELECT 1 FROM platform.exposure_transition_outbox b
        JOIN platform.device_fleet_ordinals o ON o.uid=b.device_uid
        WHERE o.ordinal=s.ordinal AND b.inserted_at<now()-interval '10 minutes'))
    FROM scopes s CROSS JOIN stale_dimensions sd
    LEFT JOIN platform.exposure_reconciliation_checks c ON c.device_ord=s.ordinal
    LEFT JOIN LATERAL (SELECT id,updated_at FROM platform.exposure_snapshot_generations
      WHERE status='complete' AND (control->>'scope' IS NULL OR (control->>'scope')::bigint=s.ordinal)
      ORDER BY id DESC LIMIT 1) g ON true ORDER BY s.ordinal
    """
  end
end
