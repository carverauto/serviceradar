defmodule ServiceRadar.EventWriter.EdgeRecordDeadLetter.FailureLog do
  @moduledoc """
  The first failure this node saw for each edge-record delivery that is still being retried,
  keyed by its source `{stream, stream_sequence}`, so a dead-letter can say when the record
  first failed rather than only when it last did.

  It is a hint, not a ledger: a NAK carries no state, and redeliveries can move between
  replicas, so a node only knows the failures it handled. An entry leaves when its delivery
  succeeds or is dead-lettered on this node; a delivery that moved to another replica leaves
  its entry behind. The table is therefore bounded at 50,000 entries: recording a new delivery
  in a full table evicts the entry recorded earliest, found through a second table ordered by
  `{at_ms, key}`. Re-noting a recorded delivery changes nothing. When the owner is not running
  (a test that drives the pipeline's ack callback directly), every call is a no-op.
  """

  use GenServer

  @table __MODULE__
  @order Module.concat(__MODULE__, Order)
  @max_entries 50_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records `at_ms` as the first failure of `key`, unless an earlier one is recorded."
  @spec note(term(), integer()) :: :ok
  def note(key, at_ms) do
    if !:ets.member(@table, key) do
      if :ets.info(@table, :size) >= @max_entries, do: evict_earliest()
      if :ets.insert_new(@table, {key, at_ms}), do: :ets.insert(@order, {{at_ms, key}})
    end

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
    case :ets.take(@table, key) do
      [{^key, at_ms}] -> :ets.delete(@order, {at_ms, key})
      [] -> true
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp evict_earliest do
    case :ets.first(@order) do
      {at_ms, key} = earliest ->
        :ets.delete(@order, earliest)
        :ets.delete_object(@table, {key, at_ms})

      :"$end_of_table" ->
        true
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ets.new(@order, [:named_table, :public, :ordered_set, write_concurrency: true])
    {:ok, nil}
  end
end
