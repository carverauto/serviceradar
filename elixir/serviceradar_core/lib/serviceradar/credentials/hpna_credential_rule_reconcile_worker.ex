defmodule ServiceRadar.Credentials.HpnaCredentialRuleReconcileWorker do
  @moduledoc """
  Periodically converges HPNA credential-rule state into one selected-agent
  action-only assignment and its disabled-by-default producer schedule.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.HpnaInventoryProvisioner
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
    actor = SystemActor.system(:hpna_credential_rule_reconcile_worker)

    result = HpnaInventoryProvisioner.reconcile_all(actor: actor)
    schedule_next()

    case result do
      {:ok, summary} ->
        Logger.info("Reconciled HPNA inventory credential rule", summary: inspect(summary))
        :ok

      {:error, reason} ->
        Logger.warning("Failed to reconcile HPNA inventory credential rule",
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
        :hpna_credential_rule_reconcile_interval_seconds,
        @default_reschedule_seconds
      )

    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(seconds, 10)))
    :ok
  end
end
