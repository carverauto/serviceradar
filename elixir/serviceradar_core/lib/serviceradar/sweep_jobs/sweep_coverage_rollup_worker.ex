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
  rollup run must still block the delete through its own watermark guard --
  the earliest day that has `sweep_host_results` rows but no matching
  `sweep_coverage_daily` row.

  ## Catch-up

  A scheduled (args-less) run does not roll only yesterday: on a fresh
  deployment, or after any missed day, `sweep_coverage_daily` can be empty
  or gapped while `sweep_host_results` already holds days of history.
  Rolling only yesterday would leave that backlog permanently un-rolled,
  because the watermark day this worker exists to keep moving is never
  deleted (it IS the gap) and never rolled up (nothing would look further
  back than yesterday). So an args-less run rolls every un-rolled day
  oldest-first through yesterday, capped at 30 days per invocation so a
  long backlog cannot turn one execution into an unbounded loop -- the
  remainder drains over the next scheduled runs. A day that fails is
  logged and skipped rather than aborting the run.

  A run given an explicit `"day"` argument (tests, manual re-runs) rolls
  exactly that one day, with no catch-up -- unchanged from before.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3600, fields: [:worker, :args], states: :incomplete]

  import Ecto.Query

  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  # Run daily (24 hours), same cadence as SweepDataCleanupWorker.
  @reschedule_interval_seconds 86_400

  # Bound on how many un-rolled days a single args-less run will process.
  # A deeper backlog is not lost -- it is picked up by later scheduled
  # runs, one reschedule interval apart -- but nothing here should let one
  # Oban execution run unboundedly.
  @max_catch_up_days 30

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
    result =
      case args["day"] do
        nil -> perform_catch_up()
        value -> perform_single_day(Date.from_iso8601!(value))
      end

    schedule_next_rollup()

    result
  end

  # Rolls exactly the day requested by args["day"]. Used by tests and
  # manual re-runs that want one specific day rolled -- unchanged from
  # before catch-up existed.
  defp perform_single_day(%Date{} = day) do
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
  end

  # Rolls every day that has `sweep_host_results` rows but no matching
  # `sweep_coverage_daily` row, oldest first, through yesterday -- capped
  # per run at @max_catch_up_days. See the moduledoc's "Catch-up" section
  # for why an args-less run cannot simply roll yesterday.
  defp perform_catch_up do
    yesterday = Date.add(Date.utc_today(), -1)

    case unrolled_days(yesterday) do
      {:ok, []} ->
        Logger.info(
          "SweepCoverageRollup: no un-rolled day found through #{Date.to_iso8601(yesterday)}"
        )

        :ok

      {:ok, gap_days} ->
        {days, remaining} = Enum.split(gap_days, @max_catch_up_days)

        if remaining != [] do
          Logger.info(
            "SweepCoverageRollup: catching up #{length(days)} day(s) this run; " <>
              "#{length(remaining)} day(s) still behind and will be picked up in later runs"
          )
        end

        roll_catch_up_days(days)

      {:error, reason} ->
        Logger.error(
          "SweepCoverageRollup: failed to compute catch-up backlog: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp roll_catch_up_days(days) do
    {success_count, failures} =
      Enum.reduce(days, {0, []}, fn day, {success_count, failures} ->
        case rollup_day(day) do
          {:ok, count} ->
            Logger.info(
              "SweepCoverageRollup: wrote #{count} row(s) for #{Date.to_iso8601(day)} (catch-up)"
            )

            {success_count + 1, failures}

          {:error, reason} ->
            Logger.error(
              "SweepCoverageRollup: catch-up failed for #{Date.to_iso8601(day)}: " <>
                "#{inspect(reason)}"
            )

            {success_count, [{day, reason} | failures]}
        end
      end)

    case {success_count, Enum.reverse(failures)} do
      {_, []} ->
        :ok

      {0, failures} ->
        {:error, {:catch_up_failed, failures}}

      {success_count, failures} ->
        Logger.warning(
          "SweepCoverageRollup: catch-up finished with #{length(failures)} failed day(s) " <>
            "out of #{success_count + length(failures)}; failed days will retry on a later run"
        )

        :ok
    end
  end

  # Days that have `sweep_host_results` rows but no matching
  # `sweep_coverage_daily` row, oldest first, through `through_day`
  # inclusive. Mirrors the gap scan in
  # `SweepDataCleanupWorker.earliest_unrolled_day/0`, but returns every gap
  # day (bounded by the caller) rather than only the earliest one.
  defp unrolled_days(%Date{} = through_day) do
    query = """
    SELECT DISTINCT (r.inserted_at)::date AS d
    FROM platform.sweep_host_results r
    WHERE (r.inserted_at)::date <= $1::date
      AND NOT EXISTS (
        SELECT 1 FROM platform.sweep_coverage_daily c WHERE c.day = (r.inserted_at)::date
      )
    ORDER BY d ASC
    """

    case Repo.query(query, [through_day]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [day] -> day end)}
      {:error, reason} -> {:error, reason}
    end
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
        COALESCE(device_uid, '') AS device_uid,
        ip,
        COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid) AS sweep_group_id,
        COALESCE(agent_id, '') AS agent_id,
        COUNT(DISTINCT execution_id) AS execution_count,
        COUNT(*) FILTER (WHERE status = 'available') AS available_count,
        COUNT(*) FILTER (WHERE status IN ('unavailable', 'timeout')) AS unavailable_count,
        COUNT(*) FILTER (WHERE status = 'error') AS error_count,
        MIN(inserted_at) AS first_seen_at,
        MAX(inserted_at) AS last_seen_at,
        (ARRAY_AGG(status ORDER BY inserted_at DESC))[1] AS last_status,
        (ARRAY_AGG(response_time_ms ORDER BY inserted_at DESC))[1] AS last_response_time_ms
      FROM src
      GROUP BY
        COALESCE(device_uid, ''),
        ip,
        COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid),
        COALESCE(agent_id, '')
    ),
    scanned AS (
      SELECT
        COALESCE(device_uid, '') AS device_uid,
        ip,
        COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid) AS sweep_group_id,
        COALESCE(agent_id, '') AS agent_id,
        ARRAY_AGG(DISTINCT p ORDER BY p) AS ports
      FROM src, LATERAL unnest(src.scanned_ports) AS p
      GROUP BY
        COALESCE(device_uid, ''),
        ip,
        COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid),
        COALESCE(agent_id, '')
    ),
    opened AS (
      SELECT
        COALESCE(device_uid, '') AS device_uid,
        ip,
        COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid) AS sweep_group_id,
        COALESCE(agent_id, '') AS agent_id,
        ARRAY_AGG(DISTINCT p ORDER BY p) AS ports
      FROM src, LATERAL unnest(src.open_ports) AS p
      GROUP BY
        COALESCE(device_uid, ''),
        ip,
        COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid),
        COALESCE(agent_id, '')
    ),
    modes AS (
      SELECT
        COALESCE(device_uid, '') AS device_uid,
        ip,
        COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid) AS sweep_group_id,
        COALESCE(agent_id, '') AS agent_id,
        ARRAY_AGG(DISTINCT m.key ORDER BY m.key) AS requested,
        ARRAY_AGG(DISTINCT m.key ORDER BY m.key)
          FILTER (WHERE m.value::text = '"success"') AS observed
      FROM src, LATERAL jsonb_each(src.sweep_modes_results) AS m(key, value)
      GROUP BY
        COALESCE(device_uid, ''),
        ip,
        COALESCE(sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid),
        COALESCE(agent_id, '')
    )
    INSERT INTO platform.sweep_coverage_daily AS t (
      id, day, device_uid, ip, sweep_group_id, agent_id,
      execution_count, available_count, unavailable_count, error_count,
      first_seen_at, last_seen_at,
      scanned_ports, open_ports, modes_requested, modes_observed,
      last_status, last_response_time_ms, inserted_at, updated_at
    )
    SELECT
      gen_random_uuid(), $1::date,
      NULLIF(s.device_uid, ''),
      s.ip,
      NULLIF(s.sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid),
      NULLIF(s.agent_id, ''),
      s.execution_count, s.available_count, s.unavailable_count, s.error_count,
      s.first_seen_at, s.last_seen_at,
      COALESCE(sc.ports, '{}'::bigint[]),
      COALESCE(op.ports, '{}'::bigint[]),
      COALESCE(md.requested, '{}'::text[]),
      COALESCE(md.observed, '{}'::text[]),
      s.last_status, s.last_response_time_ms,
      (now() AT TIME ZONE 'utc'), (now() AT TIME ZONE 'utc')
    FROM scalars s
    LEFT JOIN scanned sc
      ON COALESCE(s.device_uid, '') = COALESCE(sc.device_uid, '')
     AND s.ip = sc.ip
     AND COALESCE(s.sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid)
       = COALESCE(sc.sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid)
     AND COALESCE(s.agent_id, '') = COALESCE(sc.agent_id, '')
    LEFT JOIN opened op
      ON COALESCE(s.device_uid, '') = COALESCE(op.device_uid, '')
     AND s.ip = op.ip
     AND COALESCE(s.sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid)
       = COALESCE(op.sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid)
     AND COALESCE(s.agent_id, '') = COALESCE(op.agent_id, '')
    LEFT JOIN modes md
      ON COALESCE(s.device_uid, '') = COALESCE(md.device_uid, '')
     AND s.ip = md.ip
     AND COALESCE(s.sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid)
       = COALESCE(md.sweep_group_id, '00000000-0000-0000-0000-000000000000'::uuid)
     AND COALESCE(s.agent_id, '') = COALESCE(md.agent_id, '')
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
      updated_at = (now() AT TIME ZONE 'utc')
    """
  end
end
