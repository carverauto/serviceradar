defmodule ServiceRadar.EventWriter.EdgeRecordDeadLetter.FailureLog do
  @moduledoc """
  The first failure this node saw for each edge-record delivery that is still being retried,
  keyed by its source `{stream, stream_sequence}`, so a dead-letter can say when the record
  first failed rather than only when it last did.

  It is a hint, not a ledger: a NAK carries no state, and redeliveries can move between
  replicas, so a node only knows the failures it handled. The table is bounded at
  50,000 entries; past that a failure is not recorded and the dead-letter reports its last
  failure as the first. An entry leaves when its delivery succeeds or is dead-lettered. When the
  owner is not running (a test that drives the pipeline's ack callback directly), every call is
  a no-op.
  """

  use GenServer

  @table __MODULE__
  @max_entries 50_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Records `at_ms` as the first failure of `key`, unless an earlier one is recorded."
  @spec note(term(), integer()) :: :ok
  def note(key, at_ms) do
    if :ets.info(@table, :size) < @max_entries, do: :ets.insert_new(@table, {key, at_ms})
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

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
