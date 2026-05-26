defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorker do
  @moduledoc """
  Oban worker that executes a single Armis northbound update run for one
  IntegrationSource.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:integration_source_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_stale_run_cutoff_seconds 120

  @spec enqueue_now(String.t() | Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_now(integration_source_id) do
    enqueue(integration_source_id, manual?: true)
  end

  @spec enqueue_recurring(String.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_recurring(integration_source_id, opts \\ []) do
    schedule_in = Keyword.get(opts, :schedule_in, 0)
    enqueue(integration_source_id, manual?: false, schedule_in: schedule_in)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"integration_source_id" => integration_source_id} = args,
        id: oban_job_id
      }) do
    actor = SystemActor.system(:armis_northbound_run_worker)
    manual? = Map.get(args, "manual", false)

    Logger.info("Executing Armis northbound job",
      integration_source_id: integration_source_id,
      oban_job_id: oban_job_id,
      manual: manual?
    )

    case load_source(integration_source_id, actor) do
      {:ok, source} ->
        source
        |> runner().run_for_source(
          actor: actor,
          oban_job_id: oban_job_id,
          manual?: manual?
        )
        |> case do
          {:ok, _result} ->
            Logger.info("Armis northbound job completed",
              integration_source_id: integration_source_id,
              oban_job_id: oban_job_id
            )

            :ok

          {:error, result} ->
            Logger.warning("Armis northbound job recorded failure",
              integration_source_id: integration_source_id,
              oban_job_id: oban_job_id,
              reason: failure_reason(result),
              device_count: failure_count(result, :device_count),
              updated_count: failure_count(result, :updated_count),
              error_count: failure_count(result, :error_count)
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning("Armis northbound job could not load integration source",
          integration_source_id: integration_source_id,
          oban_job_id: oban_job_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp load_source(integration_source_id, actor) do
    with {:ok, source} <- source_module().get_by_id(integration_source_id, actor: actor) do
      load_source_credentials(source, actor)
    end
  end

  defp load_source_credentials(%IntegrationSource{} = source, actor) do
    Ash.load(source, [:credentials_encrypted, :credentials], actor: actor)
  end

  defp load_source_credentials(source, _actor), do: {:ok, source}

  defp enqueue(integration_source_id, opts) do
    if support_module().available?() do
      integration_source_id = to_string(integration_source_id)
      reap_stale_source_jobs(integration_source_id)

      integration_source_id
      |> args_for(Keyword.get(opts, :manual?, false))
      |> new(schedule_opts(opts))
      |> support_module().safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  defp args_for(integration_source_id, manual?) do
    %{
      "integration_source_id" => to_string(integration_source_id),
      "manual" => manual?
    }
  end

  defp schedule_opts(opts) do
    []
    |> maybe_replace_scheduled_conflict(Keyword.get(opts, :manual?, false))
    |> maybe_schedule_in(Keyword.get(opts, :schedule_in, 0))
  end

  defp maybe_replace_scheduled_conflict(opts, true) do
    Keyword.put(opts, :replace,
      scheduled: [:args, :scheduled_at],
      available: [:args],
      retryable: [:args, :scheduled_at]
    )
  end

  defp maybe_replace_scheduled_conflict(opts, _manual?), do: opts

  defp maybe_schedule_in(opts, schedule_in) do
    case schedule_in do
      seconds when is_integer(seconds) and seconds > 0 -> Keyword.put(opts, :schedule_in, seconds)
      _ -> opts
    end
  end

  defp reap_stale_source_jobs(integration_source_id) do
    cutoff_seconds = stale_run_cutoff_seconds()
    now = DateTime.utc_now()

    case reap_stale_jobs_fun().(__MODULE__, integration_source_id, now, cutoff_seconds) do
      {count, _} when is_integer(count) and count > 0 ->
        Logger.warning("Reaped stale Armis northbound jobs before enqueue",
          integration_source_id: integration_source_id,
          stale_job_count: count,
          stale_run_cutoff_seconds: cutoff_seconds
        )

      _ ->
        :ok
    end

    :ok
  rescue
    error ->
      Logger.warning("Failed to reap stale Armis northbound jobs before enqueue",
        integration_source_id: integration_source_id,
        error: Exception.message(error)
      )

      :ok
  end

  defp default_reap_stale_source_jobs(worker, integration_source_id, now, cutoff_seconds) do
    worker_name = inspect(worker)
    cutoff = DateTime.add(now, -cutoff_seconds, :second)
    prefix = support_module().prefix()

    Oban.Job
    |> where([j], j.worker == ^worker_name)
    |> where([j], j.state == "executing")
    |> where([j], not is_nil(j.attempted_at) and j.attempted_at < ^cutoff)
    |> where(
      [j],
      fragment("? ->> ? = ?", j.args, ^"integration_source_id", ^to_string(integration_source_id))
    )
    |> ServiceRadar.Repo.update_all(set: [state: "discarded", discarded_at: now], prefix: prefix)
  rescue
    _ -> {0, nil}
  end

  defp failure_reason(%{result: %{error_message: message}}) when is_binary(message), do: message
  defp failure_reason(%{result: %{errors: errors}}), do: inspect(errors)
  defp failure_reason(reason), do: inspect(reason)

  defp failure_count(%{result: result}, key) when is_map(result), do: Map.get(result, key)
  defp failure_count(_result, _key), do: nil

  defp runner do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_runner,
      ArmisNorthboundRunner
    )
  end

  defp source_module do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_source_module,
      IntegrationSource
    )
  end

  defp support_module do
    Application.get_env(:serviceradar_core, :armis_northbound_oban_support_module, ObanSupport)
  end

  defp stale_run_cutoff_seconds do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_stale_run_cutoff_seconds,
      @default_stale_run_cutoff_seconds
    )
  end

  defp reap_stale_jobs_fun do
    Application.get_env(
      :serviceradar_core,
      :armis_northbound_reap_stale_jobs_fun,
      &default_reap_stale_source_jobs/4
    )
  end
end
