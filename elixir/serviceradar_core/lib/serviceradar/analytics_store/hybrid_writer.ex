defmodule ServiceRadar.AnalyticsStore.HybridWriter do
  @moduledoc """
  Atomically persist hot samples and their durable archive work.

  Only rows accepted by the Timescale primary key become archive members.
  Publication runs after commit from the stored batch, never inside this
  transaction and never from a newly decoded retry payload.
  """

  alias ServiceRadar.AnalyticsStore.ArchiveBatch
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.EventWriter.BulkInsert
  alias ServiceRadar.Repo

  @spec write(String.t(), [map()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def write(table, rows, opts \\ [])
  def write("timeseries_metrics", [], _opts), do: {:ok, 0}

  def write("timeseries_metrics" = table, rows, opts) when is_list(rows) do
    repo = Keyword.get(opts, :repo, Repo)
    enqueue = Keyword.get(opts, :enqueue_rows, &ArchiveBatch.enqueue_rows/3)
    transaction = Keyword.get(opts, :transaction, &Ash.transact(ArchiveBatch, &1))
    {:ok, entry} = Registry.fetch(table)
    # These names come from the fixed in-tree registry, never a message or request.
    columns = Enum.map(entry.columns, fn {name, _type, _nullable} -> String.to_atom(name) end)

    transaction.(fn ->
      {count, persisted} =
        BulkInsert.insert_all(repo, table, rows, on_conflict: :nothing, returning: columns)

      case enqueue.(table, persisted, opts) do
        {:ok, _batches} -> count
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error -> {:error, error}
  end

  def write(table, _rows, _opts), do: {:error, {:unsupported_hybrid_table, table}}
end
