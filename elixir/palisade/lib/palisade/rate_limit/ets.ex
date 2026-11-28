defmodule Palisade.RateLimit.ETS do
  @moduledoc """
  Single-node `Palisade.RateLimit` backend on a bounded ETS table.

  ## Starting it

  The table is owned by a process the consumer starts from its own
  supervision tree:

      children = [
        {Palisade.RateLimit.ETS, max_entries: 100_000},
        MyAppWeb.Endpoint
      ]

  Several independent tables can run side by side under different names:

      {Palisade.RateLimit.ETS, name: MyApp.LoginLimiter, max_entries: 10_000}

  and are selected with `backend: {Palisade.RateLimit.ETS, name: MyApp.LoginLimiter}`.
  Calling `check/4` for a name whose owner is not running raises
  `ArgumentError`.

  ## Options

    * `:name` - the table and process name. Default `Palisade.RateLimit.ETS`.
    * `:max_entries` - the most rows the table may hold. Default `100_000`.
      Each key uses at most two rows (the current and the previous window).
      When the table is full, requests for keys it does not already track are
      denied. Requests for tracked keys are still counted normally.
    * `:sweep_interval_ms` - how often expired rows are deleted. Default
      `60_000`.

  ## Algorithm

  A sliding-window counter: each key has a counter for the current fixed
  window and one for the previous window. The previous count is weighted by
  how much of it still overlaps the sliding window, so a client cannot send
  `2 * limit` requests across a window boundary. Counting uses
  `:ets.update_counter/4`, so checks never queue behind a process. A denied
  request is not counted.

  The fullness check reads the table size before inserting a new key, so
  concurrent inserts can overshoot `:max_entries` by at most the number of
  schedulers.
  """

  @behaviour Palisade.RateLimit

  use GenServer

  @config_key {__MODULE__, :max_entries}

  @defaults [
    name: __MODULE__,
    max_entries: 100_000,
    sweep_interval_ms: 60_000
  ]

  ## Process

  @doc false
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the table owner. See the module documentation for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.merge(@defaults, opts)

    for key <- [:max_entries, :sweep_interval_ms] do
      value = Keyword.fetch!(opts, key)

      if !(is_integer(value) and value > 0) do
        raise ArgumentError,
              "invalid #{inspect(key)} for #{inspect(__MODULE__)}: #{inspect(value)}"
      end
    end

    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl GenServer
  def init(opts) do
    table =
      :ets.new(Keyword.fetch!(opts, :name), [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ets.insert(table, {@config_key, Keyword.fetch!(opts, :max_entries)})
    interval = Keyword.fetch!(opts, :sweep_interval_ms)
    schedule_sweep(interval)
    {:ok, %{table: table, interval: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, %{table: table, interval: interval} = state) do
    sweep(table)
    schedule_sweep(interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp sweep(table) do
    now = now_ms()
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
  end

  ## Backend

  @impl Palisade.RateLimit
  def check(key, limit, window_ms, opts \\ [])
      when is_integer(limit) and limit > 0 and is_integer(window_ms) and window_ms > 0 do
    table = Keyword.get(opts, :name, __MODULE__)
    max_entries = max_entries!(table)

    now = now_ms()
    index = Integer.floor_div(now, window_ms)
    elapsed = now - index * window_ms
    current_key = {key, window_ms, index}
    previous = count(table, {key, window_ms, index - 1})

    case increment(table, current_key, index, window_ms, max_entries) do
      :full ->
        {:deny, window_ms}

      count ->
        # Integer form of: previous * (window - elapsed) / window + count <= limit
        budget = limit * window_ms - previous * (window_ms - elapsed) - count * window_ms

        if budget >= 0 do
          {:allow, div(budget, window_ms), window_ms - elapsed}
        else
          :ets.update_counter(table, current_key, {2, -1})
          {:deny, retry_after(previous, count - 1, limit, window_ms, elapsed)}
        end
    end
  end

  defp max_entries!(table) do
    case :ets.whereis(table) do
      :undefined ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} table #{inspect(table)} is not running; " <>
                "add {#{inspect(__MODULE__)}, name: #{inspect(table)}} to a supervision tree"

      tid ->
        [{@config_key, max_entries}] = :ets.lookup(tid, @config_key)
        max_entries
    end
  end

  defp count(table, row_key) do
    case :ets.lookup(table, row_key) do
      [{^row_key, count, _expires_at}] -> count
      [] -> 0
    end
  end

  defp increment(table, row_key, index, window_ms, max_entries) do
    # The row is needed for this window and, as the previous window, the next.
    expires_at = (index + 2) * window_ms

    cond do
      :ets.member(table, row_key) ->
        :ets.update_counter(table, row_key, {2, 1}, {row_key, 0, expires_at})

      # The config row is not a rate-limit entry.
      :ets.info(table, :size) - 1 >= max_entries ->
        :full

      true ->
        :ets.update_counter(table, row_key, {2, 1}, {row_key, 0, expires_at})
    end
  end

  # How long until one more request fits. `current` excludes the denied request.
  defp retry_after(previous, current, limit, window_ms, elapsed) do
    remaining_in_window = window_ms - elapsed

    wait =
      if current < limit do
        # The previous window's weight alone is over budget; wait for it to
        # slide out far enough within this window.
        remaining_in_window - div((limit - 1 - current) * window_ms, previous)
      else
        # This window is full; wait into the next one until this window's
        # weight drops below the limit.
        remaining_in_window + ceil_div((current - limit + 1) * window_ms, current)
      end

    max(wait, 1)
  end

  defp ceil_div(numerator, denominator), do: div(numerator + denominator - 1, denominator)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
