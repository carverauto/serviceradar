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

  def admit_cast(server, status, lane) do
    GenServer.call(server, {:admit_cast, status}, :infinity)
  catch
    :exit, reason ->
      emit(
        lane,
        :rejected,
        %{count: 1, payload_bytes: payload_bytes(status)},
        %{reason: :lane_unavailable}
      )

      {:error, {:admission_lane_unavailable, reason}}
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
          lease_supervisor:
            Keyword.get(opts, :lease_supervisor, Keyword.fetch!(opts, :task_supervisor)),
          processor: Keyword.fetch!(opts, :processor),
          on_accepted_result: Keyword.get(opts, :on_accepted_result),
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
  def handle_call({:admit_cast, status}, _from, state) do
    case do_admit(status, nil, state) do
      {:ok, next_state} -> {:reply, :ok, dispatch(next_state)}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_info({:queue_timeout, id}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :queued} = job ->
        emit(
          state.lane,
          :timeout,
          %{count: 1, acknowledgement_ms: elapsed_ms(job.admitted_at)},
          %{reason: :admission_timeout}
        )

        emit_completion(state.lane, job, :admission_timeout)

        {:noreply, begin_delivery(state, job, {:error, :admission_timeout}, :none, nil, true)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:execution_timeout, id}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :running} = job ->
        {:noreply, begin_execution_termination(state, job, :execution_timeout)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:worker_result, id, worker, result}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :running, worker: ^worker} = job ->
        Process.cancel_timer(job.execution_timer)
        duration_ms = elapsed_ms(job.started_at)

        if duration_ms >= state.config[:worker_timeout_ms] do
          {:noreply, begin_execution_termination(state, job, :execution_timeout)}
        else
          {:noreply,
           begin_delivery(
             state,
             job,
             normalize_result(result),
             {:accepted, result},
             duration_ms,
             false
           )}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:lease_delivered, id, lease}, state) do
    case Map.get(state.jobs, id) do
      %{phase: :delivering, lease: ^lease, delivery_acknowledged: false} = job ->
        send(lease, {:delivery_recorded, id})
        {:noreply, finalize_delivery(state, job)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.monitors, ref) do
      {:lease, id} -> handle_lease_exit(state, id, ref, reason)
      {:caller, id} -> handle_caller_exit(state, id, ref)
      {:worker, id} -> handle_worker_exit(state, id, ref, reason)
      nil -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_lease_exit(state, id, ref, reason) do
    case Map.get(state.jobs, id) do
      nil ->
        {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}

      %{phase: :queued} = job ->
        reply(job.reply_to, {:error, :worker_crash})
        report_worker_crash(state, job, reason)
        {:noreply, state |> remove_job(job) |> dispatch()}

      %{phase: :running} = job ->
        Process.cancel_timer(job.execution_timer)
        reply(job.reply_to, {:error, :worker_crash})
        Process.exit(job.worker, :kill)
        report_worker_crash(state, job, reason)

        terminating =
          job
          |> Map.put(:phase, :terminating)
          |> Map.put(:reply_to, nil)

        {:noreply,
         state
         |> drop_monitor(ref)
         |> put_job(terminating)}

      %{phase: :delivering, delivery_acknowledged: false} = job ->
        reply(job.reply_to, job.delivery_result)
        {:noreply, state |> drop_monitor(ref) |> finalize_delivery(job)}

      %{phase: :delivering, delivery_acknowledged: true} ->
        {:noreply, drop_monitor(state, ref)}

      %{phase: :terminating} ->
        {:noreply, drop_monitor(state, ref)}
    end
  end

  defp handle_caller_exit(state, id, ref) do
    case Map.get(state.jobs, id) do
      nil ->
        {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}

      %{phase: :queued} = job ->
        Process.exit(job.lease, :kill)
        {:noreply, state |> remove_job(job) |> dispatch()}

      %{phase: phase} = job when phase in [:running, :delivering] ->
        if is_reference(Map.get(job, :execution_timer)) do
          Process.cancel_timer(job.execution_timer)
        end

        Process.exit(job.lease, :kill)

        if is_pid(Map.get(job, :worker)) and Process.alive?(job.worker) do
          Process.exit(job.worker, :kill)
        end

        terminating =
          job
          |> Map.put(:phase, :terminating)
          |> Map.put(:reply_to, nil)

        next_state = drop_monitor(state, ref)

        if Map.get(job, :worker_down, false) do
          {:noreply, next_state |> remove_job(terminating) |> dispatch()}
        else
          {:noreply, put_job(next_state, terminating)}
        end

      %{phase: :terminating} ->
        {:noreply, drop_monitor(state, ref)}
    end
  end

  defp handle_worker_exit(state, id, ref, reason) do
    case Map.get(state.jobs, id) do
      nil ->
        {:noreply, drop_monitor(state, ref)}

      %{phase: :terminating} = job ->
        {:noreply, state |> remove_job(job) |> dispatch()}

      %{phase: :running} = job ->
        report_worker_crash(state, job, reason)

        {:noreply,
         state
         |> drop_monitor(ref)
         |> begin_delivery(job, {:error, :worker_crash}, :none, nil, true)}

      %{phase: :delivering, delivery_acknowledged: true} = job ->
        {:noreply, state |> drop_monitor(ref) |> remove_job(job) |> dispatch()}

      %{phase: :delivering} = job ->
        worker_down = Map.put(job, :worker_down, true)
        {:noreply, state |> drop_monitor(ref) |> put_job(worker_down)}
    end
  end

  defp begin_delivery(state, job, delivery_result, accepted_result, duration_ms, worker_down) do
    delivering =
      Map.merge(job, %{
        phase: :delivering,
        delivery_result: delivery_result,
        accepted_result: accepted_result,
        delivery_duration_ms: duration_ms,
        delivery_acknowledged: false,
        worker_down: worker_down
      })

    send(job.lease, {:deliver, job.id, delivery_result})
    put_job(state, delivering)
  end

  defp finalize_delivery(state, job) do
    case job.accepted_result do
      {:accepted, result} ->
        notify_accepted_result(state.on_accepted_result, result)

        emit(
          state.lane,
          :execution,
          execution_measurements(job, result, job.delivery_duration_ms),
          %{result: result_label(result)}
        )

        emit_completion(state.lane, job, result_label(result))

      :none ->
        :ok
    end

    delivered =
      job
      |> Map.put(:delivery_acknowledged, true)
      |> Map.put(:reply_to, nil)

    if job.worker_down do
      state |> remove_job(delivered) |> dispatch()
    else
      put_job(state, delivered)
    end
  end

  defp begin_execution_termination(state, job, reason) do
    Process.cancel_timer(job.execution_timer)
    reply(job.reply_to, {:error, reason})
    Process.exit(job.lease, :kill)
    Process.exit(job.worker, :kill)

    emit(
      state.lane,
      :timeout,
      %{count: 1, acknowledgement_ms: elapsed_ms(job.admitted_at)},
      %{reason: reason}
    )

    emit_completion(state.lane, job, reason)

    terminating =
      job
      |> Map.put(:phase, :terminating)
      |> Map.put(:reply_to, nil)

    put_job(state, terminating)
  end

  defp report_worker_crash(state, job, reason) do
    emit(
      state.lane,
      :crash,
      %{count: 1, acknowledgement_ms: elapsed_ms(job.admitted_at)},
      %{reason: :worker_crash, exit_reason: bounded_reason(reason)}
    )

    emit_completion(state.lane, job, :worker_crash)
  end

  defp put_job(state, job), do: %{state | jobs: Map.put(state.jobs, job.id, job)}

  defp drop_monitor(state, ref), do: %{state | monitors: Map.delete(state.monitors, ref)}

  defp do_admit(status, reply_to, state) do
    payload_bytes = payload_bytes(status)
    retained_bytes = payload_bytes + @envelope_overhead_bytes
    agent_id = agent_id(status)

    with :ok <- validate_source_size(payload_bytes, state.source_max_bytes),
         :ok <- validate_capacity(state, retained_bytes, agent_id),
         {:ok, lease} <- start_lease(state, reply_to) do
      id = make_ref()
      lease_ref = Process.monitor(lease)
      caller_ref = monitor_caller(reply_to)
      admitted_at = now_ms()
      queue_timer = Process.send_after(self(), {:queue_timeout, id}, state.config[:queue_wait_ms])

      job = %{
        id: id,
        status: status,
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

  defp start_lease(state, reply_to) do
    coordinator = self()

    # The lightweight lease exists for queued as well as running work. It owns
    # the eventual GenServer.reply/2 and monitors the coordinator, so a lane
    # restart cannot strand a caller whose admission was already accepted.
    case Task.Supervisor.start_child(state.lease_supervisor, fn ->
           lease(coordinator, reply_to)
         end) do
      {:ok, pid} -> {:ok, pid}
      {:error, _reason} -> {:error, :worker_crash}
    end
  end

  defp lease(coordinator, reply_to) do
    coordinator_ref = Process.monitor(coordinator)

    receive do
      {:lease_id, id} ->
        lease_wait(id, coordinator, coordinator_ref, reply_to)

      {:DOWN, ^coordinator_ref, :process, _pid, _reason} ->
        reply(reply_to, {:error, :coordinator_restart})
    end
  end

  defp lease_wait(id, coordinator, coordinator_ref, reply_to) do
    receive do
      {:worker, ^id, worker} ->
        lease_running(id, coordinator, coordinator_ref, worker, reply_to)

      {:deliver, ^id, result} ->
        deliver_from_lease(id, coordinator, coordinator_ref, reply_to, result)

      {:DOWN, ^coordinator_ref, :process, _pid, _reason} ->
        reply(reply_to, {:error, :coordinator_restart})
    end
  end

  defp lease_running(id, coordinator, coordinator_ref, worker, reply_to) do
    receive do
      {:deliver, ^id, result} ->
        deliver_from_lease(id, coordinator, coordinator_ref, reply_to, result)

      {:DOWN, ^coordinator_ref, :process, _pid, _reason} ->
        Process.exit(worker, :kill)
        reply(reply_to, {:error, :coordinator_restart})
    end
  end

  defp deliver_from_lease(id, coordinator, coordinator_ref, reply_to, result) do
    reply(reply_to, result)
    send(coordinator, {:lease_delivered, id, self()})

    receive do
      {:delivery_recorded, ^id} ->
        :ok

      {:DOWN, ^coordinator_ref, :process, _pid, _reason} ->
        :ok
    end
  end

  defp invoke({module, function, extra_args}, status),
    do: apply(module, function, [status | extra_args])

  defp invoke(fun, status) when is_function(fun, 1), do: fun.(status)

  defp notify_accepted_result(nil, _result), do: :ok

  defp notify_accepted_result({module, function, extra_args}, {:ok, metadata}) do
    apply(module, function, [metadata | extra_args])
  end

  defp notify_accepted_result(_callback, _result), do: :ok

  defp dispatch(state) when map_size(state.running) >= state.concurrency, do: state

  defp dispatch(state) do
    case pop_next_job(state) do
      {:empty, next_state} ->
        next_state

      {:ok, job, next_state} ->
        wait_ms = elapsed_ms(job.admitted_at)

        if wait_ms >= state.config[:queue_wait_ms] do
          emit(
            state.lane,
            :timeout,
            %{count: 1, acknowledgement_ms: wait_ms},
            %{reason: :admission_timeout}
          )

          emit_completion(state.lane, job, :admission_timeout)

          begin_delivery(
            next_state,
            job,
            {:error, :admission_timeout},
            :none,
            nil,
            true
          )
        else
          Process.cancel_timer(job.queue_timer)

          case start_worker(next_state, job) do
            {:ok, worker, worker_ref} ->
              timer =
                Process.send_after(
                  self(),
                  {:execution_timeout, job.id},
                  state.config[:worker_timeout_ms]
                )

              running_job =
                Map.merge(job, %{
                  phase: :running,
                  started_at: now_ms(),
                  execution_timer: timer,
                  worker: worker,
                  worker_ref: worker_ref
                })

              dispatched = %{
                next_state
                | jobs: Map.put(next_state.jobs, job.id, running_job),
                  monitors: Map.put(next_state.monitors, worker_ref, {:worker, job.id}),
                  running: Map.put(next_state.running, job.id, true)
              }

              # The worker must not invoke persistence until its monitor and
              # running job are installed. Otherwise a fast worker can exit
              # before the lane is ready to correlate its result and DOWN.
              send(job.lease, {:worker, job.id, worker})
              send(worker, {:start, job.id})

              emit(
                state.lane,
                :admission,
                %{wait_ms: wait_ms, payload_bytes: job.payload_bytes},
                %{}
              )

              emit_state(dispatched)
              dispatch(dispatched)

            {:error, reason} ->
              report_worker_crash(state, job, reason)

              begin_delivery(
                next_state,
                job,
                {:error, :worker_crash},
                :none,
                nil,
                true
              )
          end
        end
    end
  end

  defp start_worker(state, job) do
    coordinator = self()
    processor = state.processor

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           receive do
             {:start, id} when id == job.id ->
               result = invoke(processor, job.status)
               send(coordinator, {:worker_result, job.id, self(), result})
           end
         end) do
      {:ok, worker} -> {:ok, worker, Process.monitor(worker)}
      {:error, reason} -> {:error, reason}
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
    if is_reference(Map.get(job, :worker_ref)), do: Process.demonitor(job.worker_ref, [:flush])

    next_state = %{
      state
      | queue: :queue.delete(job.id, state.queue),
        jobs: Map.delete(state.jobs, job.id),
        running: Map.delete(state.running, job.id),
        monitors:
          state.monitors
          |> Map.delete(job.lease_ref)
          |> Map.delete(job.caller_ref)
          |> Map.delete(Map.get(job, :worker_ref)),
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
