defmodule ServiceRadarWebNG.Topology.BitmapQueryAdmission do
  @moduledoc """
  First-come admission to the eight bitmap query tasks.

  A response waits for a free task only until its own deadline, and reports
  `:query_busy` if none frees in time. It also reports `:query_busy` at once
  when 64 live, unexpired requests are already waiting. Rejecting every
  arrival that found all tasks busy made admission a race decided within
  milliseconds, so viewers whose retries coincided with other sockets'
  periodic refreshes could lose it on every attempt.
  """
  use GenServer

  @tasks ServiceRadarWebNG.Topology.BitmapQueryTasks
  @max_running 8
  # Waiters expire at their own deadline (at most one second); this bounds the
  # queue when arrivals outpace that expiry.
  @max_waiting 64

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Runs `work` in a query task once admitted. The task is killed at `deadline`.

  Returns `{:ok, result}` or `{:error, reason}`, where reason is `:query_busy`
  when the work never started, `:query_timeout` when it did not finish, and
  `:query_unavailable` when it crashed.
  """
  def run(work, deadline) when is_function(work, 0) and is_integer(deadline) do
    reply = Process.alias()

    try do
      with :ok <- GenServer.call(__MODULE__, {:run, self(), reply, work, deadline}, max(deadline - now(), 0)) do
        await(reply, deadline)
      end
    catch
      :exit, _ -> {:error, :query_unavailable}
    after
      Process.unalias(reply)
      flush(reply)
    end
  end

  # Drops a start notice that raced a finished or expired response.
  defp flush(reply) do
    receive do
      {^reply, _message} -> flush(reply)
    after
      0 -> :ok
    end
  end

  defp await(reply, deadline) do
    receive do
      {^reply, {:started, pid}} -> await(reply, deadline, pid, Process.monitor(pid))
      {^reply, {:done, result}} -> {:ok, result}
    after
      max(deadline - now(), 0) -> {:error, :query_busy}
    end
  end

  defp await(reply, deadline, pid, ref) do
    receive do
      {^reply, {:done, result}} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, _pid, reason} ->
        exited(reply, reason)
    after
      max(deadline - now(), 0) ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> {:error, :query_timeout}
        end
    end
  end

  # The task sends its result before exiting, so a crash without one is final.
  defp exited(reply, reason) do
    receive do
      {^reply, {:done, result}} -> {:ok, result}
    after
      0 -> if reason == :killed, do: {:error, :query_timeout}, else: {:error, :query_unavailable}
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{running: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call({:run, caller, reply, work, deadline}, _from, state) do
    waiting = if :queue.len(state.waiting) < @max_waiting, do: state.waiting, else: live(state.waiting)

    if :queue.len(waiting) < @max_waiting do
      waiting = :queue.in({caller, reply, work, deadline}, waiting)
      {:reply, :ok, dispatch(%{state | waiting: waiting})}
    else
      {:reply, {:error, :query_busy}, %{state | waiting: waiting}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, dispatch(%{state | running: Map.delete(state.running, ref)})}
  end

  defp dispatch(state) do
    with true <- map_size(state.running) < @max_running,
         {{:value, entry}, waiting} <- :queue.out(state.waiting) do
      dispatch(start(entry, %{state | waiting: waiting}))
    else
      _ -> state
    end
  end

  defp start({caller, reply, work, deadline}, state) do
    budget = deadline - now()

    with true <- budget > 0 and Process.alive?(caller),
         {:ok, pid} <- Task.Supervisor.start_child(@tasks, fn -> execute(reply, work, budget) end) do
      send(reply, {reply, {:started, pid}})
      %{state | running: Map.put(state.running, Process.monitor(pid), pid)}
    else
      _ -> state
    end
  end

  defp execute(reply, work, budget) do
    # The timer also bounds a disconnected caller's database/authorization
    # work. Resource destruction releases a pin if cancellation skips `after`.
    {:ok, timer} = :timer.exit_after(budget, self(), :kill)

    try do
      send(reply, {reply, {:done, work.()}})
    after
      :timer.cancel(timer)
    end
  end

  defp live(waiting) do
    now = now()
    :queue.filter(fn {caller, _reply, _work, deadline} -> deadline > now and Process.alive?(caller) end, waiting)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
