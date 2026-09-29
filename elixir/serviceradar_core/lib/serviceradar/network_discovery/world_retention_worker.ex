defmodule ServiceRadar.NetworkDiscovery.WorldRetentionWorker do
  @moduledoc "Reclaims expired world layouts in bounded, resumable background passes."

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.NetworkDiscovery.WorldRetention
  alias ServiceRadar.SweepJobs.ObanSupport

  @max_batches 20
  @interval_seconds 60

  def ensure_scheduled, do: %{} |> new() |> ObanSupport.safe_insert()

  @impl Oban.Worker
  def perform(_job) do
    with :ok <- prune(@max_batches),
         {:ok, _job} <- SelfScheduling.insert_successor(__MODULE__, %{}, @interval_seconds) do
      :ok
    end
  end

  defp prune(0), do: :ok

  defp prune(remaining) do
    case WorldRetention.prune_batch() do
      {:ok, :idle} -> :ok
      {:ok, _progress} -> prune(remaining - 1)
      {:error, _reason} = error -> error
    end
  end
end
