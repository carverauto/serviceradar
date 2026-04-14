defmodule ServiceRadar.Integrations.ArmisNorthboundRunWorker do
  @moduledoc """
  Oban worker that executes a single Armis northbound update run for one
  IntegrationSource.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [
      period: 60,
      fields: [:worker, :args],
      keys: [:integration_source_id, :manual],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.SweepJobs.ObanSupport

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

    case source_module().get_by_id(integration_source_id, actor: actor) do
      {:ok, source} ->
        source
        |> runner().run_for_source(
          actor: actor,
          oban_job_id: oban_job_id,
          manual?: Map.get(args, "manual", false)
        )
        |> case do
          {:ok, _result} -> :ok
          {:error, _result} -> {:error, :northbound_run_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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
    case Keyword.get(opts, :schedule_in, 0) do
      seconds when is_integer(seconds) and seconds > 0 -> [schedule_in: seconds]
      _ -> []
    end
  end

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
