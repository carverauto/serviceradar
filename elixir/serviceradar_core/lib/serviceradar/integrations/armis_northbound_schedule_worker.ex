defmodule ServiceRadar.Integrations.ArmisNorthboundScheduleWorker do
  @moduledoc """
  Periodic Oban worker that reconciles recurring Armis northbound jobs for all
  enabled Armis integration sources.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.ArmisNorthboundRunWorker
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_scheduler_interval_seconds 60
  @default_northbound_interval_seconds 3600

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
        Enum.each(sources, &ensure_source_job(&1, now))
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

  defp ensure_source_job(%{enabled: true, northbound_enabled: true} = source, now) do
    cond do
      recurring_job_exists?(source.id) ->
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
  end

  defp ensure_source_job(_source, _now), do: :ok

  defp schedule_next do
    _ =
      support_module().safe_insert(new(%{}, schedule_in: max(scheduler_interval_seconds(), 10)))

    :ok
  end

  defp scheduler_interval_seconds do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_scheduler_interval_seconds,
      @default_scheduler_interval_seconds
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

  defp recurring_job_exists?(integration_source_id) do
    active_job_exists?(run_worker_module(), %{
      "integration_source_id" => to_string(integration_source_id),
      "manual" => false
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

  defp now_fun do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_schedule_now_fun,
      &DateTime.utc_now/0
    )
  end
end
