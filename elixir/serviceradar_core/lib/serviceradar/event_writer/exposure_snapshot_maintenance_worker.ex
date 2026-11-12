defmodule ServiceRadar.EventWriter.ExposureSnapshotMaintenanceWorker do
  @moduledoc "Resumes retained snapshot effects, cleanup and finalization in bounded passes."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.ExposureSnapshotIngestion, as: Ingestion
  alias ServiceRadar.Inventory.ExposureSnapshotFinalizer, as: Finalizer
  alias ServiceRadar.Inventory.ExposureSnapshotScopes, as: Scopes
  alias ServiceRadar.Inventory.ExposureSnapshotState, as: State
  alias ServiceRadar.Inventory.ExposureSnapshotWorker, as: Publisher
  alias ServiceRadar.Repo

  @impl Oban.Worker
  def perform(_job) do
    if Destination.enabled?() do
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

      backstop = ensure_publisher_backstop()

      results = [backstop, result | results]

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
      Scopes.request(nil)
    end
  end

  # Backstop for a publisher that exited before its table drained (wait budget
  # out, crash, or deploy): pending scope work with no live publish in flight
  # ensures a fresh pass. Over-ensuring is free — a run that finds the session
  # lock held or the table quiet exits immediately.
  defp ensure_publisher_backstop do
    if Scopes.pending?(), do: Scopes.ensure_publisher(), else: :ok
  end
end
