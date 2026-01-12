defmodule ServiceRadarAgentGateway.StatusBuffer do
  @moduledoc """
  Buffers result payloads when core processing is unavailable.

  This is an in-memory, bounded queue intended to reduce data loss
  during short core outages. It is not durable across restarts.
  """

  use GenServer

  require Logger

  alias ServiceRadarAgentGateway.StatusProcessor

  @default_max_entries 100
  @default_flush_interval_ms 5_000
  @default_flush_batch_size 100

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec enqueue(map()) :: :ok
  def enqueue(status) when is_map(status) do
    GenServer.call(__MODULE__, {:enqueue, status}, 1_000)
  catch
    :exit, {:noproc, _} ->
      :ok

    :exit, {:timeout, _} ->
      :ok
  end

  @spec size() :: non_neg_integer()
  def size do
    GenServer.call(__MODULE__, :size)
  end

  @impl true
  def init(_opts) do
    max_entries = env_int("GATEWAY_RESULTS_BUFFER_LIMIT", @default_max_entries)
    flush_interval_ms = env_int("GATEWAY_RESULTS_BUFFER_FLUSH_MS", @default_flush_interval_ms)

    schedule_flush(flush_interval_ms)

    {:ok,
     %{
       queue: :queue.new(),
       max_entries: max_entries,
       flush_interval_ms: flush_interval_ms
     }}
  end

  @impl true
  def handle_call({:enqueue, status}, _from, state) do
    if state.max_entries <= 0 do
      Logger.debug("Results buffer disabled; dropping status")
      {:reply, :ok, state}
    else
      {queue, dropped} = enqueue_status(state.queue, status, state.max_entries)

      if dropped do
        Logger.warning("Results buffer full; dropping oldest status")
      end

      {:reply, :ok, %{state | queue: queue}}
    end
  end

  @impl true
  def handle_call(:size, _from, state) do
    {:reply, :queue.len(state.queue), state}
  end

  @impl true
  def handle_info(:flush, state) do
    {state, more?} = flush_queue(state, @default_flush_batch_size)

    if more? do
      Process.send_after(self(), :flush, 0)
    else
      schedule_flush(state.flush_interval_ms)
    end

    {:noreply, state}
  end

  defp enqueue_status(queue, status, max_entries) do
    if :queue.len(queue) >= max_entries do
      {{:value, _dropped}, reduced} = :queue.out(queue)
      {:queue.in(status, reduced), true}
    else
      {:queue.in(status, queue), false}
    end
  end

  defp flush_queue(state, remaining) when remaining <= 0 do
    {state, not :queue.is_empty(state.queue)}
  end

  defp flush_queue(state, remaining) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        {state, false}

      {{:value, status}, rest} ->
        case StatusProcessor.forward(status, buffer_on_failure: false, from_buffer: true) do
          :ok ->
            flush_queue(%{state | queue: rest}, remaining - 1)

          {:error, reason} ->
            Logger.debug("Results buffer flush paused: #{inspect(reason)}")
            {%{state | queue: :queue.in_r(status, rest)}, false}
        end
    end
  end

  defp schedule_flush(flush_interval_ms) do
    Process.send_after(self(), :flush, max(flush_interval_ms, 1_000))
  end

  defp env_int(var, default) do
    case System.get_env(var) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end
    end
  end
end
