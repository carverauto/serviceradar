defmodule ServiceRadarAgentGateway.StatusBuffer do
  @moduledoc """
  Buffers status payloads when their downstream consumer is unavailable.

  This is an in-memory, bounded queue intended to reduce data loss
  during short core outages. It is not durable across restarts.
  """

  use GenServer

  alias ServiceRadarAgentGateway.StatusProcessor

  require Logger

  @default_max_entries 100
  @default_flush_interval_ms 5_000
  @default_flush_batch_size 100

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec enqueue(map()) :: :ok | {:error, :unavailable}
  def enqueue(status) when is_map(status) do
    GenServer.call(__MODULE__, {:enqueue, status}, 1_000)
  catch
    :exit, {:noproc, _} ->
      {:error, :unavailable}

    :exit, {:timeout, _} ->
      {:error, :unavailable}
  end

  @doc false
  @spec record_drop(map(), atom()) :: :ok
  def record_drop(status, reason) when is_map(status) and is_atom(reason) do
    emit_buffer_drop(status, reason)
  end

  @spec size() :: non_neg_integer()
  def size do
    GenServer.call(__MODULE__, :size)
  end

  @impl true
  def init(opts) do
    max_entries = Keyword.get(opts, :max_entries, env_int("GATEWAY_RESULTS_BUFFER_LIMIT", @default_max_entries))

    flush_interval_ms =
      Keyword.get(opts, :flush_interval_ms, env_int("GATEWAY_RESULTS_BUFFER_FLUSH_MS", @default_flush_interval_ms))

    schedule_flush(flush_interval_ms)
    emit_buffer_depth(0)

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
      Logger.warning("Status buffer disabled; dropping status")
      emit_buffer_drop(status, :disabled)
      {:reply, :ok, state}
    else
      {queue, dropped} = enqueue_status(state.queue, status, state.max_entries)

      if dropped do
        Logger.warning("Status buffer full; dropping oldest status")
        emit_buffer_drop(status, :overflow)
      end

      emit_buffer_depth(:queue.len(queue))
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
        case StatusProcessor.process(status, buffer_on_failure: false, from_buffer: true) do
          :ok ->
            emit_buffer_depth(:queue.len(rest))
            flush_queue(%{state | queue: rest}, remaining - 1)

          {:ok, _result} ->
            emit_buffer_depth(:queue.len(rest))
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

  defp emit_buffer_drop(status, reason) do
    :telemetry.execute(
      [:serviceradar, :agent_gateway, :results, :buffer, :dropped],
      %{count: 1},
      buffer_metadata(status, reason)
    )
  end

  defp emit_buffer_depth(depth) do
    :telemetry.execute(
      [:serviceradar, :agent_gateway, :results, :buffer, :depth],
      %{depth: depth},
      %{gateway_id: ServiceRadarAgentGateway.Config.gateway_id()}
    )
  end

  defp buffer_metadata(status, reason) do
    %{
      reason: reason,
      gateway_id: status[:gateway_id] || ServiceRadarAgentGateway.Config.gateway_id(),
      partition: status[:partition] || "default"
    }
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
