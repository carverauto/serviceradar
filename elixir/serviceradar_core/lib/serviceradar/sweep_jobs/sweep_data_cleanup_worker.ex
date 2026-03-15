defmodule ServiceRadar.SweepJobs.SweepDataCleanupWorker do
  @moduledoc """
  Worker that cleans up old sweep execution data.

  This worker runs daily to delete:
  - `SweepHostResult` records older than `host_results_retention_days` (default: 7)
  - `SweepGroupExecution` records older than `executions_retention_days` (default: 30)

  Host results are deleted first to avoid foreign key issues, then orphaned
  executions are removed.

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
        batch_size: 1000
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  import Ecto.Query

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadar.SweepJobs.SweepGroupExecution
  alias ServiceRadar.SweepJobs.SweepHostResult

  require Logger

  @default_host_results_retention_days 7
  @default_executions_retention_days 30
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

    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    host_results_cutoff = DateTime.add(DateTime.utc_now(), -host_results_days * 86_400, :second)
    executions_cutoff = DateTime.add(DateTime.utc_now(), -executions_days * 86_400, :second)

    Logger.info(
      "SweepDataCleanupWorker: Starting cleanup - " <>
        "host results older than #{host_results_days} days, " <>
        "executions older than #{executions_days} days"
    )

    stats = cleanup_data(host_results_cutoff, executions_cutoff, batch_size)

    Logger.info(
      "SweepDataCleanupWorker: Completed - " <>
        "deleted #{stats.host_results} host results, " <>
        "#{stats.executions} executions",
      errors: stats.errors
    )

    # Reschedule for tomorrow
    schedule_next_cleanup()

    :ok
  end

  defp schedule_next_cleanup do
    case ObanSupport.safe_insert(new(%{}, schedule_in: @reschedule_interval_seconds)) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Sweep data cleanup reschedule deferred", reason: inspect(reason))
        :ok
    end
  end

  defp cleanup_data(host_results_cutoff, executions_cutoff, batch_size) do
    host_result_stats = cleanup_host_results(host_results_cutoff, batch_size)
    execution_stats = cleanup_executions(executions_cutoff, batch_size)

    %{
      host_results: host_result_stats.deleted,
      executions: execution_stats.deleted,
      errors: host_result_stats.errors + execution_stats.errors
    }
  end

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
end
