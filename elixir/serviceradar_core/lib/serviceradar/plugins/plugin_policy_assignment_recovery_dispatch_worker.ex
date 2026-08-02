defmodule ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryDispatchWorker do
  @moduledoc false

  # Core-side durable-request dispatcher. This covers web-ng nodes that create
  # the request while intentionally running without a local Oban instance.
  # It does not perform recovery itself; it emits a request-ID-only job for the
  # restricted worker.

  use Oban.Worker,
    queue: :integrations,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryRequest
  alias ServiceRadar.Plugins.PluginPolicyAssignmentRecoveryWorker
  alias ServiceRadar.SweepJobs.ObanSupport

  require Ash.Query

  @actor SystemActor.system(:plugin_policy_assignment_recovery_dispatcher)
  @default_reschedule_seconds 30
  @batch_size 100

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
    case pending_requests() do
      {:ok, requests} ->
        Enum.each(requests, fn request ->
          _ = PluginPolicyAssignmentRecoveryWorker.enqueue(request.id)
        end)

        schedule_next()
        :ok

      {:error, reason} ->
        schedule_next()
        {:error, reason}
    end
  end

  defp pending_requests do
    now = DateTime.utc_now()

    PluginPolicyAssignmentRecoveryRequest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      status == :requested or (status == :executing and lease_expires_at <= ^now)
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@batch_size)
    |> Ash.read(actor: @actor)
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
        :plugin_policy_assignment_recovery_dispatch_interval_seconds,
        @default_reschedule_seconds
      )

    _ =
      ObanSupport.safe_insert(
        SelfScheduling.successor_changeset(__MODULE__, %{}, max(seconds, 10))
      )

    :ok
  end
end
