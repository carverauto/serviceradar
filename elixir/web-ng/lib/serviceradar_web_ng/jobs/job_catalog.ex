defmodule ServiceRadarWebNG.Jobs.JobCatalog do
  @moduledoc """
  Unified catalog of background jobs from all sources.

  This module provides a unified view of:
  1. Oban.Plugins.Cron jobs (config-based system maintenance)
  2. AshOban triggered jobs (resource-based scheduled actions)
  3. Self-scheduling workers (workers that implement `ensure_scheduled/0` and re-schedule themselves)

  The old ng_job_schedules table approach is deprecated in favor of:
  - Using Oban.Plugins.Cron for simple, fixed-schedule maintenance jobs
  - Using AshOban triggers for resource-action based scheduling
  - Using self-scheduling workers for dynamic/feature-gated periodic work (e.g. netflow enrichment)
  """

  alias Oban.Cron.Expression
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Monitoring.Alert
  alias ServiceRadar.Monitoring.PollingSchedule
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Oban.Router

  require Logger

  @type job_entry :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          source: :cron_plugin | :ash_oban | :self_scheduling,
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
  """
  @spec list_all_jobs() :: [job_entry()]
  def list_all_jobs do
    cron_jobs() ++ ash_oban_jobs() ++ self_scheduling_jobs()
  end

  @doc """
  Get a single job by its ID.
  """
  @spec get_job(String.t()) :: {:ok, job_entry()} | {:error, :not_found}
  def get_job(id) do
    case Enum.find(list_all_jobs(), &(&1.id == id)) do
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
  @spec list_jobs(keyword()) :: [job_entry()] | {[job_entry()], non_neg_integer()}
  def list_jobs(filters \\ []) do
    jobs =
      list_all_jobs()
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

  defp maybe_sort(jobs, field, dir) when field in [:name, :source, :cron, :last_run_at, :next_run_at] do
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
    Enum.flat_map(ash_oban_resources(), &resource_triggers/1)
  end

  @doc """
  List periodic jobs implemented as self-scheduling workers.

  These workers aren't configured in `Oban.Plugins.Cron` and aren't AshOban triggers; instead
  they insert their next run from `perform/1` and expose `ensure_scheduled/0` to seed the first run.
  """
  @spec self_scheduling_jobs() :: [job_entry()]
  def self_scheduling_jobs do
    Enum.map(self_scheduling_workers(), fn worker ->
      %{
        id: "self:#{inspect(worker)}",
        name: worker_name(worker),
        description: worker_description(worker),
        source: :self_scheduling,
        cron: self_schedule_hint(worker),
        queue: worker_queue(worker),
        enabled: worker_seeded?(worker),
        worker: worker,
        resource: nil,
        action: nil,
        last_run_at: get_last_run(worker),
        next_run_at: next_scheduled_at(worker)
      }
    end)
  end

  defp ash_oban_resources do
    [
      PollingSchedule,
      ServiceCheck,
      Alert,
      OnboardingPackage
    ]
  end

  defp resource_triggers(resource) do
    case AshOban.Info.oban_triggers(resource) do
      {:ok, triggers} ->
        Enum.map(triggers, &trigger_entry(resource, &1))

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp trigger_entry(resource, trigger) do
    %{
      id: "ash_oban:#{resource_id(resource)}:#{trigger.name}",
      name: "#{resource_label(resource)}: #{humanize_trigger_name(trigger.name)}",
      description: resource_description(resource),
      source: :ash_oban,
      cron: trigger.scheduler_cron,
      queue: trigger.queue,
      enabled: true,
      worker: trigger.worker_module_name,
      resource: resource,
      action: trigger.action,
      last_run_at: nil,
      next_run_at: next_run_at(trigger.scheduler_cron)
    }
  end

  @doc """
  Get recent job runs for a worker.

  ## Options
  - `:limit` - maximum number of runs to return (default: 5)
  """
  @spec get_recent_runs(module(), keyword()) :: [map()]
  def get_recent_runs(worker, opts \\ []) do
    import Ecto.Query

    limit = Keyword.get(opts, :limit, 5)
    worker_str = inspect(worker)

    try do
      Oban.Job
      |> where([j], j.worker == ^worker_str)
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
    job = worker.new(%{})
    Oban.insert(job)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # For AshOban, we insert the scheduler worker which will process due records
  def trigger_job(%{source: :ash_oban, worker: worker}) when not is_nil(worker) do
    job = worker.new(%{})
    Router.insert(job)
  rescue
    e -> {:error, Exception.message(e)}
  end

  def trigger_job(%{source: :self_scheduling, worker: worker}) when not is_nil(worker) do
    job = worker.new(%{})
    Router.insert(job)
  rescue
    e -> {:error, Exception.message(e)}
  end

  def trigger_job(_job), do: {:error, :no_worker}

  @doc """
  Get execution statistics for a worker over a time period.

  Returns hourly buckets of job execution counts by state.

  ## Options
  - `:hours` - number of hours to look back (default: 24)
  """
  @spec get_execution_stats(module(), keyword()) :: [map()]
  def get_execution_stats(worker, opts \\ []) do
    import Ecto.Query

    hours = Keyword.get(opts, :hours, 24)
    worker_str = inspect(worker)

    try do
      since = DateTime.add(DateTime.utc_now(), -hours, :hour)

      # Get all jobs in the time range
      jobs =
        Oban.Job
        |> where([j], j.worker == ^worker_str)
        |> where([j], j.inserted_at >= ^since)
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

  ## Options
  - `:hours` - number of hours to look back (default: 24)
  """
  @spec get_aggregated_stats(module(), keyword()) :: map()
  def get_aggregated_stats(worker, opts \\ []) do
    import Ecto.Query

    hours = Keyword.get(opts, :hours, 24)
    worker_str = inspect(worker)

    try do
      since = DateTime.add(DateTime.utc_now(), -hours, :hour)

      stats =
        Oban.Job
        |> where([j], j.worker == ^worker_str)
        |> where([j], j.inserted_at >= ^since)
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

      avg_duration = if durations == [], do: nil, else: Enum.sum(durations) / length(durations)

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
    plugins =
      case get_oban_plugins() do
        plugins when is_list(plugins) -> plugins
        _ -> []
      end

    plugins
    |> Enum.find_value(fn
      {Oban.Plugins.Cron, opts} when is_list(opts) -> Keyword.get(opts, :crontab, [])
      _ -> nil
    end)
    |> case do
      crontab when is_list(crontab) -> crontab
      _ -> nil
    end
  end

  defp get_oban_plugins do
    plugins =
      case coordinator_node() do
        {:ok, node} ->
          case :rpc.call(node, Oban, :config, [Oban]) do
            %Oban.Config{plugins: plugins} when is_list(plugins) -> plugins
            _ -> []
          end

        :error ->
          case Application.get_env(:serviceradar_core, Oban, []) do
            oban_config when is_list(oban_config) ->
              Keyword.get(oban_config, :plugins, [])

            _ ->
              # Some environments set `config :serviceradar_core, Oban, false` to disable Oban.
              []
          end
      end

    if is_list(plugins), do: plugins, else: []
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

  defp resource_label(resource) when is_atom(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp resource_id(resource) when is_atom(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp resource_description(PollingSchedule), do: "Executes polling schedules for service checks"

  defp resource_description(ServiceCheck), do: "Executes scheduled service checks"

  defp resource_description(Alert), do: "Sends alert notifications for active alert rules"

  defp resource_description(OnboardingPackage), do: "Expires edge onboarding packages"

  defp resource_description(_), do: "Executes scheduled actions for Ash resources"

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

  defp next_scheduled_at(worker) when is_atom(worker) do
    import Ecto.Query

    try do
      Oban.Job
      |> where([j], j.worker == ^inspect(worker))
      |> where([j], j.state == "scheduled")
      |> order_by([j], asc: j.scheduled_at)
      |> limit(1)
      |> select([j], j.scheduled_at)
      |> ServiceRadar.Repo.one(prefix: oban_prefix())
    rescue
      _ -> nil
    end
  end

  defp worker_seeded?(worker) when is_atom(worker) do
    import Ecto.Query

    try do
      Oban.Job
      |> where([j], j.worker == ^inspect(worker))
      |> where([j], j.state in ["available", "scheduled", "executing", "retryable"])
      |> limit(1)
      |> ServiceRadar.Repo.exists?(prefix: oban_prefix())
    rescue
      _ -> false
    end
  end

  defp oban_prefix do
    case Application.get_env(:serviceradar_core, Oban) do
      config when is_list(config) -> Keyword.get(config, :prefix, "platform")
      _ -> "platform"
    end
  rescue
    _ -> "platform"
  end

  defp worker_queue(worker) when is_atom(worker) do
    case worker.__info__(:attributes) do
      attrs when is_list(attrs) ->
        case Keyword.get(attrs, :oban_worker) do
          [{opts}] when is_list(opts) -> Keyword.get(opts, :queue, :default)
          _ -> :default
        end

      _ ->
        :default
    end
  rescue
    _ -> :default
  end

  defp self_schedule_hint(worker) when is_atom(worker) do
    config = Application.get_env(:serviceradar_core, worker, [])

    case Keyword.get(config, :reschedule_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> "every #{format_seconds(seconds)}"
      _ -> "self"
    end
  rescue
    _ -> "self"
  end

  defp format_seconds(seconds) when is_integer(seconds) and seconds > 0 do
    cond do
      rem(seconds, 3600) == 0 -> "#{div(seconds, 3600)}h"
      rem(seconds, 60) == 0 -> "#{div(seconds, 60)}m"
      true -> "#{seconds}s"
    end
  end

  defp self_scheduling_workers do
    [
      # Inventory + cleanup
      ServiceRadar.Inventory.InterfaceThresholdWorker,
      ServiceRadar.Inventory.DeviceCleanupWorker,
      ServiceRadar.Edge.AgentCommandCleanupWorker,

      # Observability / netflow periodic workers
      ServiceRadar.Observability.GeoLiteMmdbDownloadWorker,
      ServiceRadar.Observability.IpinfoMmdbDownloadWorker,
      ServiceRadar.Observability.IpEnrichmentRefreshWorker,
      ServiceRadar.Observability.IpEnrichmentCleanupWorker,
      ServiceRadar.Observability.NetflowExporterCacheRefreshWorker,
      ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker,
      ServiceRadar.Observability.ThreatIntelFeedRefreshWorker,
      ServiceRadar.Observability.NetflowSecurityRefreshWorker,
      ServiceRadar.Observability.StatefulAlertCleanupWorker,

      # Sweep jobs
      ServiceRadar.SweepJobs.SweepMonitorWorker,
      ServiceRadar.SweepJobs.SweepDataCleanupWorker
    ]
  end

  # Calculate next run time from cron expression
  defp next_run_at(nil), do: nil

  defp next_run_at(cron) when is_binary(cron) do
    case Expression.parse(cron) do
      {:ok, expr} ->
        now = DateTime.utc_now()

        case Expression.next_at(expr, now) do
          %DateTime{} = next -> next
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
