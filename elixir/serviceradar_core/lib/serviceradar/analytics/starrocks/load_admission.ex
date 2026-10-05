defmodule ServiceRadar.Analytics.StarRocks.LoadAdmission do
  @moduledoc """
  Node-wide Stream Load admission, shared by every dataset and flow pipeline.

  `max_in_flight` limits complete load operations, including sequential redirects
  and label reconciliation. Waiting callers retain their own payloads under
  Broadway backpressure; this server stores only monitored caller references.
  At most twice the concurrency limit may wait, with combined encoded bodies
  bounded by `max_bytes * max_in_flight`. Overload or a 60-second wait returns an
  error to the existing JetStream retry path. There is no independent retry queue.

  This is a node-wide budget for the single coordinator-owned ingestion tree.
  Horizontal workers require deployment-wide admission before enabling #5285.
  """

  use GenServer

  alias ServiceRadar.Analytics.StarRocks.Destination

  @wait_timeout_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # The admitted worker is unlinked from the caller, so a supervisor restart
  # that stops the worker never propagates a linked exit into a normal
  # (non-trapping) caller: the await below maps the worker death to the
  # retryable admission error instead. An unlinked watcher still stops the
  # worker when its caller dies, using a catchable shutdown so real HTTP
  # requests are cancelled before the permit is reused.
  def run(bytes, fun) do
    # Capture the caller before starting work: self() inside the fun would
    # return the worker itself and caller death would never cancel.
    caller = self()

    task =
      try do
        Task.Supervisor.async_nolink(ServiceRadar.Analytics.StarRocks.LoadTasks, fn ->
          worker = self()
          watcher = spawn_link(fn -> watch_caller(caller, worker) end)

          try do
            {:result, run_admitted(bytes, fun)}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          after
            Process.unlink(watcher)
            Process.exit(watcher, :kill)
          end
        end)
      catch
        :exit, _ -> nil
      end

    case task do
      nil ->
        {:error, :load_admission_unavailable}

      task ->
        awaited =
          try do
            Task.await(task, :infinity)
          catch
            :exit, _ -> {:result, {:error, :load_admission_unavailable}}
          end

        case awaited do
          {:result, result} ->
            result

          {:raised, :exit, reason, _stacktrace}
          when reason in [:shutdown, :killed] ->
            {:error, :load_admission_unavailable}

          {:raised, :exit, {:shutdown, _}, _} ->
            {:error, :load_admission_unavailable}

          {:raised, kind, reason, stacktrace} ->
            :erlang.raise(kind, reason, stacktrace)
        end
    end
  end

  # Unlinked from the caller, so it survives caller death long enough to
  # cancel the worker. Exits normally once the worker completes.
  defp watch_caller(caller, worker) do
    caller_ref = Process.monitor(caller)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^caller_ref, :process, _, _} ->
        Process.demonitor(worker_ref, [:flush])
        shutdown_worker(worker)

      {:DOWN, ^worker_ref, :process, _, _} ->
        Process.demonitor(caller_ref, [:flush])
        :ok
    end
  end

  # A catchable shutdown lets a worker inside the default HTTP adapter trap
  # the exit, cancel its HTTP request, and die before capacity is reused.
  # Escalation to :kill is bounded: only when the worker ignores shutdown.
  defp shutdown_worker(worker) do
    ref = Process.monitor(worker)
    Process.exit(worker, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^worker, _} -> :ok
    after
      5_000 ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)
        :ok
    end
  end

  defp run_admitted(bytes, fun) do
    server = Process.whereis(__MODULE__)

    if is_pid(server) do
      acquired =
        try do
          GenServer.call(server, {:acquire, bytes}, :infinity)
        catch
          :exit, _ -> {:error, :load_admission_unavailable}
        end

      case acquired do
        {:ok, token} ->
          try do
            fun.()
          after
            GenServer.cast(server, {:release, token})
          end

        {:error, _} = error ->
          error
      end
    else
      {:error, :load_admission_unavailable}
    end
  end

  @impl true
  def init(opts) do
    limits = Destination.stream_load_limits()
    limit = Keyword.get(opts, :max_in_flight, limits[:max_in_flight])

    {:ok,
     %{
       limit: limit,
       max_waiters: limit * 2,
       max_wait_bytes: limits[:max_bytes] * limit,
       wait_timeout_ms: Keyword.get(opts, :wait_timeout_ms, @wait_timeout_ms),
       active: %{},
       waiting: [],
       waiting_bytes: 0
     }}
  end

  @impl true
  def handle_call({:acquire, bytes}, from, state) do
    cond do
      map_size(state.active) < state.limit ->
        token = Process.monitor(elem(from, 0))
        {:reply, {:ok, token}, %{state | active: Map.put(state.active, token, from)}}

      length(state.waiting) >= state.max_waiters or
          state.waiting_bytes + bytes > state.max_wait_bytes ->
        {:reply, {:error, :load_admission_full}, state}

      true ->
        token = Process.monitor(elem(from, 0))
        timer = Process.send_after(self(), {:wait_timeout, token}, state.wait_timeout_ms)
        waiter = %{token: token, from: from, bytes: bytes, timer: timer}

        {:noreply,
         %{state | waiting: state.waiting ++ [waiter], waiting_bytes: state.waiting_bytes + bytes}}
    end
  end

  @impl true
  def handle_cast({:release, token}, state), do: {:noreply, release(state, token)}

  @impl true
  def handle_info({:DOWN, token, :process, _pid, _reason}, state) do
    {:noreply, state |> drop_waiter(token) |> release(token)}
  end

  def handle_info({:wait_timeout, token}, state) do
    case Enum.find(state.waiting, &(&1.token == token)) do
      nil -> :ok
      waiter -> GenServer.reply(waiter.from, {:error, :load_admission_timeout})
    end

    {:noreply, drop_waiter(state, token)}
  end

  defp release(state, token) do
    Process.demonitor(token, [:flush])
    dispatch(%{state | active: Map.delete(state.active, token)})
  end

  defp drop_waiter(state, token) do
    {removed, waiting} = Enum.split_with(state.waiting, &(&1.token == token))

    Enum.each(removed, fn waiter ->
      Process.cancel_timer(waiter.timer)
      Process.demonitor(waiter.token, [:flush])
    end)

    bytes = Enum.reduce(removed, 0, &(&1.bytes + &2))
    %{state | waiting: waiting, waiting_bytes: state.waiting_bytes - bytes}
  end

  defp dispatch(%{waiting: [waiter | _]} = state) when map_size(state.active) < state.limit do
    state = drop_waiter(state, waiter.token)
    # Re-monitor after removing the queued monitor. A dead waiter must never
    # reserve capacity; death immediately after this check is caught by DOWN.
    pid = elem(waiter.from, 0)

    if Process.alive?(pid) do
      token = Process.monitor(pid)
      GenServer.reply(waiter.from, {:ok, token})
      dispatch(%{state | active: Map.put(state.active, token, waiter.from)})
    else
      dispatch(state)
    end
  end

  defp dispatch(state), do: state
end
