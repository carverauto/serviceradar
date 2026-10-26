defmodule ServiceRadar.Inventory.ExposureReadiness do
  @moduledoc "Scoped recovery readiness. Ordinary outbox traffic is governed by age, not emptiness."
  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.Inventory.ExposureSnapshotWorker, as: Publisher
  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.DirectSession

  def status(scope \\ nil)

  def status(scope) when is_nil(scope) or (is_integer(scope) and scope in 1..4_294_967_295) do
    if Destination.enabled?() do
      DirectSession.run(fn reader ->
        Postgrex.transaction(reader, fn tx ->
          Postgrex.query!(tx, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
          Postgrex.query!(tx, "SET LOCAL statement_timeout = '30s'", [])
          readiness(tx, scope)
        end)
      end)
    else
      {:error, :starrocks_required}
    end
  end

  def status(_scope), do: {:error, :invalid_exposure_scope}

  def latest_generation(scope) do
    case Repo.query!(
           """
           SELECT id, updated_at FROM platform.exposure_snapshot_generations
           WHERE status = 'complete' AND
             (control->>'scope' IS NULL OR (control->>'scope')::bigint = $1)
           ORDER BY id DESC LIMIT 1
           """,
           [scope]
         ).rows do
      [[id, time]] -> {id, time}
      [] -> {0, nil}
    end
  end

  defp readiness(reader, scope) do
    [[generation, age, completed_at]] =
      Postgrex.query!(
        reader,
        """
        SELECT COALESCE(max(id), 0),
          COALESCE(EXTRACT(EPOCH FROM now() - max(updated_at))::bigint, 0), max(updated_at)
        FROM platform.exposure_snapshot_generations WHERE status = 'complete'
          AND (control->>'scope' IS NULL OR (control->>'scope')::bigint = $1)
        """,
        [scope]
      ).rows

    [[comparison_pending]] =
      Postgrex.query!(
        reader,
        """
        SELECT EXISTS (
          SELECT 1 FROM (
            SELECT ordinal AS device_ord FROM platform.device_fleet_ordinals
            UNION SELECT device_ord FROM platform.exposure_reconciliation_checks WHERE device_ord > 0
          ) devices LEFT JOIN platform.exposure_reconciliation_checks c USING (device_ord)
          WHERE ($1::bigint IS NULL OR devices.device_ord = $1) AND
            (c.device_ord IS NULL OR c.status <> 'matched' OR c.checked_at IS NULL
             OR c.checked_at < now() - interval '1 day'
           OR (c.control->>'started_at')::timestamp < $3
             OR COALESCE((c.control->>'generation_floor')::bigint, 0) >= $2)
        ) OR ($1::bigint IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM platform.exposure_reconciliation_checks WHERE device_ord = $1))
        """,
        [scope, generation, completed_at]
      ).rows

    [[fleet_pending]] =
      Postgrex.query!(
        reader,
        """
        SELECT $1::bigint IS NULL AND NOT EXISTS (
          SELECT 1 FROM platform.exposure_reconciliation_checks fleet WHERE device_ord = 0
            AND status = 'matched' AND checked_at >= now() - interval '1 day'
            AND NOT EXISTS (SELECT 1 FROM platform.exposure_reconciliation_checks c
              WHERE c.device_ord > 0 AND (c.checked_at IS NULL OR
                c.checked_at < (fleet.control->>'started_at')::timestamp)))
        """,
        [scope]
      ).rows

    bucket = bucket(reader, scope)

    [[delivery]] =
      Postgrex.query!(
        reader,
        """
        SELECT count(*) FROM platform.exposure_delivery_batches
        WHERE phase <> 'complete' AND ($1::integer IS NULL OR bucket = $1)
        """,
        [bucket]
      ).rows

    [[pending, repairs]] =
      Postgrex.query!(
        reader,
        """
        SELECT count(*), COALESCE(sum(jsonb_array_length(control->'repairs')), 0)::bigint
        FROM platform.exposure_snapshot_generations
        WHERE ($1::bigint IS NULL OR control->>'scope' IS NULL OR (control->>'scope')::bigint = $1)
          AND (control->'pending' <> '{}'::jsonb OR
            (id > $2 AND (status <> 'complete' OR jsonb_array_length(control->'repairs') > 0)))
        """,
        [scope, generation]
      ).rows

    [[comparison_repairs]] =
      Postgrex.query!(
        reader,
        """
        SELECT COALESCE(sum(jsonb_array_length(COALESCE(control->'repairs', '[]'::jsonb))), 0)::bigint
        FROM platform.exposure_reconciliation_checks
        WHERE device_ord > 0 AND ($1::bigint IS NULL OR device_ord = $1)
        """,
        [scope]
      ).rows

    [[stale_outbox]] =
      Postgrex.query!(
        reader,
        """
        SELECT EXISTS (SELECT 1 FROM platform.exposure_transition_outbox b
          LEFT JOIN platform.device_fleet_ordinals o ON o.uid = b.device_uid
          WHERE ($1::bigint IS NULL OR o.ordinal = $1) AND b.inserted_at < now() - interval '10 minutes')
        OR EXISTS (SELECT 1 FROM platform.exposure_dimension_outbox
          WHERE inserted_at < now() - interval '10 minutes')
        """,
        [scope]
      ).rows

    reasons =
      Enum.flat_map(
        [
          {generation == 0, :snapshot_missing},
          {comparison_pending or fleet_pending, :comparison_pending},
          {Publisher.prerequisites(reader, scope) != :ok, :source_preparation},
          {delivery > 0, :delivery_recovery},
          {pending > 0 or repairs + comparison_repairs > 0, :snapshot_recovery},
          {stale_outbox, :outbox_stale}
        ],
        fn {blocked, reason} -> if blocked, do: [reason], else: [] end
      )

    metrics = %{
      generation_age: age,
      repair_pending: repairs + comparison_repairs,
      delivery_recovery: delivery,
      ready: if(reasons == [], do: 1, else: 0)
    }

    :telemetry.execute([:serviceradar, :exposure, :readiness], metrics, %{
      scope: if(is_nil(scope), do: :deployment, else: :device)
    })

    %{ready: reasons == [], reasons: reasons, generation: generation, metrics: metrics}
  end

  defp bucket(_reader, nil), do: nil

  defp bucket(reader, scope) do
    case Postgrex.query!(
           reader,
           "SELECT uid FROM platform.device_fleet_ordinals WHERE ordinal = $1",
           [scope]
         ).rows do
      [[uid]] ->
        uid
        |> ExposureTransitionRelay.subject()
        |> String.split(".")
        |> List.last()
        |> String.to_integer()

      # Unknown warehouse ordinals cannot prove journal scope. Fail conservatively.
      [] ->
        nil
    end
  end
end
