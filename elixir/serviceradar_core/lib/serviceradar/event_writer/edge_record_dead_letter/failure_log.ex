defmodule ServiceRadar.EventWriter.EdgeRecordDeadLetter.FailureLog do
  @moduledoc """
  The first failure this node saw for each edge-record delivery that is still being retried,
  keyed by its source `{stream, stream_sequence}`, so a dead-letter can say when the record
  first failed rather than only when it last did.

  It is a hint, not a ledger: a NAK carries no state, and redeliveries can move between
  replicas, so a node only knows the failures it handled. An entry leaves when its delivery
  succeeds or is dead-lettered on this node; a delivery that moved to another replica leaves
  its entry behind. The table is therefore bounded at 50,000 entries: a new failure on a full
  table first evicts entries older than the source stream's 24-hour `MaxAge` (their deliveries
  can no longer be redelivered), and failing that the oldest entry. When the
  owner is not running (a test that drives the pipeline's ack callback directly), every call is
  a no-op.
  """

  use GenServer

  @table __MODULE__
  @max_entries 50_000
  @stale_after_ms 24 * 60 * 60 * 1000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records `at_ms` as the first failure of `key`, unless an earlier one is recorded."
  @spec note(term(), integer()) :: :ok
  def note(key, at_ms) do
    if :ets.info(@table, :size) >= @max_entries, do: evict(at_ms)
    :ets.insert_new(@table, {key, at_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The first recorded failure of `key`, in milliseconds, or `nil`."
  @spec first(term()) :: integer() | nil
  def first(key) do
    case :ets.lookup(@table, key) do
      [{^key, at_ms}] -> at_ms
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Drops the record of `key`."
  @spec forget(term()) :: :ok
  def forget(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp evict(now_ms) do
    cutoff = now_ms - @stale_after_ms

    if :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]) == 0 do
      case :ets.foldl(&older/2, nil, @table) do
        {key, _at_ms} -> :ets.delete(@table, key)
        nil -> true
      end
    end
  end

  defp older(entry, nil), do: entry
  defp older({_key, at_ms} = entry, {_oldest_key, oldest_ms}) when at_ms < oldest_ms, do: entry
  defp older(_entry, oldest), do: oldest

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
