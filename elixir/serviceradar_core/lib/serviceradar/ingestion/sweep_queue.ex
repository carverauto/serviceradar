defmodule ServiceRadar.Ingestion.SweepQueue do
  @moduledoc """
  Bounded background queue for sweep result chunks.

  An agent reports one scan as a burst of chunks, and the gateway acknowledges
  sweep results to the agent before core ingests them. A lane that bounds the
  wait for a worker therefore drops the tail of every burst it cannot finish in
  time, including the final chunk that completes the execution. This queue
  acknowledges a chunk once it is queued and never expires it for waiting.

  It speaks the admission lane's reserve/submit protocol, so the gateway, the
  status handler and the results router reach it unchanged. Capacity is checked
  at reservation: a full queue rejects the reservation, and the gateway's status
  buffer keeps the chunk and offers it again.

  Chunks that share an agent and sweep group run one at a time in arrival
  order; other agents and groups run concurrently. A chunk therefore waits for
  the chunks ahead of it in its own group, at most `max_items_per_agent` of
  them, and for a free worker. Each attempt has a deadline that includes the
  wait for a database permit. A worker that crashes or overruns it is killed
  and the chunk retried, up to `max_attempts` in all. An error or unexpected
  processor result is final and not retried: ingestion may already have counted
  the chunk's hosts. Accepted chunks live
  in memory and are lost if the coordinator restarts.
  """

  use GenServer

  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.Ingestion.WorkerBudget

  require Logger

  @lane :sweep
  @source_max_bytes 16 * 1_024 * 1_024
  @reservation_ttl_ms 2_000
  @start_retry_ms 100
  @defaults [
    max_items: 128,
    max_bytes: 32 * 1_024 * 1_024,
    max_items_per_agent: 32,
    concurrency: 4,
    worker_timeout_ms: 60_000,
    max_attempts: 2,
    retry_delay_ms: 1_000
  ]
  @positive_keys [
    :max_items,
    :max_bytes,
    :max_items_per_agent,
    :max_bytes_per_agent,
    :concurrency,
    :worker_timeout_ms,
    :max_attempts
  ]

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Queue limits: defaults, then the `:sweep` ingestion config, then `overrides`."
  def limits(overrides \\ []) do
    config = Application.get_env(:serviceradar_core, ServiceRadar.Ingestion.Supervisor, [])

    @defaults
    |> Keyword.merge(Keyword.get(config, :sweep, []))
    |> Keyword.merge(overrides)
    |> Lane.with_per_agent_bytes(@source_max_bytes)
  end

  @impl true
  def init(opts) do
    config = limits(Keyword.get(opts, :config, []))

    case validate_config(config) do
      :ok ->
        # Trap exits so a supervised shutdown reports the accepted chunks it loses.
        Process.flag(:trap_exit, true)

        state = %{
          config: config,
          task_supervisor: Keyword.fetch!(opts, :task_supervisor),
          processor:
            Keyword.get(opts, :processor, {ServiceRadar.Ingestion.Admission, :ingest, []}),
          execution_gate: Keyword.get(opts, :execution_gate, WorkerBudget),
          jobs: %{},
          queue: :queue.new(),
          running: %{},
          monitors: %{},
          bytes: 0,
          agents: %{}
        }

        {:ok, emit_state(state)}

      {:error, reason} ->
        {:stop, {:invalid_sweep_queue_config, reason}}
    end
  end

  @impl true
  def handle_call({:reserve, descriptor, owner, _timeout, call_ref}, _from, state) do
    {reply, next_state} = reserve_reply(state, descriptor, owner, call_ref)
    {:reply, reply, next_state}
  end

  def handle_call({:submit, id, status, mode}, _from, state),
    do: submit(state, id, status, mode, :infinity)

  def handle_call({:submit, id, status, mode, submit_timeout}, _from, state)
      when is_integer(submit_timeout) and submit_timeout > 0,
      do: submit(state, id, status, mode, submit_timeout)

  def handle_call({:submit, _id, _status, _mode, _timeout}, _from, state),
    do: {:reply, {:error, :invalid_admission_mode}, state}

  defp reserve_reply(state, descriptor, owner, call_ref) do
    case reserve(state, descriptor, owner, call_ref) do
      {:ok, id, next_state} ->
        emit(:admitted, %{count: 1}, %{})
        {{:ok, {self(), id}}, emit_state(next_state)}

      {:error, reason} ->
        emit(:rejected, %{count: 1}, %{reason: reason})
        {{:error, reason}, state}
    end
  end

  # A reservation forwarded by the status router, answered here so the router
  # never waits on this queue (see `ServiceRadar.Ingestion.Admission.forward_reserve/2`).
  @impl true
  def handle_cast({:reserve_for, descriptor, owner, from}, state) do
    {reply, next_state} = reserve_reply(state, descriptor, owner, nil)
    GenServer.reply(from, reply)
    {:noreply, next_state}
  end

  def handle_cast({:cancel, id}, state) do
    case Map.get(state.jobs, id) do
      nil -> {:noreply, state}
      job -> {:noreply, cancel(state, job)}
    end
  end

  def handle_cast({:cancel_ref, call_ref}, state) do
    case Enum.find(Map.values(state.jobs), &(&1.client_ref == call_ref)) do
      nil -> {:noreply, state}
      job -> {:noreply, cancel(state, job)}
    end
  end

  @impl true
  def handle_info({:reservation_expired, id}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :reserved} = job -> {:noreply, state |> remove(job) |> dispatch() |> emit_state()}
      _ -> {:noreply, state}
    end
  end

  def handle_info(:dispatch, state), do: {:noreply, state |> dispatch() |> emit_state()}

  def handle_info({:worker_result, id, worker, result}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :running, worker: ^worker} = job ->
        {:noreply, finish(state, job, result)}

      # The result beat the kill. That attempt finished, so it is not retried.
      %{phase: :terminating, worker: ^worker} = job ->
        {:noreply, put_job(state, %{job | result: result})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_deadline, id, worker}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :running, worker: ^worker} = job ->
        # Keep the key busy until the worker is gone, so a retry cannot
        # overlap the persistence work of the attempt it replaces.
        Process.exit(worker, :kill)

        emit(
          :timeout,
          %{count: 1, acknowledgement_ms: elapsed_ms(job.admitted_at)},
          %{reason: :execution_timeout}
        )

        {:noreply, put_job(state, %{job | phase: :terminating, failure: :execution_timeout})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {id, monitors} ->
        state = %{state | monitors: monitors}
        {:noreply, handle_down(state, Map.get(state.jobs, id), reason)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    accepted = Enum.count(state.jobs, fn {_id, job} -> job.phase != :reserved end)

    if accepted > 0 do
      Logger.warning(
        "Sweep result queue stopped with #{accepted} accepted chunks not yet ingested"
      )
    end

    :ok
  end

  defp reserve(state, descriptor, owner, call_ref) do
    with :ok <- Lane.validate_descriptor(descriptor),
         %{headers: headers, payload_bytes: bytes, retained_bytes: retained} = descriptor,
         agent_id = agent_id(headers),
         :ok <- validate_capacity(state, bytes, retained, agent_id) do
      id = make_ref()
      now = now_ms()
      ttl = min(descriptor.remaining_ms, @reservation_ttl_ms)
      monitor = if is_pid(owner), do: Process.monitor(owner)

      job = %{
        id: id,
        client_ref: call_ref,
        phase: :reserved,
        status: nil,
        headers: headers,
        agent_id: agent_id,
        key: ordering_key(headers, agent_id),
        payload_bytes: bytes,
        retained_bytes: retained,
        admitted_at: now,
        queued_at: nil,
        reserved_until: now + ttl,
        timer: Process.send_after(self(), {:reservation_expired, id}, ttl),
        monitor: monitor,
        attempts: 0,
        not_before: nil,
        worker: nil,
        worker_ref: nil,
        started_at: nil,
        failure: nil,
        result: :no_result
      }

      # A reservation holds its place in arrival order, so a chunk reserved
      # first runs first even when its payload arrives second.
      next_state = %{
        state
        | jobs: Map.put(state.jobs, id, job),
          queue: :queue.in(id, state.queue),
          monitors: put_monitor(state.monitors, monitor, id),
          bytes: state.bytes + retained,
          agents: Map.update(state.agents, agent_id, {1, retained}, &add_agent(&1, retained))
      }

      {:ok, id, next_state}
    end
  end

  defp submit(state, id, status, mode, submit_timeout) do
    with {:ok, reply_to} <- reply_target(mode),
         %{phase: :reserved} = job <- Map.get(state.jobs, id, :reservation_expired),
         :ok <- validate_submit(job, status, submit_timeout) do
      Process.cancel_timer(job.timer)
      demonitor(job.monitor)

      # Nobody waits for the ingestion result, so it publishes service state
      # the best-effort way, whatever mode the caller submitted with.
      queued = %{
        job
        | phase: :queued,
          status: Map.put(status, :ingestion_best_effort, true),
          queued_at: now_ms(),
          timer: nil,
          monitor: nil
      }

      reply(reply_to, :ok)

      next_state =
        %{state | monitors: Map.delete(state.monitors, job.monitor)}
        |> put_job(queued)
        |> dispatch()
        |> emit_state()

      {:reply, :ok, next_state}
    else
      {:error, reason, job} ->
        {:reply, {:error, reason}, state |> remove(job) |> dispatch() |> emit_state()}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      _expired ->
        {:reply, {:error, :reservation_expired}, state}
    end
  end

  # Every mode is acknowledged on enqueue; nothing waits for ingestion.
  defp reply_target(mode) when mode in [:wait, :best_effort], do: {:ok, nil}
  defp reply_target({:reply_to, target}), do: {:ok, target}
  defp reply_target(_mode), do: {:error, :invalid_admission_mode}

  defp validate_submit(job, status, submit_timeout) when is_map(status) do
    actual = Lane.descriptor(status, 1)
    now = now_ms()

    cond do
      now >= job.reserved_until or stale_submit?(now, job, submit_timeout) ->
        {:error, :admission_timeout, job}

      actual.headers != job.headers or actual.retained_bytes != job.retained_bytes ->
        {:error, :reservation_payload_mismatch, job}

      true ->
        :ok
    end
  end

  defp validate_submit(job, _status, _submit_timeout),
    do: {:error, :reservation_payload_mismatch, job}

  defp stale_submit?(_now, _job, :infinity), do: false
  defp stale_submit?(now, job, submit_timeout), do: now >= job.admitted_at + submit_timeout

  defp cancel(state, %{phase: phase} = job) when phase in [:reserved, :queued],
    do: state |> remove(job) |> dispatch() |> emit_state()

  defp cancel(state, %{phase: :running} = job) do
    Process.cancel_timer(job.timer)
    Process.exit(job.worker, :kill)
    put_job(state, %{job | phase: :terminating, failure: :cancelled})
  end

  defp cancel(state, %{phase: :terminating} = job),
    do: put_job(state, %{job | failure: :cancelled})

  defp handle_down(state, nil, _reason), do: state

  defp handle_down(state, %{phase: :reserved} = job, _reason),
    do: state |> remove(job) |> dispatch() |> emit_state()

  defp handle_down(state, %{phase: :running} = job, reason) do
    Process.cancel_timer(job.timer)

    emit(
      :crash,
      %{count: 1, acknowledgement_ms: elapsed_ms(job.admitted_at)},
      %{reason: :worker_crash, exit_reason: bounded_reason(reason)}
    )

    retry_or_drop(state, %{job | failure: :worker_crash})
  end

  defp handle_down(state, %{phase: :terminating, failure: :cancelled} = job, _reason) do
    emit_completion(job, :cancelled)
    state |> remove(job) |> dispatch() |> emit_state()
  end

  defp handle_down(state, %{phase: :terminating, result: result} = job, _reason)
       when result != :no_result,
       do: finish(state, job, result)

  defp handle_down(state, %{phase: :terminating} = job, _reason), do: retry_or_drop(state, job)

  defp finish(state, job, result) do
    Process.cancel_timer(job.timer)
    demonitor(job.worker_ref)
    label = result_label(result)

    emit(:execution, execution_measurements(job, result), %{result: label})
    emit_completion(job, label)

    if label != :committed do
      Logger.warning(
        "Sweep result chunk ingestion failed and will not be retried (#{describe(job)}): " <>
          inspect(result, limit: 8, printable_limit: 256)
      )
    end

    state |> remove(job) |> dispatch() |> emit_state()
  end

  defp retry_or_drop(state, job) do
    state = %{state | running: Map.delete(state.running, job.id)}

    if job.attempts < state.config[:max_attempts] do
      delay = state.config[:retry_delay_ms]
      emit(:retry, %{count: 1}, %{reason: job.failure})

      Logger.warning(
        "Sweep result chunk ingestion attempt #{job.attempts} ended with #{job.failure}; " <>
          "retrying in #{delay}ms (#{describe(job)})"
      )

      retried = %{
        job
        | phase: :queued,
          worker: nil,
          worker_ref: nil,
          timer: nil,
          result: :no_result,
          not_before: now_ms() + delay
      }

      # The retry goes back to the head of the queue, ahead of the later
      # chunks of its own key, which stay blocked behind it.
      Process.send_after(self(), :dispatch, delay)

      %{put_job(state, retried) | queue: :queue.in_r(job.id, state.queue)}
      |> dispatch()
      |> emit_state()
    else
      emit(:failed, %{count: 1}, %{reason: job.failure})
      emit_completion(job, job.failure)

      Logger.error(
        "Sweep result chunk dropped after #{job.attempts} attempts ending with " <>
          "#{job.failure} (#{describe(job)})"
      )

      state |> remove(job) |> dispatch() |> emit_state()
    end
  end

  defp dispatch(state) do
    if map_size(state.running) >= state.config[:concurrency] do
      state
    else
      busy = MapSet.new(Map.keys(state.running), &state.jobs[&1].key)

      case next_job(:queue.to_list(state.queue), state.jobs, busy, now_ms()) do
        nil -> state
        job -> start(state, job)
      end
    end
  end

  # Only the first queued chunk of each key may start. A key whose first chunk
  # is running, reserved, or waiting to retry blocks the chunks behind it.
  defp next_job([], _jobs, _blocked, _now), do: nil

  defp next_job([id | rest], jobs, blocked, now) do
    job = Map.fetch!(jobs, id)

    cond do
      MapSet.member?(blocked, job.key) -> next_job(rest, jobs, blocked, now)
      job.phase == :queued and ready?(job, now) -> job
      true -> next_job(rest, jobs, MapSet.put(blocked, job.key), now)
    end
  end

  defp ready?(%{not_before: nil}, _now), do: true
  defp ready?(%{not_before: not_before}, now), do: not_before <= now

  defp start(state, job) do
    case start_worker(state, job) do
      {:ok, worker} ->
        ref = Process.monitor(worker)

        timer =
          Process.send_after(
            self(),
            {:worker_deadline, job.id, worker},
            state.config[:worker_timeout_ms]
          )

        emit(
          :admission,
          %{wait_ms: elapsed_ms(job.queued_at), payload_bytes: job.payload_bytes},
          %{}
        )

        running = %{
          job
          | phase: :running,
            attempts: job.attempts + 1,
            worker: worker,
            worker_ref: ref,
            timer: timer,
            started_at: now_ms(),
            not_before: nil
        }

        # The worker waits for this message, so its result and exit cannot
        # arrive before the job and monitor that correlate them exist.
        send(worker, {:start, job.id})

        dispatch(%{
          put_job(state, running)
          | queue: :queue.delete(job.id, state.queue),
            running: Map.put(state.running, job.id, true),
            monitors: Map.put(state.monitors, ref, job.id)
        })

      {:error, reason} ->
        # A worker slot freed by a killed worker can lag its monitor. The chunk
        # stays queued and the next dispatch tries again.
        Logger.debug("Sweep result worker did not start: #{inspect(reason)}")
        Process.send_after(self(), :dispatch, @start_retry_ms)
        state
    end
  end

  defp start_worker(state, job) do
    coordinator = self()
    %{processor: processor, execution_gate: gate} = state
    %{id: id, status: status} = job

    Task.Supervisor.start_child(state.task_supervisor, fn ->
      receive do
        {:start, ^id} ->
          result =
            if gate do
              WorkerBudget.run(gate, @lane, fn -> invoke(processor, status) end)
            else
              invoke(processor, status)
            end

          send(coordinator, {:worker_result, id, self(), result})
      end
    end)
  catch
    :exit, reason -> {:error, reason}
  end

  defp invoke({module, function, extra_args}, status),
    do: apply(module, function, [status | extra_args])

  defp invoke(fun, status) when is_function(fun, 1), do: fun.(status)

  defp remove(state, job) do
    if is_reference(job.timer), do: Process.cancel_timer(job.timer)
    demonitor(job.monitor)
    demonitor(job.worker_ref)

    %{
      state
      | jobs: Map.delete(state.jobs, job.id),
        queue: :queue.delete(job.id, state.queue),
        running: Map.delete(state.running, job.id),
        monitors: Map.drop(state.monitors, [job.monitor, job.worker_ref]),
        bytes: state.bytes - job.retained_bytes,
        agents: release_agent(state.agents, job.agent_id, job.retained_bytes)
    }
  end

  defp put_job(state, job), do: %{state | jobs: Map.put(state.jobs, job.id, job)}

  defp put_monitor(monitors, nil, _id), do: monitors
  defp put_monitor(monitors, ref, id), do: Map.put(monitors, ref, id)

  defp demonitor(ref) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp demonitor(_ref), do: :ok

  defp validate_capacity(state, bytes, retained, agent_id) do
    config = state.config
    {agent_items, agent_bytes} = Map.get(state.agents, agent_id, {0, 0})

    cond do
      bytes > @source_max_bytes -> {:error, :wire_payload_too_large}
      map_size(state.jobs) >= config[:max_items] -> {:error, :count_full}
      state.bytes + retained > config[:max_bytes] -> {:error, :configured_byte_full}
      agent_bytes + retained > config[:max_bytes_per_agent] -> {:error, :per_agent_byte_full}
      agent_items >= config[:max_items_per_agent] -> {:error, :per_agent_full}
      true -> :ok
    end
  end

  defp add_agent({items, bytes}, retained), do: {items + 1, bytes + retained}

  defp release_agent(agents, agent_id, retained) do
    case Map.get(agents, agent_id) do
      {items, _bytes} when items <= 1 -> Map.delete(agents, agent_id)
      {items, bytes} -> Map.put(agents, agent_id, {items - 1, bytes - retained})
      nil -> agents
    end
  end

  defp validate_config(config) do
    case Enum.find(@positive_keys, &(not positive_integer?(config[&1]))) do
      nil ->
        if is_integer(config[:retry_delay_ms]) and config[:retry_delay_ms] >= 0,
          do: :ok,
          else: {:error, {:negative, :retry_delay_ms}}

      key ->
        {:error, {:non_positive, key}}
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp agent_id(headers), do: headers[:agent_id] || "unknown"

  # An execution belongs to one agent and sweep group. A status without
  # prepared group metadata keeps the conservative per-agent key.
  defp ordering_key(%{sweep_group_id: group}, agent_id), do: {agent_id, group}
  defp ordering_key(_headers, agent_id), do: agent_id

  defp describe(job) do
    status = job.status || %{}

    "agent #{job.agent_id}, sweep group #{job.headers[:sweep_group_id] || "unknown"}, " <>
      "chunk_index #{inspect(status[:chunk_index])} of #{inspect(status[:total_chunks])}"
  end

  defp reply(nil, _result), do: :ok
  defp reply(reply_to, result), do: GenServer.reply(reply_to, result)

  defp result_label(:ok), do: :committed
  defp result_label({:ok, _}), do: :committed
  defp result_label({:error, _}), do: :failed
  defp result_label(_), do: :unexpected

  defp execution_measurements(job, result) do
    measurements = %{
      count: 1,
      duration_ms: elapsed_ms(job.started_at),
      acknowledgement_ms: elapsed_ms(job.admitted_at),
      payload_bytes: job.payload_bytes
    }

    case result do
      {:ok, %{event_count: event_count}} when is_integer(event_count) and event_count >= 0 ->
        Map.put(measurements, :event_count, event_count)

      _ ->
        measurements
    end
  end

  defp emit_completion(job, result) do
    emit(
      :completion,
      %{
        count: 1,
        acknowledgement_ms: elapsed_ms(job.admitted_at),
        payload_bytes: job.payload_bytes
      },
      %{result: result}
    )
  end

  defp emit_state(state) do
    {in_flight_count, in_flight_bytes} =
      Enum.reduce(state.running, {0, 0}, fn {id, _}, {count, bytes} ->
        {count + 1, bytes + state.jobs[id].retained_bytes}
      end)

    oldest_queued_at =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.phase == :queued))
      |> Enum.map(& &1.queued_at)
      |> Enum.min(fn -> nil end)

    emit(
      :state,
      %{
        pending_count: map_size(state.jobs) - in_flight_count,
        pending_bytes: state.bytes - in_flight_bytes,
        in_flight_count: in_flight_count,
        in_flight_bytes: in_flight_bytes,
        oldest_pending_ms: if(oldest_queued_at, do: elapsed_ms(oldest_queued_at), else: 0)
      },
      %{}
    )

    state
  end

  # The same events, names and lane label as ServiceRadar.Admission.Lane, so
  # the sweep lane's existing dashboards and alerts keep reading this queue.
  defp emit(event, measurements, metadata) do
    runtime_measurements =
      case measurements do
        %{wait_ms: wait} -> Map.put(measurements, :queue_wait_ms, wait)
        measurements -> measurements
      end

    runtime_measurements =
      if event == :completion do
        outcome = if metadata[:result] == :committed, do: :accepted, else: :not_accepted
        Map.put(runtime_measurements, :outcome, outcome)
      else
        runtime_measurements
      end

    RuntimeMetrics.record(@lane, event, Map.put(runtime_measurements, :reason, metadata[:reason]))

    :telemetry.execute(
      [:serviceradar, :admission_lane, event],
      measurements,
      Map.put(metadata, :lane, @lane)
    )
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp elapsed_ms(started_at), do: max(now_ms() - started_at, 0)

  defp bounded_reason(reason) when reason in [:normal, :shutdown, :killed, :noproc], do: reason
  defp bounded_reason(_reason), do: :unexpected
end
