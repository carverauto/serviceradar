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
  alias ServiceRadar.Plugins.AddonAssignment
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
        retire_orphaned_profile_assignments(rows, actor)

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

  # Retire profile-sourced assignments whose owning profile is gone or disabled.
  #
  # `AddonProfileReconciler.reconcile/2` loads only ONE profile's assignments
  # (`list_profile_assignments/2`), so its `disable_stale` can never see a row that
  # belongs to a profile it is not reconciling -- and this worker only reconciles
  # ENABLED profiles. Between them, disabling a profile stranded its assignments, and
  # deleting one stranded them with a null `addon_profile_id` (the FK is ON DELETE SET
  # NULL). Either way the rows stayed `enabled: true` and kept being delivered to
  # agents forever, with no profile left to ever turn them off.
  #
  # This is the fleet-wide sweep that owns that question: anything sourced from a
  # profile that is no longer an enabled profile gets disabled.
  defp retire_orphaned_profile_assignments(enabled_profiles, actor) do
    live_profile_ids = MapSet.new(enabled_profiles, &to_string(&1.id))

    AddonAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(source == :profile and enabled == true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, assignments} ->
        assignments
        |> Enum.reject(&MapSet.member?(live_profile_ids, to_string(&1.addon_profile_id)))
        |> Enum.each(&disable_orphaned_assignment(&1, actor))

      {:error, reason} ->
        Logger.warning("Failed to load profile assignments for orphan sweep: #{inspect(reason)}",
          reason: inspect(reason)
        )
    end
  end

  defp disable_orphaned_assignment(assignment, actor) do
    assignment
    |> Ash.Changeset.for_update(:update, %{
      enabled: false,
      profile_reconcile_status: "orphaned",
      profile_last_reconciled_at: DateTime.utc_now()
    })
    |> Ash.update(actor: actor, authorize?: true)
    |> case do
      {:ok, _} ->
        Logger.info("Disabled orphaned add-on assignment",
          assignment_id: assignment.id,
          addon_id: assignment.addon_id,
          agent_uid: assignment.agent_uid
        )

      {:error, reason} ->
        Logger.warning(
          "Failed to disable orphaned add-on assignment #{assignment.id}: #{inspect(reason)}",
          assignment_id: assignment.id,
          reason: inspect(reason)
        )
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
