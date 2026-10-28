defmodule ServiceRadar.EventWriter.ExposureTerminalCompactionWorker do
  @moduledoc "Daily, bounded terminal payload compaction with a durable keyset cursor."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker], states: :incomplete]

  import Ecto.Query

  alias ServiceRadar.Analytics.StarRocks.Destination
  alias ServiceRadar.EventWriter.ExposureFactPayload
  alias ServiceRadar.EventWriter.ExposureSnapshotEnvelope, as: Envelope
  alias ServiceRadar.EventWriter.ExposureSnapshotWarehouse, as: Warehouse
  alias ServiceRadar.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{id: id}) when is_integer(id) do
    cond do
      not Destination.enabled?() -> :ok
      legacy_repairs_pending?() -> {:snooze, 30}
      true -> compact(Repo.get!(Oban.Job, id))
    end
  end

  # Existing obligations carry only a digest of the full row. Let them settle
  # before erasing that evidence. New obligations also retain a compacted digest.
  defp legacy_repairs_pending? do
    [[pending]] =
      Repo.query!("""
      SELECT EXISTS (
        SELECT 1 FROM platform.exposure_snapshot_generations
        WHERE control @? '$.** ? (@.kind == "fact" && exists(@.required) && !exists(@.expected_compacted))'
        UNION ALL
        SELECT 1 FROM platform.exposure_reconciliation_checks
        WHERE control @? '$.** ? (@.kind == "fact" && exists(@.required) && !exists(@.expected_compacted))'
      )
      """).rows

    pending
  end

  defp compact(job) do
    cutoff =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-7 * 86_400, :second)
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_iso8601()

    with {:ok, job} <- checkpoint(job, Map.put_new(job.args, "cutoff", cutoff)) do
      compact_pages(job, 10)
    end
  end

  defp compact_pages(_job, 0), do: {:snooze, 1}

  defp compact_pages(job, remaining) do
    cursor = job.args["cursor"] || [0, 0, 0]
    cutoff = NaiveDateTime.from_iso8601!(job.args["cutoff"])

    with {:ok, facts} <- Warehouse.compactable_facts(cursor, cutoff) do
      compact_page(job, facts, remaining)
    end
  end

  defp compact_page(_job, [], _remaining), do: :ok

  defp compact_page(job, facts, remaining) do
    rows = Enum.map(facts, &ExposureFactPayload.compact/1)

    # This changes storage representation, never the logical publication.
    # Conditional loads cannot clear a newer state, and omit snapshot_generation.
    # Even a timed-out load arriving after replay can only clear the same
    # terminal publication; it cannot reactivate a fact or erase a new fence.
    # A new job id permits compaction again after identical terminal replay.
    label = Envelope.digest(Envelope.canonical([job.id, job.args["cutoff"], rows]))

    with {:ok, _} <-
           Destination.persist_warehouse(:exposure_compacted_facts, rows,
             label: "exposure-compaction-" <> label,
             stream_load: [max_rows: 1000, max_bytes: 512 * 1024, max_in_flight: 1]
           ),
         {:ok, next} <-
           checkpoint(job, Map.put(job.args, "cursor", Warehouse.key(List.last(facts)))) do
      compact_pages(next, remaining - 1)
    end
  end

  defp checkpoint(job, args) do
    query = from(j in Oban.Job, where: j.id == ^job.id and j.args == ^job.args)

    case Repo.update_all(query, set: [args: args]) do
      {1, _} -> {:ok, %{job | args: args}}
      {0, _} -> {:error, :exposure_compaction_cursor_changed}
    end
  end
end
