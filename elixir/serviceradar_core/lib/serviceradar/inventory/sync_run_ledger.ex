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

  def with_newest_run(meta, fun), do: with_run_status_lock(meta, fun, false)

  def with_open_newest_run(meta, fun), do: with_run_status_lock(meta, fun, true)

  defp with_run_status_lock(meta, fun, skip_incomplete) do
    case identity(meta) do
      {:ok, source, run} ->
        source
        |> newest_run_transaction(run, fun, skip_incomplete)
        |> notify_after_commit()

      {:error, _} ->
        notify_after_commit(fun.())
    end
  end

  defp newest_run_transaction(source, run, fun, skip_incomplete) do
    fn ->
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        ["sync-source-status:" <> source]
      )

      {superseded, incomplete} = run_state(source, run)

      if superseded or (skip_incomplete and incomplete) do
        {:ok, []}
      else
        case fun.() do
          {:ok, _notifications} = handled -> handled
          :ok -> {:ok, []}
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end
    |> Repo.transaction(timeout: status_transaction_timeout_ms())
    |> case do
      {:ok, handled} -> handled
      {:error, _} = error -> error
    end
  end

  defp notify_after_commit({:ok, notifications}) do
    Ash.Notifier.notify(notifications)
    :ok
  end

  defp notify_after_commit(:ok), do: :ok
  defp notify_after_commit({:error, _} = error), do: error

  defp status_transaction_timeout_ms,
    do: Application.get_env(:serviceradar_core, :sync_ingestor_worker_timeout_ms, 120_000)

  defp run_state(source, run) do
    %{rows: [[superseded, incomplete]]} =
      Repo.query!(
        """
        SELECT
          EXISTS (
            SELECT 1
            FROM platform.sync_ingest_runs AS current_run
            JOIN platform.sync_ingest_runs AS newer_run
              ON newer_run.sync_service_id = current_run.sync_service_id
             AND newer_run.sync_run_id <> current_run.sync_run_id
             AND newer_run.inserted_at > current_run.inserted_at
            WHERE current_run.sync_service_id = $1 AND current_run.sync_run_id = $2
          ),
          COALESCE(
            (SELECT incomplete
             FROM platform.sync_ingest_runs
             WHERE sync_service_id = $1 AND sync_run_id = $2),
            false
          )
        """,
        [Ecto.UUID.dump!(source), run]
      )

    {superseded, incomplete}
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
