defmodule ServiceRadar.Plugins.AddonRolloutWorker do
  @moduledoc """
  Periodically creates and advances managed native add-on fleet rollouts.

  A single globally unique job serializes source ownership and batch advancement;
  database uniqueness constraints remain the final concurrency backstop.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Plugins.AddonRolloutCoordinator
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_reschedule_seconds 30

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if scheduled?(),
        do: {:ok, :already_scheduled},
        else: %{} |> new() |> ObanSupport.safe_insert()
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = AddonRolloutCoordinator.reconcile()
    schedule_next()

    case result do
      {:ok, summary} ->
        Logger.info("Reconciled native add-on fleet rollouts", summary: inspect(summary))
        :ok

      {:error, reason} ->
        Logger.warning("Native add-on fleet rollout reconciliation failed",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp scheduled? do
    import Ecto.Query

    query =
      from(job in Oban.Job,
        where: job.worker == ^to_string(__MODULE__),
        where: job.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp schedule_next do
    seconds =
      Application.get_env(
        :serviceradar_core,
        :addon_rollout_reconcile_interval_seconds,
        @default_reschedule_seconds
      )

    _ =
      ObanSupport.safe_insert(
        SelfScheduling.successor_changeset(__MODULE__, %{}, max(seconds, 10))
      )

    :ok
  end
end
