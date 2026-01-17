defmodule ServiceRadarWebNG.Edge.Workers.ExpirePackagesWorker do
  @moduledoc """
  Oban cron worker that expires stale edge onboarding packages.

  Runs periodically to find packages where both join_token and download_token
  have expired, and marks them as "expired" status.

  Uses Ash resources from serviceradar_core for all operations.

  ## Configuration

  Add to your Oban config in config/config.exs:

      config :serviceradar_web_ng, Oban,
        queues: [default: 10, events: 5, maintenance: 1],
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"0 * * * *", ServiceRadarWebNG.Edge.Workers.ExpirePackagesWorker}
           ]}
        ]

  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3

  import Ash.Expr
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Edge.Workers.RecordEventWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    # Find packages that are still in "issued" state but tokens have expired
    actor = SystemActor.system(:expire_packages_worker)

    expired_packages =
      OnboardingPackage
      |> Ash.Query.filter(expr(status == :issued))
      |> Ash.Query.filter(expr(download_token_expires_at < ^now))
      |> Ash.Query.filter(expr(join_token_expires_at < ^now))
      |> Ash.read!(actor: actor)

    expired_count =
      Enum.reduce(expired_packages, 0, fn package, count ->
        case expire_package(package, actor) do
          {:ok, _} -> count + 1
          {:error, _} -> count
        end
      end)

    {:ok, %{expired: expired_count, checked: length(expired_packages)}}
  end

  defp expire_package(package, actor) do
    case OnboardingPackage
         |> Ash.Changeset.for_update(:expire, %{}, actor: actor)
         |> Ash.update(package) do
      {:ok, updated} ->
        # Record expiration event asynchronously
        RecordEventWorker.enqueue(package.id, :expired,
          actor: "system",
          details: %{reason: "tokens_expired"}
        )

        {:ok, updated}

      error ->
        error
    end
  end
end
