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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

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
end
