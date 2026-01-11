defmodule ServiceRadar.SweepJobs.SweepDataCleanupWorker do
  @moduledoc """
  Cleans up old sweep execution data to prevent unbounded table growth.

  This worker runs periodically to delete:
  - `SweepHostResult` records older than `host_results_retention_days` (default: 7)
  - `SweepGroupExecution` records older than `executions_retention_days` (default: 30)

  Host results are deleted first to avoid foreign key issues, then orphaned
  executions are removed.

  ## Configuration

  Retention periods can be configured via application config:

      config :serviceradar_core, ServiceRadar.SweepJobs.SweepDataCleanupWorker,
        host_results_retention_days: 7,
        executions_retention_days: 30,
        batch_size: 1000

  ## Scheduling

  This worker is scheduled via Oban cron plugin:

      {Oban.Plugins.Cron,
       crontab: [
         {"0 3 * * *", ServiceRadar.SweepJobs.SweepDataCleanupWorker, queue: :maintenance}
       ]}
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.{SweepGroupExecution, SweepHostResult}

  import Ecto.Query

  require Logger

  @default_host_results_retention_days 7
  @default_executions_retention_days 30
  @default_batch_size 1000

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])

    host_results_days = Keyword.get(config, :host_results_retention_days, @default_host_results_retention_days)
    executions_days = Keyword.get(config, :executions_retention_days, @default_executions_retention_days)
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    host_results_cutoff = DateTime.add(DateTime.utc_now(), -host_results_days * 86_400, :second)
    executions_cutoff = DateTime.add(DateTime.utc_now(), -executions_days * 86_400, :second)

    Logger.info(
      "SweepDataCleanupWorker: Starting cleanup - " <>
        "host results older than #{host_results_days} days, " <>
        "executions older than #{executions_days} days"
    )

    total_stats =
      TenantSchemas.list_schemas()
      |> Enum.reduce(%{host_results: 0, executions: 0, errors: 0}, fn schema, acc ->
        stats = cleanup_tenant(schema, host_results_cutoff, executions_cutoff, batch_size)
        %{
          host_results: acc.host_results + stats.host_results,
          executions: acc.executions + stats.executions,
          errors: acc.errors + stats.errors
        }
      end)

    Logger.info(
      "SweepDataCleanupWorker: Completed - " <>
        "deleted #{total_stats.host_results} host results, " <>
        "#{total_stats.executions} executions, " <>
        "#{total_stats.errors} errors"
    )

    :ok
  end

  defp cleanup_tenant(schema, host_results_cutoff, executions_cutoff, batch_size) do
    host_result_stats = cleanup_host_results(schema, host_results_cutoff, batch_size)
    execution_stats = cleanup_executions(schema, executions_cutoff, batch_size)

    %{
      host_results: host_result_stats.deleted,
      executions: execution_stats.deleted,
      errors: host_result_stats.errors + execution_stats.errors
    }
  end

  defp cleanup_host_results(schema, cutoff, batch_size) do
    cleanup_in_batches(schema, SweepHostResult, :inserted_at, cutoff, batch_size)
  end

  defp cleanup_executions(schema, cutoff, batch_size) do
    # Only delete completed/failed executions, not running ones
    cleanup_in_batches(
      schema,
      SweepGroupExecution,
      :started_at,
      cutoff,
      batch_size,
      fn query -> where(query, [e], e.status in [:completed, :failed]) end
    )
  end

  defp cleanup_in_batches(schema, resource, timestamp_field, cutoff, batch_size, extra_filter \\ nil) do
    table = get_table_name(resource)

    do_cleanup_batch(schema, table, resource, timestamp_field, cutoff, batch_size, extra_filter, %{deleted: 0, errors: 0})
  end

  defp do_cleanup_batch(schema, table, resource, timestamp_field, cutoff, batch_size, extra_filter, acc) do
    # Build query to find IDs of records to delete
    base_query =
      from(r in {schema <> "." <> table, resource},
        where: field(r, ^timestamp_field) < ^cutoff,
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
          from(r in {schema <> "." <> table, resource},
            where: r.id in ^ids
          )

        case Repo.delete_all(delete_query) do
          {count, _} ->
            Logger.debug(
              "SweepDataCleanupWorker: Deleted #{count} #{table} records from #{schema}"
            )

            # Continue with next batch
            do_cleanup_batch(
              schema,
              table,
              resource,
              timestamp_field,
              cutoff,
              batch_size,
              extra_filter,
              %{acc | deleted: acc.deleted + count}
            )
        end
    end
  rescue
    e ->
      Logger.warning(
        "SweepDataCleanupWorker: Error cleaning #{table} in #{schema}: #{inspect(e)}"
      )

      %{acc | errors: acc.errors + 1}
  end

  defp get_table_name(SweepHostResult), do: "sweep_host_results"
  defp get_table_name(SweepGroupExecution), do: "sweep_group_executions"
end
