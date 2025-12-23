defmodule ServiceRadarWebNG.Edge.Workers.ExpirePackagesWorker do
  @moduledoc """
  Oban cron worker that expires stale edge onboarding packages.

  Runs periodically to find packages where both join_token and download_token
  have expired, and marks them as "expired" status.

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

  import Ecto.Query
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.Edge.OnboardingPackage
  alias ServiceRadarWebNG.Edge.Workers.RecordEventWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    # Find packages that are still in "issued" state but tokens have expired
    expired_packages =
      OnboardingPackage
      |> where([p], p.status == "issued")
      |> where([p], p.download_token_expires_at < ^now)
      |> where([p], p.join_token_expires_at < ^now)
      |> Repo.all()

    expired_count =
      Enum.reduce(expired_packages, 0, fn package, count ->
        case expire_package(package) do
          {:ok, _} -> count + 1
          {:error, _} -> count
        end
      end)

    {:ok, %{expired: expired_count, checked: length(expired_packages)}}
  end

  defp expire_package(package) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset =
      package
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_change(:status, "expired")
      |> Ecto.Changeset.put_change(:updated_at, now)

    case Repo.update(changeset) do
      {:ok, updated} ->
        # Record expiration event asynchronously
        RecordEventWorker.enqueue(package.id, "expired",
          actor: "system",
          details: %{reason: "tokens_expired"}
        )

        {:ok, updated}

      error ->
        error
    end
  end
end
