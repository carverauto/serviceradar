defmodule ServiceRadarWebNG.Jobs.JobCatalog do
  @moduledoc """
  Unified catalog of background jobs from all sources.

  This module provides a unified view of:
  1. Oban.Plugins.Cron jobs (config-based system maintenance)
  2. AshOban triggered jobs (resource-based scheduled actions)

  The old ng_job_schedules table approach is deprecated in favor of:
  - Using Oban.Plugins.Cron for simple, fixed-schedule maintenance jobs
  - Using AshOban triggers for resource-action based scheduling
  """

  require Logger

  alias ServiceRadar.Monitoring.PollingSchedule

  @type job_entry :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          source: :cron_plugin | :ash_oban,
          cron: String.t() | nil,
          queue: atom(),
          enabled: boolean(),
          worker: module() | nil,
          resource: module() | nil,
          action: atom() | nil,
          last_run_at: DateTime.t() | nil,
          next_run_at: DateTime.t() | nil
        }

  @doc """
  List all scheduled jobs from all sources.

  ## Options
  - `:tenant_id` - scope jobs to a tenant (non-platform admins)
  - `:platform_admin?` - show platform jobs when true
  """
  @spec list_all_jobs(keyword()) :: [job_entry()]
  def list_all_jobs(opts \\ []) do
    jobs = cron_jobs() ++ ash_oban_jobs()
    filter_jobs_for_scope(jobs, opts)
  end

  @doc """
  Get a single job by its ID.
  """
  @spec get_job(String.t(), keyword()) :: {:ok, job_entry()} | {:error, :not_found}
  def get_job(id, opts \\ []) do
    case Enum.find(list_all_jobs(opts), &(&1.id == id)) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  @doc """
  List jobs with optional filters, sorting, and pagination.

  ## Options
  - `:source` - filter by :cron_plugin or :ash_oban
  - `:search` - search by name (case-insensitive)
  - `:enabled` - filter by enabled status
  - `:sort_by` - field to sort by (:name, :source, :cron, :last_run_at, :next_run_at)
  - `:sort_dir` - sort direction (:asc or :desc)
  - `:page` - page number (1-indexed)
  - `:per_page` - items per page

  Returns `{jobs, total_count}` when pagination is used, or just `jobs` otherwise.
  """
  @spec list_jobs(keyword(), keyword()) :: [job_entry()] | {[job_entry()], non_neg_integer()}
  def list_jobs(filters \\ [], opts \\ []) do
    jobs =
      list_all_jobs(opts)
      |> maybe_filter_source(filters[:source])
      |> maybe_filter_search(filters[:search])
      |> maybe_filter_enabled(filters[:enabled])
      |> maybe_sort(filters[:sort_by], filters[:sort_dir])

    case {filters[:page], filters[:per_page]} do
      {nil, _} ->
        jobs

      {_, nil} ->
        jobs

      {page, per_page} when is_integer(page) and is_integer(per_page) ->
        total = length(jobs)
        offset = (page - 1) * per_page
        paginated = jobs |> Enum.drop(offset) |> Enum.take(per_page)
        {paginated, total}
    end
  end

  defp maybe_filter_source(jobs, nil), do: jobs
  defp maybe_filter_source(jobs, source), do: Enum.filter(jobs, &(&1.source == source))

  defp maybe_filter_search(jobs, nil), do: jobs
  defp maybe_filter_search(jobs, ""), do: jobs

  defp maybe_filter_search(jobs, search) do
    search_lower = String.downcase(search)

    Enum.filter(jobs, fn job ->
      String.contains?(String.downcase(job.name), search_lower) ||
        String.contains?(String.downcase(job.description), search_lower)
    end)
  end

  defp maybe_filter_enabled(jobs, nil), do: jobs
  defp maybe_filter_enabled(jobs, enabled), do: Enum.filter(jobs, &(&1.enabled == enabled))

  defp maybe_sort(jobs, nil, _dir), do: jobs

  defp maybe_sort(jobs, field, dir)
       when field in [:name, :source, :cron, :last_run_at, :next_run_at] do
    sorter = fn job ->
      value = Map.get(job, field)
      # Handle nil values - put them at the end
      case value do
        nil -> {1, nil}
        v -> {0, v}
      end
    end

    case dir do
      :desc -> Enum.sort_by(jobs, sorter, :desc)
      _ -> Enum.sort_by(jobs, sorter, :asc)
    end
  end

  defp maybe_sort(jobs, _field, _dir), do: jobs

  defp filter_jobs_for_scope(jobs, opts) do
    platform_admin? = Keyword.get(opts, :platform_admin?, false)
    tenant_id = Keyword.get(opts, :tenant_id)

    cond do
      platform_admin? ->
        jobs

      is_binary(tenant_id) ->
        Enum.filter(jobs, &tenant_visible_job?(&1, tenant_id))

      true ->
        []
    end
  end

  defp tenant_visible_job?(%{source: :cron_plugin}, _tenant_id), do: false

  defp tenant_visible_job?(%{source: :ash_oban, resource: resource}, _tenant_id)
       when is_atom(resource) do
    tenant_scoped_resource?(resource)
  end

  defp tenant_visible_job?(_, _tenant_id), do: false

  defp tenant_scoped_resource?(resource) when is_atom(resource) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      :attribute -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp maybe_filter_tenant_runs(query, _tenant_id, true), do: query

  defp maybe_filter_tenant_runs(query, tenant_id, false) when is_binary(tenant_id) do
    import Ecto.Query

    where(
      query,
      [j],
      fragment("?->>?", j.meta, "tenant_id") == ^tenant_id or
        fragment("?->>?", j.args, "tenant_id") == ^tenant_id
    )
  end

  defp maybe_filter_tenant_runs(query, _tenant_id, false) do
    import Ecto.Query
    where(query, [j], false)
  end

  @doc """
  List jobs configured via Oban.Plugins.Cron in config.
  """
  @spec cron_jobs() :: [job_entry()]
  def cron_jobs do
    case get_cron_config() do
      nil ->
        []

      crontab ->
        Enum.map(crontab, fn entry ->
          {cron_expr, worker, opts} = parse_cron_entry(entry)

          %{
            id: "cron:#{inspect(worker)}",
            name: worker_name(worker),
            description: worker_description(worker),
            source: :cron_plugin,
            cron: cron_expr,
            queue: Keyword.get(opts, :queue, :default),
            enabled: true,
            worker: worker,
            resource: nil,
            action: nil,
            last_run_at: get_last_run(worker),
            next_run_at: next_run_at(cron_expr)
          }
        end)
    end
  end

  @doc """
  List jobs configured via AshOban triggers on resources.
  """
  @spec ash_oban_jobs() :: [job_entry()]
  def ash_oban_jobs do
    # Get AshOban triggers from known resources
    polling_schedule_triggers()
  end

  # Get polling schedule triggers
  defp polling_schedule_triggers do
    case AshOban.Info.oban_triggers(PollingSchedule) do
      {:ok, triggers} ->
        Enum.map(triggers, fn trigger ->
          %{
            id: "ash_oban:polling_schedule:#{trigger.name}",
            name: humanize_trigger_name(trigger.name),
            description: "Executes polling schedules for service checks",
            source: :ash_oban,
            cron: trigger.scheduler_cron,
            queue: trigger.queue,
            enabled: true,
            worker: trigger.worker_module_name,
            resource: PollingSchedule,
            action: trigger.action,
            last_run_at: nil,
            next_run_at: next_run_at(trigger.scheduler_cron)
          }
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Get recent job runs for a worker.
  """
  @spec get_recent_runs(module(), keyword()) :: [map()]
  def get_recent_runs(worker, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    tenant_id = Keyword.get(opts, :tenant_id)
    platform_admin? = Keyword.get(opts, :platform_admin?, false)
    worker_str = inspect(worker)

    import Ecto.Query

    try do
      Oban.Job
      |> where([j], j.worker == ^worker_str)
      |> maybe_filter_tenant_runs(tenant_id, platform_admin?)
      |> order_by([j], desc: j.inserted_at)
      |> limit(^limit)
      |> ServiceRadar.Repo.all()
    rescue
      _ -> []
    end
  end

  @doc """
  Trigger a manual run of a job.

  For cron jobs, this inserts a new job into the Oban queue.
  For AshOban jobs, this triggers the scheduled action.
  """
  @spec trigger_job(job_entry()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def trigger_job(%{source: :cron_plugin, worker: worker}) when not is_nil(worker) do
    try do
      job = worker.new(%{})
      Oban.insert(job)
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  def trigger_job(%{source: :ash_oban, worker: worker}) when not is_nil(worker) do
    # For AshOban, we insert the scheduler worker which will process due records
    try do
      job = worker.new(%{})
      Oban.insert(job)
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  def trigger_job(_job), do: {:error, :no_worker}

  @doc """
  Get execution statistics for a worker over a time period.

  Returns hourly buckets of job execution counts by state.
  """
  @spec get_execution_stats(module(), keyword()) :: [map()]
  def get_execution_stats(worker, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    tenant_id = Keyword.get(opts, :tenant_id)
    platform_admin? = Keyword.get(opts, :platform_admin?, false)
    worker_str = inspect(worker)

    import Ecto.Query

    try do
      since = DateTime.add(DateTime.utc_now(), -hours, :hour)

      # Get all jobs in the time range
      jobs =
        Oban.Job
        |> where([j], j.worker == ^worker_str)
        |> where([j], j.inserted_at >= ^since)
        |> maybe_filter_tenant_runs(tenant_id, platform_admin?)
        |> select([j], %{
          state: j.state,
          inserted_at: j.inserted_at,
          completed_at: j.completed_at
        })
        |> ServiceRadar.Repo.all()

      # Bucket by hour
      jobs
      |> Enum.group_by(fn job ->
        job.inserted_at
        |> DateTime.truncate(:second)
        |> Map.put(:minute, 0)
        |> Map.put(:second, 0)
      end)
      |> Enum.map(fn {hour, jobs_in_hour} ->
        %{
          hour: hour,
          total: length(jobs_in_hour),
          completed: Enum.count(jobs_in_hour, &(&1.state == "completed")),
          failed: Enum.count(jobs_in_hour, &(&1.state in ["discarded", "cancelled"])),
          retrying: Enum.count(jobs_in_hour, &(&1.state == "retryable"))
        }
      end)
      |> Enum.sort_by(& &1.hour, DateTime)
    rescue
      _ -> []
    end
  end

  @doc """
  Get aggregated execution stats for a worker.
  """
  @spec get_aggregated_stats(module(), keyword()) :: map()
  def get_aggregated_stats(worker, opts \\ []) do
    hours = Keyword.get(opts, :hours, 24)
    tenant_id = Keyword.get(opts, :tenant_id)
    platform_admin? = Keyword.get(opts, :platform_admin?, false)
    worker_str = inspect(worker)

    import Ecto.Query

    try do
      since = DateTime.add(DateTime.utc_now(), -hours, :hour)

      stats =
        Oban.Job
        |> where([j], j.worker == ^worker_str)
        |> where([j], j.inserted_at >= ^since)
        |> maybe_filter_tenant_runs(tenant_id, platform_admin?)
        |> select([j], %{
          state: j.state,
          attempted_at: j.attempted_at,
          completed_at: j.completed_at
        })
        |> ServiceRadar.Repo.all()

      total = length(stats)
      completed = Enum.count(stats, &(&1.state == "completed"))
      failed = Enum.count(stats, &(&1.state in ["discarded", "cancelled"]))

      # Calculate average duration for completed jobs
      durations =
        stats
        |> Enum.filter(&(&1.state == "completed" && &1.completed_at && &1.attempted_at))
        |> Enum.map(fn job ->
          DateTime.diff(job.completed_at, job.attempted_at, :millisecond)
        end)

      avg_duration = if durations != [], do: Enum.sum(durations) / length(durations), else: nil

      %{
        total: total,
        completed: completed,
        failed: failed,
        success_rate: if(total > 0, do: completed / total * 100, else: 0),
        avg_duration_ms: avg_duration
      }
    rescue
      _ -> %{total: 0, completed: 0, failed: 0, success_rate: 0, avg_duration_ms: nil}
    end
  end

  # Get Oban.Plugins.Cron configuration
  defp get_cron_config do
    plugins = get_oban_plugins()

    Enum.find_value(plugins, fn
      {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
      _ -> nil
    end)
  end

  defp get_oban_plugins do
    case coordinator_node() do
      {:ok, node} ->
        case :rpc.call(node, Oban, :config, [Oban]) do
          %Oban.Config{plugins: plugins} -> plugins
          _ -> []
        end

      :error ->
        oban_config = Application.get_env(:serviceradar_core, Oban, [])
        Keyword.get(oban_config, :plugins, [])
    end
  rescue
    _ -> []
  end

  defp coordinator_node do
    case ServiceRadar.Cluster.ClusterStatus.find_coordinator() do
      nil -> :error
      node -> {:ok, node}
    end
  rescue
    _ -> :error
  end

  # Parse a crontab entry which can be {cron, worker} or {cron, worker, opts}
  defp parse_cron_entry({cron, worker}) when is_binary(cron) and is_atom(worker) do
    {cron, worker, []}
  end

  defp parse_cron_entry({cron, worker, opts}) when is_binary(cron) and is_atom(worker) do
    {cron, worker, opts}
  end

  # Get human-readable name from worker module
  defp worker_name(worker) when is_atom(worker) do
    worker
    |> Module.split()
    |> List.last()
    |> String.replace("Worker", "")
    |> Macro.underscore()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  # Get description from worker module doc
  defp worker_description(worker) when is_atom(worker) do
    case Code.fetch_docs(worker) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} ->
        doc
        |> String.split("\n")
        |> List.first()
        |> String.trim()

      _ ->
        "No description available"
    end
  rescue
    _ -> "No description available"
  end

  # Humanize AshOban trigger name
  defp humanize_trigger_name(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  # Get last run time for a worker
  defp get_last_run(worker) when is_atom(worker) do
    import Ecto.Query

    try do
      Oban.Job
      |> where([j], j.worker == ^inspect(worker))
      |> where([j], j.state == "completed")
      |> order_by([j], desc: j.completed_at)
      |> limit(1)
      |> select([j], j.completed_at)
      |> ServiceRadar.Repo.one()
    rescue
      _ -> nil
    end
  end

  # Calculate next run time from cron expression
  defp next_run_at(nil), do: nil

  defp next_run_at(cron) when is_binary(cron) do
    case Oban.Cron.Expression.parse(cron) do
      {:ok, expr} ->
        now = DateTime.utc_now()

        case Oban.Cron.Expression.next_at(expr, now) do
          %DateTime{} = next -> next
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
