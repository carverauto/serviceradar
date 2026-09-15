defmodule ServiceRadar.EventWriter.ArchivePublisher do
  @moduledoc """
  Publish durable EventWriter batches without holding a primary transaction open
  during object-store IO. Every attempt uses a fresh candidate key; only the
  winner of the batch completion transaction becomes query-visible.
  """

  use Oban.Worker,
    queue: :analytics_archive,
    max_attempts: 20,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:batch_id], states: :incomplete]

  alias ServiceRadar.AnalyticsStore.ArchiveBatch
  alias ServiceRadar.AnalyticsStore.Writer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_id" => id}}), do: publish(id)
  def perform(%Oban.Job{args: %{"reconcile" => true}}), do: reconcile_pending()

  @doc "Enqueue by ID; durable rows remain available if a job is discarded."
  def enqueue(id), do: %{batch_id: id} |> new() |> Oban.insert()

  @doc "Retry a bounded page of pending batches, including discarded jobs."
  def reconcile_pending(opts \\ []) do
    list = Keyword.get(opts, :pending_ids, &ArchiveBatch.pending_ids/1)
    enqueue = Keyword.get(opts, :enqueue_job, &enqueue/1)
    mark = Keyword.get(opts, :mark_reconciled, &ArchiveBatch.mark_reconciled/1)

    with {:ok, ids} <- list.(100) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        with {:ok, _} <- enqueue.(id),
             :ok <- mark.(id) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Publish one batch, using an injectable writer for database-backed tests."
  def publish(id, opts \\ []) do
    load = Keyword.get(opts, :load_batch, &ArchiveBatch.fetch/1)

    case load.(id) do
      {:ok, %{state: :published}} -> :ok
      {:ok, nil} -> {:error, :archive_batch_missing}
      {:ok, batch} -> publish_pending(batch, opts)
      {:error, _} = error -> error
    end
  end

  defp publish_pending(batch, opts) do
    writer = Keyword.get(opts, :writer, &Writer.write/3)
    complete = Keyword.get(opts, :complete_batch, &ArchiveBatch.complete/3)

    with {:ok, rows} <- ArchiveBatch.decode_payload(batch) do
      writer_opts =
        opts
        |> Keyword.put(:batch_id, Ecto.UUID.generate())
        |> Keyword.put(:candidate, true)
        |> Keyword.put(:record_manifest, fn attrs -> complete.(batch.id, attrs, opts) end)

      case writer.(batch.table_name, rows, writer_opts) do
        {:ok, _count} -> :ok
        {:error, _} = error -> error
      end
    end
  end
end
