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

  alias ServiceRadar.Edge.OnboardingPackage
  alias ServiceRadar.Edge.Workers.RecordEventWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    # Find packages that are still in "issued" state but tokens have expired
    expired_packages =
      OnboardingPackage
      |> Ash.Query.filter(expr(status == :issued))
      |> Ash.Query.filter(expr(download_token_expires_at < ^now))
      |> Ash.Query.filter(expr(join_token_expires_at < ^now))
      |> Ash.read!(actor: system_actor(), authorize?: false)

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
    case OnboardingPackage
         |> Ash.Changeset.for_update(:expire, %{}, actor: system_actor())
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

  defp system_actor do
    %{
      id: "00000000-0000-0000-0000-000000000000",
      email: "system@serviceradar.local",
      role: :super_admin
    }
  end
end
