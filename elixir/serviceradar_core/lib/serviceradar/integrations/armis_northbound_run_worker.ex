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
      keys: [:integration_source_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Integrations.ArmisNorthboundRunner
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.SweepJobs.ObanSupport

  @spec enqueue_now(String.t() | Ecto.UUID.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_now(integration_source_id) do
    if ObanSupport.available?() do
      %{"integration_source_id" => to_string(integration_source_id), "manual" => true}
      |> new()
      |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
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
end
