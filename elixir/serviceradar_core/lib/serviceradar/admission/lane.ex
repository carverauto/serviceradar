defmodule ServiceRadar.Admission.Lane do
  @moduledoc false

  use GenServer

  @envelope_overhead_bytes 256
  @max_queue_wait_ms 2_000
  @max_worker_timeout_ms 20_000
  @deadline_reserve_ms 3_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def admit(server, status, reply_to) do
    # There is deliberately no client-side timeout here. The coordinator never
    # executes handlers or database work, and timing out a call whose message is
    # already in its mailbox could produce an immediate rejection followed by a
    # second, late reply to the original caller after admission succeeds.
    GenServer.call(server, {:admit, status, reply_to}, :infinity)
  catch
    :exit, reason -> {:error, {:admission_lane_unavailable, reason}}
  end

  def admit_cast(server, status) do
    GenServer.cast(server, {:admit_cast, status})
    :ok
  catch
    :exit, reason -> {:error, {:admission_lane_unavailable, reason}}
  end

  def validate_config(config, gateway_max_ms) do
    keys = [:max_items, :max_bytes, :max_items_per_agent, :queue_wait_ms, :worker_timeout_ms]

    with :ok <- validate_positive(config, keys ++ [:gateway_call_timeout_ms]),
         :ok <- at_most(config, :queue_wait_ms, @max_queue_wait_ms),
         :ok <- at_most(config, :worker_timeout_ms, @max_worker_timeout_ms),
         :ok <- at_most(config, :gateway_call_timeout_ms, gateway_max_ms) do
      validate_deadline(config)
    end
  end

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    case validate_config(config, Keyword.fetch!(opts, :gateway_max_ms)) do
      :ok ->
        state = %{
          lane: Keyword.fetch!(opts, :lane),
          concurrency: Keyword.fetch!(opts, :concurrency),
          task_supervisor: Keyword.fetch!(opts, :task_supervisor),
          processor: Keyword.fetch!(opts, :processor),
          source_max_bytes: Keyword.fetch!(opts, :source_max_bytes),
          config: config,
          queue: :queue.new(),
          jobs: %{},
          monitors: %{},
          running: %{},
          admitted_bytes: 0,
          admitted_per_agent: %{}
        }

        emit_state(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:invalid_admission_lane_config, reason}}
    end
  end

  @impl true
  def handle_call({:admit, status, reply_to}, _from, state) do
    case do_admit(status, reply_to, state) do
      {:ok, next_state} -> {:reply, :ok, dispatch(next_state)}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_cast({:admit_cast, status}, state) do
    case do_admit(status, nil, state) do
      {:ok, next_state} -> {:noreply, dispatch(next_state)}
      {:error, _reason, next_state} -> {:noreply, next_state}
    end
  end

  @impl true
  def handle_info({:queue_timeout, id}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :queued} = job ->
        send(job.lease, {:deliver, {:error, :admission_timeout}})

        emit(
          state.lane,
          :timeout,
          %{count: 1, acknowledgement_ms: elapsed_ms(job.admitted_at)},
          %{reason: :admission_timeout}
        )

        emit_completion(state.lane, job, :admission_timeout)

        {:noreply, state |> remove_job(job) |> dispatch()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:execution_timeout, id}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :running} = job ->
        reply(job.reply_to, {:error, :execution_timeout})
        Process.exit(job.lease, :kill)

        emit(
          state.lane,
          :timeout,
          %{count: 1, acknowledgement_ms: elapsed_ms(job.admitted_at)},
          %{reason: :execution_timeout}
        )

        emit_completion(state.lane, job, :execution_timeout)

        {:noreply, state |> remove_job(job) |> dispatch()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_result, id, lease, result}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :running, lease: ^lease} = job ->
        Process.cancel_timer(job.execution_timer)
        duration_ms = elapsed_ms(job.started_at)

        if duration_ms >= state.config[:worker_timeout_ms] do
          send(lease, {:deliver, {:error, :execution_timeout}})

          emit(
            state.lane,
            :timeout,
            %{count: 1, acknowledgement_ms: elapsed_ms(job.admitted_at)},
            %{reason: :execution_timeout}
          )

          emit_completion(state.lane, job, :execution_timeout)
          {:noreply, state |> remove_job(job) |> dispatch()}
        else
          send(lease, {:deliver, normalize_result(result)})

          emit(
            state.lane,
            :execution,
            execution_measurements(job, result, duration_ms),
            %{result: result_label(result)}
          )

          emit_completion(state.lane, job, result_label(result))

          {:noreply, state |> remove_job(job) |> dispatch()}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.monitors, ref) do
      {:lease, id} -> handle_lease_exit(state, id, ref, reason)
      {:caller, id} -> handle_caller_exit(state, id, ref)
      nil -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_lease_exit(state, id, ref, reason) do
    case Map.get(state.jobs, id) do
      nil ->
        {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}

      job ->
        reply(job.reply_to, {:error, :worker_crash})

        emit(
          state.lane,
          :crash,
          %{count: 1, acknowledgement_ms: elapsed_ms(job.admitted_at)},
          %{reason: :worker_crash, exit_reason: bounded_reason(reason)}
        )

        emit_completion(state.lane, job, :worker_crash)

        {:noreply, state |> remove_job(job) |> dispatch()}
    end
  end

  defp handle_caller_exit(state, id, ref) do
    case Map.get(state.jobs, id) do
      nil ->
        {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}

      job ->
        Process.exit(job.lease, :kill)
        {:noreply, state |> remove_job(job) |> dispatch()}
    end
  end

  defp do_admit(status, reply_to, state) do
    payload_bytes = payload_bytes(status)
    retained_bytes = payload_bytes + @envelope_overhead_bytes
    agent_id = agent_id(status)

    with :ok <- validate_source_size(payload_bytes, state.source_max_bytes),
         :ok <- validate_capacity(state, retained_bytes, agent_id),
         {:ok, lease} <- start_lease(state, status, reply_to) do
      id = make_ref()
      lease_ref = Process.monitor(lease)
      caller_ref = monitor_caller(reply_to)
      admitted_at = now_ms()
      queue_timer = Process.send_after(self(), {:queue_timeout, id}, state.config[:queue_wait_ms])

      job = %{
        id: id,
        reply_to: reply_to,
        lease: lease,
        lease_ref: lease_ref,
        caller_ref: caller_ref,
        agent_id: agent_id,
        payload_bytes: payload_bytes,
        retained_bytes: retained_bytes,
        admitted_at: admitted_at,
        queue_timer: queue_timer,
        phase: :queued
      }

      send(lease, {:lease_id, id})

      next_state = %{
        state
        | queue: :queue.in(id, state.queue),
          jobs: Map.put(state.jobs, id, job),
          monitors:
            state.monitors
            |> Map.put(lease_ref, {:lease, id})
            |> maybe_put_monitor(caller_ref, {:caller, id}),
          admitted_bytes: state.admitted_bytes + retained_bytes,
          admitted_per_agent: Map.update(state.admitted_per_agent, agent_id, 1, &(&1 + 1))
      }

      emit_state(next_state)
      {:ok, next_state}
    else
      {:error, reason} ->
        emit(state.lane, :rejected, %{count: 1, payload_bytes: payload_bytes}, %{reason: reason})
        {:error, reason, state}
    end
  end

  defp start_lease(state, status, reply_to) do
    coordinator = self()
    processor = state.processor

    # The lightweight lease exists for queued as well as running work. It owns
    # the eventual GenServer.reply/2 and monitors the coordinator, so a lane
    # restart cannot strand a caller whose admission was already accepted.
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           lease(coordinator, processor, status, reply_to)
         end) do
      {:ok, pid} -> {:ok, pid}
      {:error, _reason} -> {:error, :worker_crash}
    end
  end

  defp lease(coordinator, processor, status, reply_to) do
    coordinator_ref = Process.monitor(coordinator)

    receive do
      {:lease_id, id} ->
        lease_wait(id, coordinator, coordinator_ref, processor, status, reply_to)

      {:DOWN, ^coordinator_ref, :process, _pid, _reason} ->
        reply(reply_to, {:error, :coordinator_restart})
    end
  end

  defp lease_wait(id, coordinator, coordinator_ref, processor, status, reply_to) do
    receive do
      :start ->
        lease = self()

        worker =
          spawn_link(fn ->
            send(lease, {:processor_result, self(), invoke(processor, status)})
          end)

        lease_running(id, coordinator, coordinator_ref, worker, reply_to)

      {:deliver, result} ->
        reply(reply_to, result)

      {:DOWN, ^coordinator_ref, :process, _pid, _reason} ->
        reply(reply_to, {:error, :coordinator_restart})
    end
  end

  defp lease_running(id, coordinator, coordinator_ref, worker, reply_to) do
    receive do
      {:processor_result, ^worker, result} ->
        send(coordinator, {:worker_result, id, self(), result})
        lease_deliver(coordinator_ref, reply_to)

      {:DOWN, ^coordinator_ref, :process, _pid, _reason} ->
        Process.exit(worker, :kill)
        reply(reply_to, {:error, :coordinator_restart})
    end
  end

  defp lease_deliver(coordinator_ref, reply_to) do
    receive do
      {:deliver, result} ->
        reply(reply_to, result)

      {:DOWN, ^coordinator_ref, :process, _pid, _reason} ->
        reply(reply_to, {:error, :coordinator_restart})
    end
  end

  defp invoke({module, function, extra_args}, status),
    do: apply(module, function, [status | extra_args])

  defp invoke(fun, status) when is_function(fun, 1), do: fun.(status)

  defp dispatch(state) when map_size(state.running) >= state.concurrency, do: state

  defp dispatch(state) do
    case pop_next_job(state) do
      {:empty, next_state} ->
        next_state

      {:ok, job, next_state} ->
        wait_ms = elapsed_ms(job.admitted_at)

        if wait_ms >= state.config[:queue_wait_ms] do
          send(job.lease, {:deliver, {:error, :admission_timeout}})

          emit(
            state.lane,
            :timeout,
            %{count: 1, acknowledgement_ms: wait_ms},
            %{reason: :admission_timeout}
          )

          emit_completion(state.lane, job, :admission_timeout)
          next_state |> remove_job(job) |> dispatch()
        else
          Process.cancel_timer(job.queue_timer)
          send(job.lease, :start)

          timer =
            Process.send_after(
              self(),
              {:execution_timeout, job.id},
              state.config[:worker_timeout_ms]
            )

          running_job =
            Map.merge(job, %{phase: :running, started_at: now_ms(), execution_timer: timer})

          dispatched = %{
            next_state
            | jobs: Map.put(next_state.jobs, job.id, running_job),
              running: Map.put(next_state.running, job.id, true)
          }

          emit(
            state.lane,
            :admission,
            %{wait_ms: wait_ms, payload_bytes: job.payload_bytes},
            %{}
          )

          emit_state(dispatched)
          dispatch(dispatched)
        end
    end
  end

  defp pop_next_job(state) do
    case :queue.out(state.queue) do
      {:empty, queue} ->
        {:empty, %{state | queue: queue}}

      {{:value, id}, queue} ->
        next_state = %{state | queue: queue}

        case Map.get(state.jobs, id) do
          %{phase: :queued} = job -> {:ok, job, next_state}
          _ -> pop_next_job(next_state)
        end
    end
  end

  defp remove_job(state, job) do
    if is_reference(job.queue_timer), do: Process.cancel_timer(job.queue_timer)
    if is_reference(Map.get(job, :execution_timer)), do: Process.cancel_timer(job.execution_timer)
    Process.demonitor(job.lease_ref, [:flush])
    if is_reference(job.caller_ref), do: Process.demonitor(job.caller_ref, [:flush])

    next_state = %{
      state
      | jobs: Map.delete(state.jobs, job.id),
        running: Map.delete(state.running, job.id),
        monitors:
          state.monitors
          |> Map.delete(job.lease_ref)
          |> Map.delete(job.caller_ref),
        admitted_bytes: state.admitted_bytes - job.retained_bytes,
        admitted_per_agent: decrement_agent(state.admitted_per_agent, job.agent_id)
    }

    emit_state(next_state)
    next_state
  end

  defp validate_capacity(state, retained_bytes, agent_id) do
    cond do
      map_size(state.jobs) >= state.config[:max_items] ->
        {:error, :count_full}

      state.admitted_bytes + retained_bytes > state.config[:max_bytes] ->
        {:error, :configured_byte_full}

      Map.get(state.admitted_per_agent, agent_id, 0) >= state.config[:max_items_per_agent] ->
        {:error, :per_agent_full}

      true ->
        :ok
    end
  end

  defp validate_source_size(bytes, maximum) when bytes > maximum,
    do: {:error, :wire_payload_too_large}

  defp validate_source_size(_bytes, _maximum), do: :ok

  defp validate_positive(config, keys) do
    case Enum.find(keys, fn key ->
           value = config[key]
           not (is_integer(value) and value > 0)
         end) do
      nil -> :ok
      key -> {:error, {:non_positive, key}}
    end
  end

  defp at_most(config, key, maximum) do
    if config[key] <= maximum, do: :ok, else: {:error, {:above_maximum, key, maximum}}
  end

  defp validate_deadline(config) do
    if config[:queue_wait_ms] + config[:worker_timeout_ms] + @deadline_reserve_ms <=
         config[:gateway_call_timeout_ms] do
      :ok
    else
      {:error, :deadline_budget_exceeded}
    end
  end

  defp payload_bytes(%{message: message}) when is_binary(message), do: byte_size(message)
  defp payload_bytes(_status), do: 0

  defp agent_id(status), do: status[:agent_id] || status["agent_id"] || "unknown"

  defp monitor_caller({pid, _tag}) when is_pid(pid), do: Process.monitor(pid)
  defp monitor_caller(_reply_to), do: nil

  defp maybe_put_monitor(monitors, nil, _value), do: monitors
  defp maybe_put_monitor(monitors, ref, value), do: Map.put(monitors, ref, value)

  defp decrement_agent(counts, agent_id) do
    case Map.get(counts, agent_id, 0) do
      count when count <= 1 -> Map.delete(counts, agent_id)
      count -> Map.put(counts, agent_id, count - 1)
    end
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _result}), do: :ok
  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result(other), do: {:error, {:unexpected_worker_result, other}}

  defp result_label(:ok), do: :committed
  defp result_label({:ok, _}), do: :committed
  defp result_label({:error, _}), do: :failed
  defp result_label(_), do: :unexpected

  defp execution_measurements(job, result, duration_ms) do
    measurements = %{
      count: 1,
      duration_ms: duration_ms,
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

  defp reply(nil, _result), do: :ok
  defp reply(reply_to, result), do: GenServer.reply(reply_to, result)

  defp emit_state(state) do
    pending_jobs = state.jobs |> Map.values() |> Enum.filter(&(&1.phase == :queued))
    pending_bytes = Enum.reduce(pending_jobs, 0, &(&1.retained_bytes + &2))

    emit(
      state.lane,
      :state,
      %{
        pending_count: length(pending_jobs),
        pending_bytes: pending_bytes,
        in_flight_count: map_size(state.running),
        in_flight_bytes: state.admitted_bytes - pending_bytes
      },
      %{}
    )
  end

  defp emit(lane, suffix, measurements, metadata) do
    :telemetry.execute(
      [:serviceradar, :admission_lane, suffix],
      measurements,
      Map.put(metadata, :lane, lane)
    )
  end

  defp emit_completion(lane, job, result) do
    emit(
      lane,
      :completion,
      %{
        count: 1,
        acknowledgement_ms: elapsed_ms(job.admitted_at),
        payload_bytes: job.payload_bytes
      },
      %{result: result}
    )
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp elapsed_ms(started_at), do: max(now_ms() - started_at, 0)

  defp bounded_reason(reason) when reason in [:normal, :shutdown, :killed, :noproc], do: reason
  defp bounded_reason(_reason), do: :unexpected
end
