defmodule ServiceRadar.Inventory.SyncRunLedger do
  @moduledoc "Records only committed chunks; missing or rejected input fails snapshot activation closed."
  import Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.SyncIngestRun
  alias ServiceRadar.Repo

  @max_chunks 10_000

  def reject(meta), do: record([meta], true)
  def committed(metas), do: record(metas, false)

  def complete(meta) do
    with {:ok, source, run} <- identity(meta),
         {:ok, row} <- read(source, run),
         %{incomplete: false, total_chunks: total, received_chunks: chunks} <- row,
         true <-
           total == value(meta, :total_chunks) and total > 0 and
             total <= @max_chunks and chunks == Enum.to_list(0..(total - 1)) do
      :ok
    else
      _ -> {:error, :sync_run_incomplete}
    end
  end

  defp record(metas, rejected) do
    Enum.reduce_while(metas, :ok, fn meta, :ok ->
      case identity(meta) do
        {:ok, source, run} ->
          case record_one(source, run, meta, rejected) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end

        {:error, _} ->
          {:cont, :ok}
      end
    end)
  end

  defp record_one(source, run, meta, rejected) do
    case record_in_transaction(source, run, meta, rejected) do
      {:ok, notifications} ->
        # Ash cannot send notifications from inside a transaction it did not start; they
        # are returned and sent once the receipt has committed, so a rollback sends none.
        Ash.Notifier.notify(notifications)
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp record_in_transaction(source, run, meta, rejected) do
    actor = SystemActor.system(:sync_ingestor)

    Repo.transaction(fn ->
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        ["sync-ingest-run:" <> source <> ":" <> run]
      )

      with {:ok, row} <- read(source, run),
           {:ok, _receipt, notifications} <-
             write_receipt(row, receipt_attrs(row, meta, rejected), source, run, actor) do
        notifications
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp write_receipt(nil, attrs, source, run, actor) do
    attrs = Map.merge(attrs, %{sync_service_id: source, sync_run_id: run})

    SyncIngestRun
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create(actor: actor, return_notifications?: true)
  end

  defp write_receipt(row, attrs, _source, _run, actor) do
    row
    |> Ash.Changeset.for_update(:record, attrs, actor: actor)
    |> Ash.update(actor: actor, return_notifications?: true)
  end

  defp receipt_attrs(row, meta, rejected) do
    index = value(meta, :chunk_index)
    total = value(meta, :total_chunks) || 0
    valid_index = is_integer(index) and index >= 0 and index < @max_chunks
    valid_total = is_integer(total) and total >= 0 and total <= @max_chunks
    old_chunks = if row, do: row.received_chunks, else: []
    old_total = if row, do: row.total_chunks, else: 0
    conflict = old_total > 0 and total > 0 and old_total != total

    %{
      received_chunks:
        if(valid_index and not rejected,
          do: Enum.sort(Enum.uniq([index | old_chunks])),
          else: old_chunks
        ),
      total_chunks: if(valid_total, do: max(old_total, total), else: old_total),
      incomplete:
        rejected or not valid_index or not valid_total or conflict or
          (row != nil and row.incomplete)
    }
  end

  defp read(source, run) do
    SyncIngestRun
    |> filter(sync_service_id == ^source and sync_run_id == ^run)
    |> Ash.read_one(actor: SystemActor.system(:sync_ingestor))
  end

  defp identity(meta) when is_map(meta) do
    source = value(meta, :sync_service_id)
    run = value(meta, :sync_run_id)

    if is_binary(run) and byte_size(run) in 1..255 do
      case Ecto.UUID.cast(source) do
        {:ok, source} -> {:ok, source, run}
        :error -> {:error, :invalid_sync_identity}
      end
    else
      {:error, :invalid_sync_identity}
    end
  end

  defp identity(_), do: {:error, :invalid_sync_identity}

  defp value(meta, key), do: Map.get(meta, key) || Map.get(meta, Atom.to_string(key))
end
