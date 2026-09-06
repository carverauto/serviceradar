defmodule ServiceRadar.SweepJobs.SweepDataCleanupWorker do
  @moduledoc """
  Worker that cleans up old sweep execution data.

  This worker runs daily to delete:
  - `SweepHostResult` records older than `host_results_retention_days` (default: 7)
  - `SweepGroupExecution` records older than `executions_retention_days` (default: 30)
  - `platform.sweep_coverage_daily` rows older than `rollup_retention_days` (default: 400)

  Host results are deleted first. Only completed or failed executions with no
  remaining host results are eligible for retention cleanup. This preserves
  watermark-protected results even though execution deletion now cascades to
  host results. Operator-initiated group deletion intentionally bypasses this
  retention protection; see `openspec/specs/sweep-jobs/spec.md`.

  The regression is covered by `sweep_data_cleanup_watermark_db_test.exs`.

  ## Rollup watermark guard

  Host results are never deleted at or after the earliest day that has
  `sweep_host_results` rows but no matching `sweep_coverage_daily` row --
  i.e. the earliest day the rollup has not (yet, or ever) covered. Deleting
  such a day would destroy the only durable record of which sweep group and
  agent produced those results.

  This is deliberately NOT `MAX(day)` from `platform.sweep_coverage_daily`.
  `ServiceRadar.SweepJobs.SweepCoverageRollupWorker` catches up a bounded
  backlog of un-rolled days per run and logs-and-continues past a day that
  fails, so a permanently failed day D does not stop a later day D+2 from
  being rolled up -- `MAX(day)` would advance past D and the unguarded
  cutoff would delete D's still-unrolled rows. Scanning for the
  earliest gap instead of trusting the maximum protects an unrolled day
  however it arose, not just the "nothing has ever been rolled up" case.
  When the gap watermark actually holds the cutoff back, that is logged at
  `warning`, naming the blocking day, so a permanently stuck day (which
  otherwise grows `sweep_host_results` unbounded with no further signal)
  is visible to an operator.

  ## Scheduling

  This worker is scheduled when:
  - A sweep group is created with `enabled: true`
  - A sweep group is enabled

  The worker reschedules itself daily if there are sweep-related records.

  ## Configuration

  Retention periods can be configured via application config:

      config :serviceradar_core, ServiceRadar.SweepJobs.SweepDataCleanupWorker,
        host_results_retention_days: 7,
        executions_retention_days: 30,
        rollup_retention_days: 400,
        batch_size: 1000
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult

  require Logger

  @default_host_results_retention_days 7
  @default_executions_retention_days 30
  @default_rollup_retention_days 400
  @default_batch_size 1000

  # Run daily (24 hours)
  @reschedule_interval_seconds 86_400

  @doc """
  Schedules sweep data cleanup if not already scheduled.

  Called automatically when sweep groups are created or enabled.
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
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    host_results_days =
      Keyword.get(config, :host_results_retention_days, @default_host_results_retention_days)

    executions_days =
      Keyword.get(config, :executions_retention_days, @default_executions_retention_days)

    rollup_days =
      Keyword.get(config, :rollup_retention_days, @default_rollup_retention_days)

    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    host_results_cutoff = clamp_host_results_cutoff(host_results_days)
    executions_cutoff = DateTime.add(DateTime.utc_now(), -executions_days * 86_400, :second)
    coverage_cutoff = Date.add(Date.utc_today(), -rollup_days)

    Logger.info(
      "SweepDataCleanupWorker: Starting cleanup - " <>
        "host results older than #{host_results_days} days (clamped to the earliest unrolled day), " <>
        "executions older than #{executions_days} days, " <>
        "coverage rollups older than #{rollup_days} days"
    )

    stats = cleanup_data(host_results_cutoff, executions_cutoff, coverage_cutoff, batch_size)

    Logger.info(
      "SweepDataCleanupWorker: Completed - " <>
        "deleted #{stats.host_results} host results, " <>
        "#{stats.executions} executions, " <>
        "#{stats.coverage_rollups} coverage rollups",
      errors: stats.errors
    )

    # Reschedule for tomorrow
    schedule_next_cleanup()

    :ok
  end

  # The earliest day that has `sweep_host_results` rows but no matching
  # `sweep_coverage_daily` row -- the earliest day the rollup has not (yet,
  # or ever) covered. `nil` means every day that has host results also has
  # a coverage row (including the trivial case of no host results at all).
  #
  # This is a gap scan rather than `MAX(day)` on purpose: the rollup worker
  # logs and continues past a day that fails rather than aborting its
  # catch-up run, so `MAX(day)` alone cannot be trusted as a watermark --
  # it advances past a permanently failed day the moment any later day
  # succeeds.
  #
  # `sweep_host_results.inserted_at` is `timestamp without time zone`,
  # populated as `now() AT TIME ZONE 'utc'` (matching how
  # SweepCoverageRollupWorker already windows a day), so casting it to
  # `::date` here is a naive UTC date with no session-timezone dependency.
  # Returns `{:ok, nil}` when every day with host results also has a
  # coverage row (including the trivial no-host-results case), `{:ok,
  # day}` when `day` is the earliest gap, or `{:error, reason}` when the
  # query itself could not be answered. That third outcome is deliberate:
  # a missing table during a rolling deploy, a connection error, or a
  # timeout on the sequential scan are all failures of the *query*, not
  # evidence that there is no gap, and must not be collapsed into `nil` --
  # doing so is what let a fail-open guard silently disable itself. See
  # `clamp_host_results_cutoff/1`, which turns `{:error, _}` here into
  # skipping the host-result delete entirely for the run.
  defp earliest_unrolled_day do
    query = """
    SELECT MIN(d) FROM (
      SELECT DISTINCT (r.inserted_at)::date AS d
      FROM platform.sweep_host_results r
      WHERE NOT EXISTS (
        SELECT 1 FROM platform.sweep_coverage_daily c WHERE c.day = (r.inserted_at)::date
      )
    ) gaps
    """

    case Repo.query(query, []) do
      {:ok, %{rows: [[%Date{} = day]]}} -> {:ok, day}
      {:ok, %{rows: [[nil]]}} -> {:ok, nil}
      {:ok, %{rows: rows}} -> {:error, {:unexpected_result, rows}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Clamps the retention-driven cutoff so it never reaches an unrolled day.
  # No un-rolled day means retention alone governs. An un-rolled day D
  # means the cutoff is `min(requested_cutoff, midnight of D)`, so D and
  # every later day survive this run regardless of whether a later day
  # happens to already be rolled up -- deleting past a gap is exactly what
  # destroys history.
  #
  # A watermark query that FAILS is the third, deliberately distinct,
  # outcome: deleting on an unknown watermark is the destructive
  # direction, so this returns `:skip` rather than falling back to
  # `requested_cutoff` (fail open) or a fabricated cutoff. The caller
  # skips the host-result delete entirely for the run; retention and
  # executions/coverage cleanup are unaffected.
  @spec clamp_host_results_cutoff(pos_integer()) :: {:ok, DateTime.t()} | :skip
  defp clamp_host_results_cutoff(host_results_days) do
    requested_cutoff = DateTime.add(DateTime.utc_now(), -host_results_days * 86_400, :second)

    case earliest_unrolled_day() do
      {:ok, nil} ->
        {:ok, requested_cutoff}

      {:ok, day} ->
        gap_cutoff = DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")
        clamped = Enum.min([requested_cutoff, gap_cutoff], DateTime)

        if DateTime.before?(clamped, requested_cutoff) do
          Logger.warning(
            "SweepDataCleanupWorker: Host-result delete held back by an unrolled day - " <>
              "#{Date.to_iso8601(day)} has sweep_host_results rows but no " <>
              "platform.sweep_coverage_daily row yet; deleting at or past it would destroy " <>
              "the only durable record of which sweep group and agent produced those results"
          )
        end

        {:ok, clamped}

      {:error, reason} ->
        Logger.error(
          "SweepDataCleanupWorker: Host-result delete SKIPPED this run - the rollup " <>
            "watermark query failed (#{inspect(reason)}), so the earliest unrolled day is " <>
            "unknown. Deleting on an unknown watermark risks destroying the only durable " <>
            "record of which sweep group and agent produced unrolled results; the guard " <>
            "fails closed instead. Executions and coverage-rollup cleanup are unaffected " <>
            "and this will retry on the next scheduled run."
        )

        :skip
    end
  end

  defp schedule_next_cleanup do
    case ObanSupport.safe_insert(
           SelfScheduling.successor_changeset(__MODULE__, %{}, @reschedule_interval_seconds)
         ) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Sweep data cleanup reschedule deferred", reason: inspect(reason))
        :ok
    end
  end

  defp cleanup_data(host_results_cutoff, executions_cutoff, coverage_cutoff, batch_size) do
    host_result_stats = cleanup_host_results(host_results_cutoff, batch_size)
    execution_stats = cleanup_executions(executions_cutoff, batch_size)
    coverage_stats = cleanup_coverage_rollups(coverage_cutoff, batch_size)

    %{
      host_results: host_result_stats.deleted,
      executions: execution_stats.deleted,
      coverage_rollups: coverage_stats.deleted,
      errors: host_result_stats.errors + execution_stats.errors + coverage_stats.errors
    }
  end

  # `:skip` means `clamp_host_results_cutoff/1` could not determine the
  # rollup watermark and, per its fail-closed contract, chose not to
  # delete anything rather than delete on an unknown watermark. Counted
  # as an error so it surfaces in the run's completion log.
  defp cleanup_host_results(:skip, _batch_size) do
    %{deleted: 0, errors: 1}
  end

  defp cleanup_host_results({:ok, cutoff}, batch_size) do
    cleanup_in_batches(SweepHostResult, :inserted_at, cutoff, batch_size)
  end

  defp cleanup_executions(cutoff, batch_size) do
    # Only delete completed/failed executions, not running ones
    cleanup_in_batches(
      SweepGroupExecution,
      :started_at,
      cutoff,
      batch_size,
      fn query ->
        from(e in query,
          as: :execution,
          where: e.status in [:completed, :failed],
          where:
            not exists(
              from(r in SweepHostResult,
                where: r.execution_id == parent_as(:execution).id,
                select: 1
              )
            )
        )
      end
    )
  end

  defp cleanup_in_batches(resource, timestamp_field, cutoff, batch_size, extra_filter \\ nil) do
    table = get_table_name(resource)

    do_cleanup_batch(
      table,
      resource,
      timestamp_field,
      cutoff,
      batch_size,
      extra_filter,
      %{deleted: 0, errors: 0}
    )
  end

  defp do_cleanup_batch(table, resource, timestamp_field, cutoff, batch_size, extra_filter, acc) do
    # Build query to find IDs of records to delete
    base_query =
      from(r in {table, resource},
        where: field(r, ^timestamp_field) < ^cutoff,
        order_by: [asc: field(r, ^timestamp_field)],
        select: r.id,
        limit: ^batch_size
      )

    query =
      if extra_filter do
        extra_filter.(base_query)
      else
        base_query
      end

    case Repo.all(query) do
      [] ->
        # No more records to delete
        acc

      ids when is_list(ids) ->
        # Delete by IDs
        delete_query =
          from(r in {table, resource},
            where: r.id in ^ids
          )

        delete_query = if extra_filter, do: extra_filter.(delete_query), else: delete_query

        {count, _} = Repo.delete_all(delete_query)
        Logger.debug("SweepDataCleanupWorker: Deleted #{count} #{table} records")

        # Continue with next batch
        do_cleanup_batch(
          table,
          resource,
          timestamp_field,
          cutoff,
          batch_size,
          extra_filter,
          %{acc | deleted: acc.deleted + count}
        )
    end
  rescue
    e ->
      Logger.warning(
        "SweepDataCleanupWorker: Error cleaning #{table}",
        error: inspect(e)
      )

      %{acc | errors: acc.errors + 1}
  end

  defp get_table_name(SweepHostResult), do: "sweep_host_results"
  defp get_table_name(SweepGroupExecution), do: "sweep_group_executions"

  # platform.sweep_coverage_daily has no Ash resource or Ecto schema of its
  # own (Task 3's rollup worker writes it with raw SQL), so it is deleted
  # from a schemaless query keyed on the `day` column rather than through
  # `cleanup_in_batches/5`, which requires a resource module.
  defp cleanup_coverage_rollups(cutoff_date, batch_size) do
    do_cleanup_coverage_batch(cutoff_date, batch_size, %{deleted: 0, errors: 0})
  end

  defp do_cleanup_coverage_batch(cutoff_date, batch_size, acc) do
    ids_query =
      from(r in "sweep_coverage_daily",
        prefix: "platform",
        where: r.day < ^cutoff_date,
        order_by: [asc: r.day],
        limit: ^batch_size,
        select: r.id
      )

    delete_query =
      from(r in "sweep_coverage_daily",
        prefix: "platform",
        where: r.id in subquery(ids_query)
      )

    case Repo.delete_all(delete_query) do
      {0, _} ->
        acc

      {count, _} ->
        Logger.debug("SweepDataCleanupWorker: Deleted #{count} sweep_coverage_daily records")

        do_cleanup_coverage_batch(cutoff_date, batch_size, %{acc | deleted: acc.deleted + count})
    end
  rescue
    e ->
      Logger.warning(
        "SweepDataCleanupWorker: Error cleaning sweep_coverage_daily",
        error: inspect(e)
      )

      %{acc | errors: acc.errors + 1}
  end
end
