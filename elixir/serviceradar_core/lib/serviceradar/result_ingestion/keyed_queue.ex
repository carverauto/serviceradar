defmodule ServiceRadar.ResultIngestion.KeyedQueue do
  @moduledoc """
  Bounded, keyed work queue for one result-ingestion class.

  `ServiceRadar.ResultsRouter` used to run every ingestor inline, so one slow
  ingest held up every other result in the fleet. Each result class now has one
  of these queues, and the router only admits work to it.

  * **Bounded.** Admission is rejected, with a reason, once the queued plus
    in-flight items or bytes would exceed the class limits, or once one key holds
    its share of them.
  * **Ordered per key.** At most one job per key runs at a time, and a key's jobs
    start in arrival order, so results that must apply in order (one agent's sweep
    chunks, say) still do.
  * **Concurrent across keys.** Up to `:workers` jobs for different keys run at
    once, on the queue's own `Task.Supervisor`, each with a timeout. The next job
    is the oldest one whose key is idle, so busy keys cannot starve quiet ones.
  * **Coalescing (optional).** For snapshot-style inputs a newer item replaces
    a key's job that has not started yet, instead of queueing behind it.

  A job is a zero-arity function run in the task. With a `:reply_to`, its result
  (or `{:error, :result_ingestion_timeout}` / `{:error, {:result_ingestion_task_exit,
  reason}}`) is sent to that caller with `GenServer.reply/2`.

  Telemetry: `[:serviceradar, :result_ingestion, event]` with `%{class: class}`
  metadata, for `:state` (pending/in-flight count and bytes), `:admission`
  (queue wait), `:execution` (duration, result), `:rejected` (reason),
  `:timeout` and `:crash`.
  """

  use GenServer

  require Logger

  @default_admission_timeout_ms 1_000

  defmodule Job do
    @moduledoc false
    defstruct [:id, :key, :bytes, :fun, :reply_to, :enqueued_at, :started_at, :task_ref, :timer]
  end

  @type admit_opt :: {:reply_to, GenServer.from() | nil} | {:timeout, timeout()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Admits `fun` under `key`, accounting `bytes` against the byte bounds.

  Returns `:ok` once the job is queued (the result goes to `:reply_to`, if
  given) or `{:error, reason}` when it is rejected.
  """
  @spec admit(GenServer.server(), term(), non_neg_integer(), (-> term()), [admit_opt()]) ::
          :ok | {:error, term()}
  def admit(server, key, bytes, fun, opts \\ []) when is_function(fun, 0) and is_integer(bytes) do
    timeout = Keyword.get(opts, :timeout, @default_admission_timeout_ms)
    GenServer.call(server, {:admit, key, bytes, fun, Keyword.get(opts, :reply_to)}, timeout)
  catch
    :exit, _reason -> {:error, :result_ingestion_queue_unavailable}
  end

  @doc "Current depth and bounds, for operator views. Never touches the database."
  @spec stats(GenServer.server()) :: {:ok, map()} | {:error, :unavailable}
  def stats(server) do
    {:ok, GenServer.call(server, :stats, @default_admission_timeout_ms)}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    state = %{
      class: Keyword.fetch!(opts, :class),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      workers: positive!(opts, :workers),
      max_items: positive!(opts, :max_items),
      max_bytes: positive!(opts, :max_bytes),
      max_items_per_key: positive!(opts, :max_items_per_key),
      job_timeout_ms: positive!(opts, :job_timeout_ms),
      coalesce?: Keyword.get(opts, :coalesce, false),
      pending: :queue.new(),
      running: %{},
      running_keys: MapSet.new(),
      items_by_key: %{},
      items: 0,
      bytes: 0,
      in_flight_bytes: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:admit, key, bytes, fun, reply_to}, _from, state) do
    job = %Job{
      id: make_ref(),
      key: key,
      bytes: bytes,
      fun: fun,
      reply_to: reply_to,
      enqueued_at: System.monotonic_time(:millisecond)
    }

    case coalesce_or_admit(state, job) do
      {:ok, state} ->
        state = dispatch(state)
        emit_state(state)
        {:reply, :ok, state}

      {:error, reason} ->
        emit(state, :rejected, %{count: 1}, %{reason: reason})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      class: state.class,
      pending_count: :queue.len(state.pending),
      in_flight_count: map_size(state.running),
      items: state.items,
      bytes: state.bytes,
      max_items: state.max_items,
      max_bytes: state.max_bytes,
      workers: state.workers
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {job, running} ->
        Process.demonitor(ref, [:flush])
        cancel_timer(job.timer)
        reply(job, result)
        emit_execution(state, job, result_tag(result))
        {:noreply, state |> finish(job, running) |> dispatch() |> tap(&emit_state/1)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {job, running} ->
        cancel_timer(job.timer)
        reply(job, {:error, {:result_ingestion_task_exit, reason}})
        emit(state, :crash, %{count: 1}, %{exit_reason: crash_reason(reason)})
        Logger.warning("#{state.class} result ingestion task exited: #{inspect(reason)}")
        {:noreply, state |> finish(job, running) |> dispatch() |> tap(&emit_state/1)}
    end
  end

  def handle_info({:job_timeout, ref}, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, state}

      {job, running} ->
        Process.demonitor(ref, [:flush])
        _ = Task.Supervisor.terminate_child(state.task_supervisor, task_pid(job))
        reply(job, {:error, :result_ingestion_timeout})
        emit(state, :timeout, %{count: 1}, %{})

        Logger.warning(
          "#{state.class} result ingestion timed out after #{state.job_timeout_ms}ms"
        )

        {:noreply, state |> finish(job, running) |> dispatch() |> tap(&emit_state/1)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A pending (not yet started) job for the key is replaced in place by the newer
  # one. The replaced job's caller, if any, is told it was superseded.
  defp coalesce_or_admit(%{coalesce?: true} = state, job) do
    case pending_job_for(state, job.key) do
      nil ->
        admit_new(state, job)

      old ->
        if state.bytes - old.bytes + job.bytes > state.max_bytes do
          {:error, :result_ingestion_bytes_full}
        else
          reply(old, {:error, :result_ingestion_superseded})

          pending =
            :queue.filter(
              fn queued -> if queued.id == old.id, do: [job], else: true end,
              state.pending
            )

          {:ok, %{state | pending: pending, bytes: state.bytes - old.bytes + job.bytes}}
        end
    end
  end

  defp coalesce_or_admit(state, job), do: admit_new(state, job)

  defp admit_new(state, job) do
    key_items = Map.get(state.items_by_key, job.key, 0)

    cond do
      state.items + 1 > state.max_items -> {:error, :result_ingestion_queue_full}
      state.bytes + job.bytes > state.max_bytes -> {:error, :result_ingestion_bytes_full}
      key_items + 1 > state.max_items_per_key -> {:error, :result_ingestion_key_full}
      true -> {:ok, enqueue(state, job, key_items)}
    end
  end

  defp enqueue(state, job, key_items) do
    %{
      state
      | pending: :queue.in(job, state.pending),
        items: state.items + 1,
        bytes: state.bytes + job.bytes,
        items_by_key: Map.put(state.items_by_key, job.key, key_items + 1)
    }
  end

  defp pending_job_for(state, key) do
    state.pending |> :queue.to_list() |> Enum.find(&(&1.key == key))
  end

  defp dispatch(state) do
    if map_size(state.running) < state.workers do
      case take_runnable(state) do
        nil -> state
        {job, pending} -> %{state | pending: pending} |> start(job) |> dispatch()
      end
    else
      state
    end
  end

  # The oldest pending job whose key has nothing running.
  defp take_runnable(state) do
    list = :queue.to_list(state.pending)

    case Enum.split_while(list, &MapSet.member?(state.running_keys, &1.key)) do
      {_blocked, []} -> nil
      {blocked, [job | rest]} -> {job, :queue.from_list(blocked ++ rest)}
    end
  end

  defp start(state, job) do
    now = System.monotonic_time(:millisecond)
    emit(state, :admission, %{wait_ms: now - job.enqueued_at}, %{})

    task = Task.Supervisor.async_nolink(state.task_supervisor, job.fun)
    timer = Process.send_after(self(), {:job_timeout, task.ref}, state.job_timeout_ms)
    job = %{job | started_at: now, task_ref: task, timer: timer}

    %{
      state
      | running: Map.put(state.running, task.ref, job),
        running_keys: MapSet.put(state.running_keys, job.key),
        in_flight_bytes: state.in_flight_bytes + job.bytes
    }
  end

  defp finish(state, job, running) do
    key_items = Map.get(state.items_by_key, job.key, 1) - 1

    %{
      state
      | running: running,
        running_keys: MapSet.delete(state.running_keys, job.key),
        items: state.items - 1,
        bytes: state.bytes - job.bytes,
        in_flight_bytes: state.in_flight_bytes - job.bytes,
        items_by_key:
          if(key_items > 0,
            do: Map.put(state.items_by_key, job.key, key_items),
            else: Map.delete(state.items_by_key, job.key)
          )
    }
  end

  defp task_pid(%Job{task_ref: %Task{pid: pid}}), do: pid

  defp reply(%Job{reply_to: nil}, _result), do: :ok
  defp reply(%Job{reply_to: reply_to}, result), do: GenServer.reply(reply_to, result)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp result_tag(:ok), do: :ok
  defp result_tag({:ok, _}), do: :ok
  defp result_tag(_other), do: :error

  defp crash_reason({reason, _stack}) when is_atom(reason), do: reason
  defp crash_reason(reason) when is_atom(reason), do: reason
  defp crash_reason(_reason), do: :other

  defp emit_execution(state, job, result) do
    duration = System.monotonic_time(:millisecond) - job.started_at

    emit(state, :execution, %{count: 1, duration_ms: duration, bytes: job.bytes}, %{
      result: result
    })
  end

  defp emit_state(state) do
    emit(
      state,
      :state,
      %{
        pending_count: :queue.len(state.pending),
        pending_bytes: state.bytes - state.in_flight_bytes,
        in_flight_count: map_size(state.running),
        in_flight_bytes: state.in_flight_bytes
      },
      %{}
    )
  end

  defp emit(state, event, measurements, metadata) do
    :telemetry.execute(
      [:serviceradar, :result_ingestion, event],
      measurements,
      Map.put(metadata, :class, state.class)
    )
  end

  defp positive!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(other)}"
    end
  end
end
