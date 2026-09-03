defmodule ServiceRadar.SweepJobs.SweepDataCleanupWorker do
  @moduledoc """
  Worker that cleans up old sweep execution data.

  This worker runs daily to delete:
  - `SweepHostResult` records older than `host_results_retention_days` (default: 7)
  - `SweepGroupExecution` records older than `executions_retention_days` (default: 30)
  - `platform.sweep_coverage_daily` rows older than `rollup_retention_days` (default: 400)

  Host results are deleted first to avoid foreign key issues, then orphaned
  executions are removed.

  ## Rollup watermark guard

  Host results are never deleted past the rollup watermark: the last day
  `ServiceRadar.SweepJobs.SweepCoverageRollupWorker` has actually written to
  `platform.sweep_coverage_daily`. Deleting a day the rollup has not yet
  covered would destroy the only durable record of which sweep group and
  agent produced those results. If nothing has ever been rolled up, the
  host-result delete is skipped entirely for this run (logged), rather than
  falling back to the unguarded retention cutoff.

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
        "host results older than #{host_results_days} days (clamped to rollup watermark), " <>
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

  # The last day fully covered by the rollup. Host results may only be
  # deleted up to this point, because deleting an unrolled day destroys the
  # only durable record of which sweep group and agent produced those
  # results.
  defp rollup_watermark do
    case Repo.query("SELECT MAX(day) FROM platform.sweep_coverage_daily", []) do
      {:ok, %{rows: [[%Date{} = day]]}} ->
        DateTime.new!(Date.add(day, 1), ~T[00:00:00.000000], "Etc/UTC")

      _ ->
        nil
    end
  end

  # Clamps the retention-driven cutoff to whatever the rollup has actually
  # covered. `nil` means nothing has ever been rolled up: skip the
  # host-result delete entirely rather than falling back to the unguarded
  # retention cutoff, because an empty rollup table is precisely when
  # deleting is most destructive. Log the skip explicitly -- a silent skip
  # here is indistinguishable from a working delete.
  defp clamp_host_results_cutoff(host_results_days) do
    requested_cutoff = DateTime.add(DateTime.utc_now(), -host_results_days * 86_400, :second)

    case rollup_watermark() do
      nil ->
        Logger.info(
          "SweepDataCleanupWorker: Skipping host-result delete - " <>
            "no rollup watermark yet (platform.sweep_coverage_daily has no rows), " <>
            "so the retention cutoff cannot be trusted not to destroy unrolled history"
        )

        nil

      watermark ->
        Enum.min([requested_cutoff, watermark], DateTime)
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

  # A `nil` cutoff means the watermark guard decided nothing is safe to
  # delete yet (see `clamp_host_results_cutoff/1`). No-op rather than
  # falling through to an unguarded delete.
  defp cleanup_host_results(nil, _batch_size), do: %{deleted: 0, errors: 0}

  defp cleanup_host_results(cutoff, batch_size) do
    cleanup_in_batches(SweepHostResult, :inserted_at, cutoff, batch_size)
  end

  defp cleanup_executions(cutoff, batch_size) do
    # Only delete completed/failed executions, not running ones
    cleanup_in_batches(
      SweepGroupExecution,
      :started_at,
      cutoff,
      batch_size,
      fn query -> where(query, [e], e.status in [:completed, :failed]) end
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
