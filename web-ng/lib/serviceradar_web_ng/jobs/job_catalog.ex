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
  """
  @spec list_all_jobs() :: [job_entry()]
  def list_all_jobs do
    cron_jobs() ++ ash_oban_jobs()
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
    worker_str = inspect(worker)

    import Ecto.Query

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

  # Get Oban.Plugins.Cron configuration
  defp get_cron_config do
    oban_config = Application.get_env(:serviceradar_core, Oban, [])
    plugins = Keyword.get(oban_config, :plugins, [])

    Enum.find_value(plugins, fn
      {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
      _ -> nil
    end)
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
