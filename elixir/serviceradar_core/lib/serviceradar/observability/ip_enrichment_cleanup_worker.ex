defmodule ServiceRadar.Observability.IpEnrichmentCleanupWorker do
  @moduledoc """
  Background job that prunes expired IP enrichment cache entries.

  This keeps the cache size bounded by the TTL windows on `expires_at`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.{IpGeoEnrichmentCache, IpRdnsCache}
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ash.Expr
  import Ecto.Query, only: [from: 2]

  require Ash.Query
  require Logger

  @default_reschedule_seconds 86_400
  @default_batch_size 1_000

  @doc """
  Schedules enrichment cleanup if not already scheduled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      case check_existing_job() do
        true -> {:ok, :already_scheduled}
        false -> %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)
    batch_size = Keyword.get(config, :batch_size, @default_batch_size)

    now = DateTime.utc_now()
    actor = SystemActor.system(:ip_enrichment_cleanup)

    prune_resource(IpGeoEnrichmentCache, actor, now, batch_size, :geo)
    prune_resource(IpRdnsCache, actor, now, batch_size, :rdns)

    ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 300)))
    :ok
  end

  defp prune_resource(resource, actor, now, batch_size, label) do
    query =
      resource
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(expr(expires_at < ^now))
      |> Ash.Query.limit(batch_size)

    case Ash.read(query, actor: actor) do
      {:ok, %Ash.Page.Keyset{results: results}} ->
        destroy_batch(results, actor, label)

      {:ok, results} when is_list(results) ->
        destroy_batch(results, actor, label)

      {:error, reason} ->
        Logger.warning("IpEnrichmentCleanupWorker: failed to read expired entries",
          label: label,
          reason: inspect(reason)
        )
    end
  end

  defp destroy_batch([], _actor, _label), do: :ok

  defp destroy_batch(records, actor, label) do
    result =
      Ash.bulk_destroy(records, :destroy, %{},
        actor: actor,
        return_records?: false,
        return_errors?: true
      )

    if match?(%Ash.BulkResult{status: :error}, result) do
      Logger.warning("IpEnrichmentCleanupWorker: bulk destroy failed",
        label: label,
        reason: inspect(result)
      )
    end

    :ok
  end
end
