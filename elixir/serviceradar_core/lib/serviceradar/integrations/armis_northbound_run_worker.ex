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
      states: :incomplete
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundObanReaper
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

            # Surface authentication/authorization failures (e.g. a rejected
            # access token) to Oban so the job retries with backoff and shows up
            # as a failed job for alerting. Other failures (partial progress,
            # per-device rejections, transient upstream errors) stay handled
            # (`:ok`) so they don't churn the 3-attempt retry budget.
            if auth_failure?(result) do
              {:error, {:armis_northbound_auth_failed, failure_reason(result)}}
            else
              :ok
            end
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
      |> build_job(opts)
      |> support_module().safe_insert(stale_conflict_cutoff_seconds: stale_run_cutoff_seconds())
    else
      {:error, :oban_unavailable}
    end
  end

  defp build_job(integration_source_id, opts) do
    integration_source_id
    |> args_for(Keyword.get(opts, :manual?, false))
    |> new(schedule_opts(opts))
  end

  defp args_for(integration_source_id, manual?) do
    %{
      "integration_source_id" => to_string(integration_source_id),
      "manual" => manual?
    }
  end

  defp schedule_opts(opts) do
    manual? = Keyword.get(opts, :manual?, false)

    []
    |> maybe_replace_scheduled_conflict(manual?)
    |> put_run_at(manual?, Keyword.get(opts, :schedule_in, 0))
  end

  defp maybe_replace_scheduled_conflict(opts, true) do
    Keyword.put(opts, :replace,
      scheduled: [:args, :scheduled_at],
      available: [:args],
      retryable: [:args, :scheduled_at]
    )
  end

  defp maybe_replace_scheduled_conflict(opts, _manual?), do: opts

  # A manual "Run now" must execute immediately even though the scheduler always
  # keeps the next recurring run sitting in the `scheduled` state. The conflict
  # `replace` above only bumps fields that are present in the *new* job's
  # changeset changes — Oban.Engines.Basic.resolve_conflict/4 does
  # `Map.take(changeset.changes, keys)`. So we must set an explicit
  # `scheduled_at`; otherwise `:scheduled_at` is absent from the changes, the
  # pending `scheduled` job's run time is never bumped, and "Run now" silently
  # waits until the next hourly run (only its args flip to manual). Setting it
  # to now bumps the existing job — or schedules a fresh one — to run on the
  # next stager tick.
  defp put_run_at(opts, true, _schedule_in),
    do: Keyword.put(opts, :scheduled_at, DateTime.utc_now())

  defp put_run_at(opts, false, schedule_in) when is_integer(schedule_in) and schedule_in > 0,
    do: Keyword.put(opts, :schedule_in, schedule_in)

  defp put_run_at(opts, false, _schedule_in), do: opts

  defp reap_stale_source_jobs(integration_source_id) do
    reap_stale_source_jobs(integration_source_id, DateTime.utc_now(), stale_run_cutoff_seconds())
  end

  defp reap_stale_source_jobs(integration_source_id, now, cutoff_seconds) do
    result = reap_stale_jobs_fun().(__MODULE__, integration_source_id, now, cutoff_seconds)

    case result do
      {count, _} when is_integer(count) and count > 0 ->
        Logger.warning("Reaped stale Armis northbound jobs before enqueue",
          integration_source_id: integration_source_id,
          stale_job_count: count,
          stale_run_cutoff_seconds: cutoff_seconds
        )

      _ ->
        :ok
    end

    result
  rescue
    error ->
      Logger.warning("Failed to reap stale Armis northbound jobs before enqueue",
        integration_source_id: integration_source_id,
        error: Exception.message(error)
      )

      {0, nil}
  end

  defp default_reap_stale_source_jobs(worker, integration_source_id, now, cutoff_seconds),
    do:
      ArmisNorthboundObanReaper.reap_stale_source_jobs(
        worker,
        integration_source_id,
        now,
        cutoff_seconds
      )

  # An auth failure is a *total* run failure (nothing updated) whose recorded
  # errors point at authentication/authorization: a rejected access token
  # (401/403), a failed token exchange, or a missing secret key. Partial runs
  # (updated_count > 0) are intentionally excluded so retries don't re-push
  # devices that already succeeded.
  defp auth_failure?(%{result: %{updated_count: updated, errors: errors}})
       when is_integer(updated) and is_list(errors) do
    updated == 0 and Enum.any?(errors, &auth_error_reason?/1)
  end

  defp auth_failure?(_result), do: false

  defp auth_error_reason?(%{reason: reason}), do: auth_error_reason?(reason)
  defp auth_error_reason?({:unexpected_status, status, _body}) when status in [401, 403], do: true
  defp auth_error_reason?({:token_request_failed, _status, _body}), do: true
  defp auth_error_reason?(:missing_secret_key), do: true
  defp auth_error_reason?(_reason), do: false

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
