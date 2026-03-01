defmodule ServiceRadar.Plugins.PluginTargetPolicyReconcileWorker do
  @moduledoc """
  Periodic Oban worker that reconciles all enabled plugin target policies.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.{PluginTargetPolicy, PluginTargetPolicyOps}
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
  require Logger

  @default_reschedule_seconds 60

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      case scheduled?() do
        true -> {:ok, :already_scheduled}
        false -> %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
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

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    actor = SystemActor.system(:plugin_target_policy_reconcile_worker)

    policies =
      PluginTargetPolicy
      |> Ash.Query.for_read(:enabled)
      |> Ash.read(actor: actor)

    case policies do
      {:ok, rows} ->
        Enum.each(rows, &reconcile_one_policy(&1, actor))

        schedule_next()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to load enabled plugin target policies", reason: inspect(reason))
        schedule_next()
        {:error, reason}
    end
  end

  defp reconcile_one_policy(policy, actor) do
    case PluginTargetPolicyOps.reconcile_policy(policy, actor: actor) do
      {:ok, summary} ->
        Logger.info("Reconciled plugin target policy",
          policy_id: policy.id,
          summary: inspect(summary)
        )

      {:error, reason} ->
        Logger.warning("Failed to reconcile plugin target policy",
          policy_id: policy.id,
          reason: inspect(reason)
        )
    end
  end

  defp schedule_next do
    seconds =
      Application.get_env(
        :serviceradar_core,
        :plugin_target_policy_reconcile_interval_seconds,
        @default_reschedule_seconds
      )

    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(seconds, 10)))
    :ok
  end
end
