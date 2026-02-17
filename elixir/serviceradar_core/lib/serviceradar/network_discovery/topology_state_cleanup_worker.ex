defmodule ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorker do
  @moduledoc """
  Periodic Oban worker that canonicalizes stale topology endpoint IDs.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.NetworkDiscovery.TopologyStateCleanup
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ecto.Query, only: [from: 2]

  require Logger

  @default_reschedule_seconds 300

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      case job_already_scheduled?() do
        true -> {:ok, :already_scheduled}
        false -> %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    case TopologyStateCleanup.canonicalize_deleted_device_links() do
      {:ok, stats} ->
        Logger.info("Topology state cleanup completed", stats: stats)

      {:error, reason} ->
        Logger.warning("Topology state cleanup failed", reason: inspect(reason))
    end

    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 60)))
    :ok
  end

  defp job_already_scheduled? do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end
end
