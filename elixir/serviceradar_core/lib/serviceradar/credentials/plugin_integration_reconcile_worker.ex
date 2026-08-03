defmodule ServiceRadar.Credentials.PluginIntegrationReconcileWorker do
  @moduledoc """
  Periodically converges package-declared credential integrations into selected-agent
  assignments and producer schedules.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.PluginIntegrationProvisioner
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_reschedule_seconds 60

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if scheduled?() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    actor = SystemActor.system(:plugin_integration_reconcile_worker)

    result = PluginIntegrationProvisioner.reconcile_all(actor: actor)
    schedule_next()

    case result do
      {:ok, summary} ->
        Logger.info("Reconciled plugin credential integrations", summary: inspect(summary))
        :ok

      {:error, reason} ->
        Logger.warning("Failed to reconcile plugin credential integrations",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp scheduled? do
    import Ecto.Query

    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp schedule_next do
    seconds =
      Application.get_env(
        :serviceradar_core,
        :plugin_integration_reconcile_interval_seconds,
        @default_reschedule_seconds
      )

    _ =
      ObanSupport.safe_insert(
        SelfScheduling.successor_changeset(__MODULE__, %{}, max(seconds, 10))
      )

    :ok
  end
end
