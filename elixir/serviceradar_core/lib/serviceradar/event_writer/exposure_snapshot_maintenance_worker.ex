defmodule ServiceRadar.EventWriter.ExposureSnapshotMaintenanceWorker do
  @moduledoc "Resumes retained snapshot effects, cleanup and finalization in bounded passes."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.ExposureSnapshotIngestion, as: Ingestion
  alias ServiceRadar.Inventory.ExposureSnapshotFinalizer, as: Finalizer
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State
  alias ServiceRadar.Inventory.ExposureSnapshotWorker, as: Publisher
  alias ServiceRadar.Repo

  @impl Oban.Worker
  def perform(_job) do
    if Destination.enabled?() do
      recovery = Publisher.recover_reader()

      pending =
        Repo.query!("""
        SELECT id, jsonb_object_keys(control->'pending')
        FROM platform.exposure_snapshot_generations
        WHERE control->'pending' <> '{}'::jsonb ORDER BY id LIMIT 18
        """).rows

      results = Enum.map(pending, fn [id, lane] -> Ingestion.resume(id, lane) end)

      result =
        case State.active() do
          {:ok, %{"status" => "published"} = generation} -> Publisher.publish_end(generation)
          {:ok, %{"status" => "finalizing", "id" => id}} -> Finalizer.step(id)
          :none -> request_missing_input_snapshot()
          _ -> :ok
        end

      results = [recovery, result | results]

      Enum.each(results, fn
        :ok ->
          :ok

        result ->
          :telemetry.execute([:serviceradar, :exposure, :snapshot, :deferred], %{count: 1}, %{
            reason: result
          })
      end)

      if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:snooze, 5}
    else
      :ok
    end
  end

  defp request_missing_input_snapshot do
    missing =
      Repo.query!(
        "SELECT 1 FROM platform.exposure_delivery_batches WHERE phase = 'snapshot_required' LIMIT 1"
      ).rows

    if missing == [] do
      :ok
    else
      with {:ok, _} <- %{} |> Publisher.new() |> Oban.insert(), do: :ok
    end
  end
end
