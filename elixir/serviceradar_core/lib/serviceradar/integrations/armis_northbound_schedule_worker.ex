defmodule ServiceRadar.Integrations.ArmisNorthboundScheduleWorker do
  @moduledoc """
  Periodic Oban worker that reconciles recurring Armis northbound jobs for all
  enabled Armis integration sources.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundObanReaper
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.ArmisNorthboundRunWorker
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_scheduler_interval_seconds 60
  @default_northbound_interval_seconds 3600
  @default_stale_run_cutoff_seconds 120

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if support_module().available?() do
      if scheduler_job_exists?() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> support_module().safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    actor = SystemActor.system(:armis_northbound_schedule_worker)
    now = now_fun().()

    case source_module().list_by_type(:armis, actor: actor) do
      {:ok, sources} ->
        Enum.each(sources, &ensure_source_job(&1, now, actor))
        schedule_next()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to load Armis integration sources for northbound scheduling",
          reason: inspect(reason)
        )

        schedule_next()
        {:error, reason}
    end
  end

  @spec seconds_until_next(map(), DateTime.t()) :: non_neg_integer()
  def seconds_until_next(source, now \\ DateTime.utc_now()) do
    interval = normalized_interval(source)

    case Map.get(source, :northbound_last_run_at) do
      %DateTime{} = last_run_at ->
        next_run_at = DateTime.add(last_run_at, interval, :second)
        max(DateTime.diff(next_run_at, now, :second), 0)

      _ ->
        0
    end
  end

  defp ensure_source_job(%{enabled: true, northbound_enabled: true} = source, now, actor) do
    reconcile_stale_source_jobs(source, now, actor)

    case load_source_credentials(source, actor) do
      {:ok, source} ->
        cond do
          source_job_exists?(source.id) ->
            :ok

          runner_module().northbound_ready?(source) != :ok ->
            :ok

          true ->
            _ =
              run_worker_module().enqueue_recurring(source.id,
                schedule_in: seconds_until_next(source, now)
              )

            :ok
        end

      {:error, reason} ->
        Logger.warning("Failed to load Armis source credentials for northbound scheduling",
          integration_source_id: inspect(Map.get(source, :id)),
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp ensure_source_job(_source, _now, _actor), do: :ok

  defp load_source_credentials(%IntegrationSource{} = source, actor) do
    Ash.load(source, [:credentials_encrypted, :credentials], actor: actor)
  end

  defp load_source_credentials(source, _actor), do: {:ok, source}

  defp reconcile_stale_source_jobs(source, now, actor) do
    cutoff_seconds = stale_run_cutoff_seconds()

    case reap_stale_jobs_fun().(run_worker_module(), source.id, now, cutoff_seconds) do
      {count, _} when is_integer(count) and count > 0 ->
        Logger.warning("Reaped stale Armis northbound jobs during scheduling",
          integration_source_id: inspect(Map.get(source, :id)),
          stale_job_count: count,
          stale_run_cutoff_seconds: cutoff_seconds
        )

      _ ->
        :ok
    end

    if function_exported?(runner_module(), :reconcile_stale_runs, 3) do
      _ =
        runner_module().reconcile_stale_runs(source, actor,
          now: now,
          stale_run_cutoff_seconds: cutoff_seconds
        )
    end

    :ok
  rescue
    error ->
      Logger.warning("Failed to reconcile stale Armis northbound jobs",
        integration_source_id: inspect(Map.get(source, :id)),
        error: Exception.message(error)
      )

      :ok
  end

  defp schedule_next do
    _ =
      support_module().safe_insert(
        SelfScheduling.successor_changeset(
          __MODULE__,
          %{},
          max(scheduler_interval_seconds(), 10)
        )
      )

    :ok
  end

  defp scheduler_interval_seconds do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_scheduler_interval_seconds,
      @default_scheduler_interval_seconds
    )
  end

  defp stale_run_cutoff_seconds do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_stale_run_cutoff_seconds,
      @default_stale_run_cutoff_seconds
    )
  end

  defp normalized_interval(source) do
    case Map.get(source, :northbound_interval_seconds, @default_northbound_interval_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _ -> @default_northbound_interval_seconds
    end
  end

  defp scheduler_job_exists? do
    active_job_exists?(__MODULE__, %{})
  end

  defp source_job_exists?(integration_source_id) do
    active_job_exists?(run_worker_module(), %{
      "integration_source_id" => to_string(integration_source_id)
    })
  end

  defp active_job_exists?(worker, args_filter) do
    active_job_exists_fun().(worker, args_filter)
  end

  defp default_active_job_exists(worker, args_filter) do
    worker_name = inspect(worker)
    prefix = support_module().prefix()

    Oban.Job
    |> where([j], j.worker == ^worker_name)
    |> where([j], j.state in ["available", "scheduled", "executing", "retryable"])
    |> maybe_filter_args(args_filter)
    |> limit(1)
    |> ServiceRadar.Repo.exists?(prefix: prefix)
  rescue
    _ -> false
  end

  defp default_reap_stale_source_jobs(worker, integration_source_id, now, cutoff_seconds),
    do:
      ArmisNorthboundObanReaper.reap_stale_source_jobs(
        worker,
        integration_source_id,
        now,
        cutoff_seconds
      )

  defp maybe_filter_args(query, args_filter) when args_filter in [%{}, nil], do: query

  defp maybe_filter_args(query, args_filter) do
    Enum.reduce(args_filter, query, fn {key, value}, scoped_query ->
      key = to_string(key)
      value = to_string(value)

      where(scoped_query, [j], fragment("? ->> ? = ?", j.args, ^key, ^value))
    end)
  end

  defp source_module do
    Application.get_env(:serviceradar_core, :armis_northbound_source_module, IntegrationSource)
  end

  defp run_worker_module do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_run_worker_module,
      ArmisNorthboundRunWorker
    )
  end

  defp runner_module do
    Application.get_env(:serviceradar_core, :armis_northbound_runner, ArmisNorthboundRunner)
  end

  defp support_module do
    Application.get_env(:serviceradar_core, :armis_northbound_oban_support_module, ObanSupport)
  end

  defp active_job_exists_fun do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_active_job_exists_fun,
      &default_active_job_exists/2
    )
  end

  defp reap_stale_jobs_fun do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_reap_stale_jobs_fun,
      &default_reap_stale_source_jobs/4
    )
  end

  defp now_fun do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_schedule_now_fun,
      &DateTime.utc_now/0
    )
  end
end
