defmodule ServiceRadar.SweepJobs.SweepCoverageRollupWorker do
  @moduledoc """
  Rolls per-host sweep results into a daily per-device, per-group, per-agent
  summary that outlives the raw host result retention window.

  Raw results are kept for days; overlap and last-writer questions are asked
  for months. The grain is what makes overlap answerable: two rows sharing a
  day, device and agent but differing in sweep group is exactly the overlap
  case that `device_agent_availability` cannot represent, because it keeps
  only the last writer.

  ## Scheduling

  `ensure_scheduled/0` is called wherever
  `ServiceRadar.SweepJobs.SweepDataCleanupWorker.ensure_scheduled/0` is
  called, and before it, so this worker has a chance to run ahead of
  cleanup's daily cycle. That ordering is only an optimization:
  `SweepDataCleanupWorker` never relies on it, because a failed or skipped
  rollup run must still block the delete through its own watermark guard
  (`SELECT MAX(day) FROM platform.sweep_coverage_daily`).
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3600, fields: [:worker, :args]]

  import Ecto.Query

  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  # Run daily (24 hours), same cadence as SweepDataCleanupWorker.
  @reschedule_interval_seconds 86_400

  @doc """
  Schedules the daily coverage rollup if not already scheduled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    day =
      case args["day"] do
        nil -> Date.add(Date.utc_today(), -1)
        value -> Date.from_iso8601!(value)
      end

    result =
      case rollup_day(day) do
        {:ok, count} ->
          Logger.info("SweepCoverageRollup: wrote #{count} row(s) for #{Date.to_iso8601(day)}")
          :ok

        {:error, reason} = error ->
          Logger.error(
            "SweepCoverageRollup: failed for #{Date.to_iso8601(day)}: #{inspect(reason)}"
          )

          error
      end

    schedule_next_rollup()

    result
  end

  defp schedule_next_rollup do
    case ObanSupport.safe_insert(
           SelfScheduling.successor_changeset(__MODULE__, %{}, @reschedule_interval_seconds)
         ) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Sweep coverage rollup reschedule deferred", reason: inspect(reason))
        :ok
    end
  end

  @doc """
  Aggregates one day of sweep host results into the coverage table.

  Idempotent: re-running a day replaces that day's rows rather than adding to
  them, so a retry or a manual re-run cannot double count.
  """
  @spec rollup_day(Date.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rollup_day(%Date{} = day) do
    case Repo.query(rollup_sql(), [day]) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollup_sql do
    """
    WITH src AS (
      SELECT
        r.execution_id,
        r.device_id AS device_uid,
        r.ip,
        COALESCE(r.sweep_group_id, e.sweep_group_id) AS sweep_group_id,
        COALESCE(r.agent_id, e.agent_id) AS agent_id,
        r.status,
        r.response_time_ms,
        r.scanned_ports,
        r.open_ports,
        r.sweep_modes_results,
        r.inserted_at
      FROM platform.sweep_host_results r
      JOIN platform.sweep_group_executions e ON e.id = r.execution_id
      WHERE r.inserted_at >= $1::date
        AND r.inserted_at < ($1::date + INTERVAL '1 day')
    ),
    scalars AS (
      SELECT
        device_uid, ip, sweep_group_id, agent_id,
        COUNT(DISTINCT execution_id) AS execution_count,
        COUNT(*) FILTER (WHERE status = 'available') AS available_count,
        COUNT(*) FILTER (WHERE status IN ('unavailable', 'timeout')) AS unavailable_count,
        COUNT(*) FILTER (WHERE status = 'error') AS error_count,
        MIN(inserted_at) AS first_seen_at,
        MAX(inserted_at) AS last_seen_at,
        (ARRAY_AGG(status ORDER BY inserted_at DESC))[1] AS last_status,
        (ARRAY_AGG(response_time_ms ORDER BY inserted_at DESC))[1] AS last_response_time_ms
      FROM src
      GROUP BY device_uid, ip, sweep_group_id, agent_id
    ),
    scanned AS (
      SELECT device_uid, ip, sweep_group_id, agent_id,
             ARRAY_AGG(DISTINCT p ORDER BY p) AS ports
      FROM src, LATERAL unnest(src.scanned_ports) AS p
      GROUP BY device_uid, ip, sweep_group_id, agent_id
    ),
    opened AS (
      SELECT device_uid, ip, sweep_group_id, agent_id,
             ARRAY_AGG(DISTINCT p ORDER BY p) AS ports
      FROM src, LATERAL unnest(src.open_ports) AS p
      GROUP BY device_uid, ip, sweep_group_id, agent_id
    ),
    modes AS (
      SELECT device_uid, ip, sweep_group_id, agent_id,
             ARRAY_AGG(DISTINCT m.key ORDER BY m.key) AS requested,
             ARRAY_AGG(DISTINCT m.key ORDER BY m.key)
               FILTER (WHERE m.value::text = '"success"') AS observed
      FROM src, LATERAL jsonb_each(src.sweep_modes_results) AS m(key, value)
      GROUP BY device_uid, ip, sweep_group_id, agent_id
    )
    INSERT INTO platform.sweep_coverage_daily AS t (
      id, day, device_uid, ip, sweep_group_id, agent_id,
      execution_count, available_count, unavailable_count, error_count,
      first_seen_at, last_seen_at,
      scanned_ports, open_ports, modes_requested, modes_observed,
      last_status, last_response_time_ms, inserted_at, updated_at
    )
    SELECT
      gen_random_uuid(), $1::date, s.device_uid, s.ip, s.sweep_group_id, s.agent_id,
      s.execution_count, s.available_count, s.unavailable_count, s.error_count,
      s.first_seen_at, s.last_seen_at,
      COALESCE(sc.ports, '{}'::bigint[]),
      COALESCE(op.ports, '{}'::bigint[]),
      COALESCE(md.requested, '{}'::text[]),
      COALESCE(md.observed, '{}'::text[]),
      s.last_status, s.last_response_time_ms,
      now(), now()
    FROM scalars s
    LEFT JOIN scanned sc
      ON s.device_uid IS NOT DISTINCT FROM sc.device_uid
     AND s.ip IS NOT DISTINCT FROM sc.ip
     AND s.sweep_group_id IS NOT DISTINCT FROM sc.sweep_group_id
     AND s.agent_id IS NOT DISTINCT FROM sc.agent_id
    LEFT JOIN opened op
      ON s.device_uid IS NOT DISTINCT FROM op.device_uid
     AND s.ip IS NOT DISTINCT FROM op.ip
     AND s.sweep_group_id IS NOT DISTINCT FROM op.sweep_group_id
     AND s.agent_id IS NOT DISTINCT FROM op.agent_id
    LEFT JOIN modes md
      ON s.device_uid IS NOT DISTINCT FROM md.device_uid
     AND s.ip IS NOT DISTINCT FROM md.ip
     AND s.sweep_group_id IS NOT DISTINCT FROM md.sweep_group_id
     AND s.agent_id IS NOT DISTINCT FROM md.agent_id
    ON CONFLICT (
      day,
      COALESCE(device_uid, ''),
      ip,
      COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(agent_id, '')
    )
    DO UPDATE SET
      execution_count = EXCLUDED.execution_count,
      available_count = EXCLUDED.available_count,
      unavailable_count = EXCLUDED.unavailable_count,
      error_count = EXCLUDED.error_count,
      first_seen_at = LEAST(t.first_seen_at, EXCLUDED.first_seen_at),
      last_seen_at = GREATEST(t.last_seen_at, EXCLUDED.last_seen_at),
      scanned_ports = EXCLUDED.scanned_ports,
      open_ports = EXCLUDED.open_ports,
      modes_requested = EXCLUDED.modes_requested,
      modes_observed = EXCLUDED.modes_observed,
      last_status = EXCLUDED.last_status,
      last_response_time_ms = EXCLUDED.last_response_time_ms,
      updated_at = now()
    """
  end
end
