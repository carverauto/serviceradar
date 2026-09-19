defmodule ServiceRadar.Analytics.StarRocks.RollupFreshnessCache do
  @moduledoc """
  Short-lived store for the high-water marks the rollup gate compares.

  `RollupFreshness` answers one question -- how far has an hourly view fallen
  behind the table it aggregates -- from two `MAX(...)` probes. Those probes
  are aggregates over the warehouse's largest partitioned tables, and a single
  dashboard render issues several rollup-eligible queries, so without a cache
  every chart pays its own pair of round trips.

  Marks are held for a minute, so a view that goes stale keeps being served
  for up to that long, and one that catches up keeps paying the raw scan for
  up to that long. That window is the price of not probing per query; it is
  small against the hour the marks are compared on. Only successful marks are
  stored, so a failed probe is retried rather than pinning the gate closed.

  This process owns the table. When it is not running -- StarRocks disabled,
  or a database-free test -- every lookup misses and every probe runs, so the
  gate's verdict never depends on the cache existing.
  """

  use GenServer

  alias ServiceRadar.Analytics.StarRocks.Env

  @table __MODULE__
  @ttl_ms 60_000

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec child_spec(term()) :: Supervisor.child_spec() | nil
  def child_spec(opts) do
    if Env.config()[:enabled] do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
    end
  end

  @spec fetch(term()) :: {:ok, term()} | :miss
  def fetch(key) do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{^key, value, expires_at}] <- :ets.lookup(tid, key),
         true <- expires_at > now_ms() do
      {:ok, value}
    else
      _ -> :miss
    end
  end

  @spec put(term(), value) :: value when value: term()
  def put(key, value) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> :ets.insert(tid, {key, value, now_ms() + @ttl_ms})
    end

    value
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
