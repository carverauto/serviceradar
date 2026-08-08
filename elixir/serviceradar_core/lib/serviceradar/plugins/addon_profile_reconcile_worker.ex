defmodule ServiceRadar.Plugins.AddonProfileReconcileWorker do
  @moduledoc """
  Periodic Oban worker that reconciles all enabled add-on profiles so
  profile -> assignment materialization happens automatically. Operators should
  not have to click "Reconcile" for a profile's SRQL target (e.g. `in:agents`)
  to materialize add-on assignments onto the matching enrolled agents.
  """

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Plugins.AddonProfile
  alias ServiceRadar.Plugins.AddonProfileOps
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query
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
    actor = SystemActor.system(:addon_profile_reconcile_worker)

    profiles =
      AddonProfile
      |> Ash.Query.for_read(:enabled)
      |> Ash.read(actor: actor)

    case profiles do
      {:ok, rows} ->
        Enum.each(rows, &reconcile_one_profile(&1, actor))

        schedule_next()
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to load enabled add-on profiles: #{inspect(reason)}",
          reason: inspect(reason)
        )

        schedule_next()
        {:error, reason}
    end
  end

  defp reconcile_one_profile(profile, actor) do
    case AddonProfileOps.reconcile_by_id(profile.id, actor: actor) do
      {:ok, summary} ->
        Logger.info("Reconciled add-on profile",
          profile_id: profile.id,
          summary: inspect(summary)
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to reconcile add-on profile #{profile.id}: #{inspect(reason)}",
          profile_id: profile.id,
          reason: inspect(reason)
        )
    end
  end

  defp schedule_next do
    seconds =
      Application.get_env(
        :serviceradar_core,
        :addon_profile_reconcile_interval_seconds,
        @default_reschedule_seconds
      )

    _ =
      ObanSupport.safe_insert(
        SelfScheduling.successor_changeset(__MODULE__, %{}, max(seconds, 10))
      )

    :ok
  end
end
