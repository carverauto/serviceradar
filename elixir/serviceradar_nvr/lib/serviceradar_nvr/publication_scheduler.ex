defmodule ServiceRadarNVR.PublicationScheduler do
  @moduledoc """
  Opt-in recovery-page scheduling. Only the cursor and last outcome live in memory.

  Files remain the recovery authority. Each step shares the single delivery slot
  and its thirty-second worker deadline with explicit calls. Network and file I/O
  run in that worker, never in this coordinator. Restart begins a new scan; an
  already admitted worker may finish under its own deadline after coordinator loss.
  """
  use GenServer

  alias ServiceRadarNVR.Delivery

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> {:error, :nvr_scheduler_unavailable}
  end

  @impl true
  def init(nil) do
    state = %{cursor: nil, worker: nil, result: nil, failures: 0, steps: 0, delivered: 0, last_result: nil, delay_ms: 0}
    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = state |> Map.drop([:worker, :result]) |> Map.put(:active?, state.worker != nil)
    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info(:tick, %{worker: nil} = state) do
    case Delivery.start_pending(state.cursor) do
      {:ok, pid, reply} ->
        worker = %{pid: pid, monitor: Process.monitor(pid), reply: reply}
        {:noreply, %{state | worker: worker, result: nil}}

      {:error, _} = error ->
        {:noreply, state |> outcome(error) |> schedule()}
    end
  end

  def handle_info({reply, result}, %{worker: %{reply: reply}} = state) do
    {:noreply, %{state | result: result}}
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, %{worker: %{monitor: monitor, pid: pid} = worker} = state) do
    :erlang.unalias(worker.reply)
    result = state.result || {:error, worker_error(reason)}
    state = %{state | worker: nil, result: nil, steps: state.steps + 1}
    {:noreply, state |> completed(result) |> schedule()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp completed(state, {:ok, %{next_cursor: cursor, block_id: block_id, outcome: outcome}}) do
    state = %{state | cursor: cursor, delivered: state.delivered + if(outcome == :delivered, do: 1, else: 0)}
    state = outcome(state, outcome)
    %{state | last_result: %{block_id: block_id, outcome: outcome}}
  end

  defp completed(state, {:error, _} = error) do
    # A scan error or unknown worker outcome supplies no safe next cursor. Retry
    # from the beginning, including after a storage-lifetime mismatch.
    outcome(%{state | cursor: nil}, error)
  end

  defp outcome(state, {:error, _} = error), do: %{state | failures: min(state.failures + 1, 6), last_result: error}

  defp outcome(state, outcome), do: %{state | failures: 0, last_result: outcome}

  defp schedule(state) do
    base = min(48_000, 1_000 * Integer.pow(2, state.failures))
    delay = base + :rand.uniform(div(base, 4)) - 1
    Process.send_after(self(), :tick, delay)
    %{state | delay_ms: delay}
  end

  defp worker_error({:shutdown, :nvr_delivery_timeout}), do: :nvr_delivery_timeout
  defp worker_error(_), do: :nvr_delivery_unavailable
end
