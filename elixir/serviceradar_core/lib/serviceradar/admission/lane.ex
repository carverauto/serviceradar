defmodule ServiceRadar.Admission.Lane do
  @moduledoc false

  use GenServer

  @envelope_overhead_bytes 256
  @max_queue_wait_ms 2_000
  @max_worker_timeout_ms 20_000
  @deadline_reserve_ms 3_000
  @max_descriptor_bytes 4_096

  # Called in the producer, before transferring the payload to any coordinator.
  # Include headers in the retained-byte charge; a message-only charge permits
  # arbitrarily large capability/metadata maps to escape the byte bound.
  def descriptor(status, remaining_ms) do
    %{
      headers:
        Map.take(status, [
          :source,
          :service_type,
          :service_name,
          :agent_id,
          :partition,
          :delivery_capabilities,
          :sweep_group_id
        ]),
      payload_bytes: payload_bytes(status),
      retained_bytes: :erlang.external_size(status) + @envelope_overhead_bytes,
      remaining_ms: remaining_ms
    }
  end

  def reserve(server, descriptor, owner, timeout) do
    with :ok <- validate_descriptor(descriptor),
         {:ok, target} <- reservation_target(server) do
      GenServer.call(target, {:reserve, descriptor, owner}, timeout)
    end
  catch
    :exit, reason -> {:error, {:admission_lane_unavailable, reason}}
  end

  def submit(server, id, status, reply_to) do
    GenServer.call(server, {:submit, id, status, {:reply_to, reply_to}}, :infinity)
  catch
    :exit, reason -> {:error, {:admission_lane_unavailable, reason}}
  end

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

  defp reservation_target({:via, Registry, {registry, key}}) do
    case Registry.lookup(registry, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, {:admission_lane_unavailable, :noproc}}
    end
  rescue
    ArgumentError -> {:error, {:admission_lane_unavailable, :noproc}}
  end

  defp reservation_target(server), do: {:ok, server}

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
          preserve_result: Keyword.get(opts, :preserve_result, false),
          execution_gate: Keyword.get(opts, :execution_gate),
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
  def handle_call({:reserve, descriptor, owner}, _from, state) do
    case do_reserve(descriptor, owner, state) do
      {:ok, id, next_state} -> {:reply, {:ok, {self(), id}}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit, id, status, mode}, from, state)
      when mode in [:wait, :best_effort] or
             (is_tuple(mode) and tuple_size(mode) == 2 and elem(mode, 0) == :reply_to) do
    reply_to =
      case mode do
        :wait -> from
        :best_effort -> nil
        {:reply_to, target} -> target
      end

    case attach_payload(state, id, status, reply_to) do
      {:ok, next_state} when mode == :wait -> {:noreply, dispatch(next_state)}
      {:ok, next_state} -> {:reply, :ok, dispatch(next_state)}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:submit, _id, _status, _mode}, _from, state),
    do: {:reply, {:error, :invalid_admission_mode}, state}

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
      %{phase: :reserved} = job ->
        emit_completion(state.lane, job, :admission_timeout)
        {:noreply, state |> remove_job(job) |> dispatch()}

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

        if duration_ms >= job.worker_budget_ms do
          {:noreply, begin_execution_termination(state, job, :execution_timeout)}
        else
          {:noreply,
           begin_delivery(
             state,
             job,
             normalize_result(result, state.preserve_result),
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

      %{phase: :reserved} = job ->
        {:noreply, state |> remove_job(job) |> dispatch()}

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

  defp do_reserve(descriptor, owner, state) do
    with :ok <- validate_descriptor(descriptor),
         %{
           headers: headers,
           payload_bytes: bytes,
           retained_bytes: retained,
           remaining_ms: remaining
         } <- descriptor,
         :ok <- validate_source_size(bytes, state.source_max_bytes),
         :ok <- validate_capacity(state, retained, agent_id(headers)),
         true <- remaining > @deadline_reserve_ms do
      id = make_ref()
      admitted_at = now_ms()
      caller_ref = if is_pid(owner), do: Process.monitor(owner)
      queue_ms = min(state.config[:queue_wait_ms], remaining - @deadline_reserve_ms)

      job = %{
        id: id,
        phase: :reserved,
        status: nil,
        headers: headers,
        reply_to: nil,
        lease: nil,
        lease_ref: nil,
        caller_ref: caller_ref,
        agent_id: agent_id(headers),
        ordering_key: ordering_key(headers),
        payload_bytes: bytes,
        retained_bytes: retained,
        admitted_at: admitted_at,
        deadline: admitted_at + min(remaining, state.config[:gateway_call_timeout_ms]),
        queue_timer: Process.send_after(self(), {:queue_timeout, id}, queue_ms)
      }

      next_state = %{
        state
        | queue: :queue.in(id, state.queue),
          jobs: Map.put(state.jobs, id, job),
          monitors: maybe_put_monitor(state.monitors, caller_ref, {:caller, id}),
          admitted_bytes: state.admitted_bytes + retained,
          admitted_per_agent: Map.update(state.admitted_per_agent, job.agent_id, 1, &(&1 + 1))
      }

      emit(state.lane, :admitted, %{count: 1}, %{})
      emit_state(next_state)
      {:ok, id, next_state}
    else
      false ->
        emit(state.lane, :rejected, %{count: 1}, %{reason: :admission_timeout})
        {:error, :admission_timeout}

      {:error, reason} = error ->
        emit(state.lane, :rejected, %{count: 1}, %{reason: reason})
        error
    end
  end

  defp validate_descriptor(descriptor) when is_map(descriptor) do
    case descriptor do
      %{headers: headers, payload_bytes: bytes, retained_bytes: retained, remaining_ms: remaining}
      when is_map(headers) and is_integer(bytes) and bytes >= 0 and
             is_integer(retained) and retained >= bytes + @envelope_overhead_bytes and
             is_integer(remaining) and remaining > 0 ->
        if :erlang.external_size(descriptor) <= @max_descriptor_bytes,
          do: :ok,
          else: {:error, :invalid_admission_descriptor}

      _ ->
        {:error, :invalid_admission_descriptor}
    end
  end

  defp validate_descriptor(_), do: {:error, :invalid_admission_descriptor}

  defp attach_payload(state, id, status, reply_to) do
    case Map.get(state.jobs, id) do
      %{phase: :reserved} = job ->
        actual = descriptor(status, 1)

        cond do
          now_ms() >= job.deadline - @deadline_reserve_ms ->
            {:error, :admission_timeout, remove_job(state, job)}

          actual.headers != job.headers or actual.retained_bytes != job.retained_bytes ->
            {:error, :reservation_payload_mismatch, remove_job(state, job)}

          true ->
            case start_lease(state, reply_to) do
              {:ok, lease} ->
                lease_ref = Process.monitor(lease)
                if is_reference(job.caller_ref), do: Process.demonitor(job.caller_ref, [:flush])
                caller_ref = monitor_caller(reply_to)

                attached = %{
                  job
                  | status: Map.put(status, :ingestion_best_effort, is_nil(reply_to)),
                    phase: :queued,
                    reply_to: reply_to,
                    lease: lease,
                    lease_ref: lease_ref,
                    caller_ref: caller_ref
                }

                send(lease, {:lease_id, id})
                next_state = state |> drop_monitor(job.caller_ref) |> put_job(attached)

                {:ok,
                 %{
                   next_state
                   | monitors:
                       next_state.monitors
                       |> Map.put(lease_ref, {:lease, id})
                       |> maybe_put_monitor(caller_ref, {:caller, id})
                 }}

              {:error, reason} ->
                {:error, reason, remove_job(state, job)}
            end
        end

      _ ->
        {:error, :reservation_expired, state}
    end
  end

  defp do_admit(status, reply_to, state) do
    payload_bytes = payload_bytes(status)
    retained_bytes = :erlang.external_size(status) + @envelope_overhead_bytes
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
        ordering_key: ordering_key(status),
        payload_bytes: payload_bytes,
        retained_bytes: retained_bytes,
        admitted_at: admitted_at,
        deadline: admitted_at + state.config[:gateway_call_timeout_ms],
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

        if wait_ms >= state.config[:queue_wait_ms] or
             job.deadline - now_ms() <= @deadline_reserve_ms do
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

          worker_budget_ms =
            min(
              state.config[:worker_timeout_ms],
              job.deadline - now_ms() - @deadline_reserve_ms
            )

          job = Map.put(job, :worker_budget_ms, max(worker_budget_ms, 1))

          case start_worker(next_state, job) do
            {:ok, worker, worker_ref} ->
              timer =
                Process.send_after(
                  self(),
                  {:execution_timeout, job.id},
                  job.worker_budget_ms
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
    execution_gate = state.execution_gate
    lane = state.lane

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           receive do
             {:start, id} when id == job.id ->
               result =
                 if execution_gate do
                   ServiceRadar.Ingestion.WorkerBudget.run(execution_gate, lane, fn ->
                     invoke(processor, job.status)
                   end)
                 else
                   invoke(processor, job.status)
                 end

               send(coordinator, {:worker_result, job.id, self(), result})
           end
         end) do
      {:ok, worker} -> {:ok, worker, Process.monitor(worker)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pop_next_job(state), do: pop_next_job(state, :queue.len(state.queue), MapSet.new())

  defp pop_next_job(state, 0, _blocked), do: {:empty, state}

  defp pop_next_job(state, remaining, blocked) do
    case :queue.out(state.queue) do
      {:empty, queue} ->
        {:empty, %{state | queue: queue}}

      {{:value, id}, queue} ->
        next_state = %{state | queue: queue}

        case Map.get(state.jobs, id) do
          %{phase: phase} = job when phase in [:queued, :reserved] ->
            busy? =
              Enum.any?(state.running, fn {running_id, _} ->
                state.jobs[running_id].ordering_key == job.ordering_key
              end)

            if phase == :reserved or busy? or MapSet.member?(blocked, job.ordering_key) do
              rotated = %{next_state | queue: :queue.in(id, queue)}
              pop_next_job(rotated, remaining - 1, MapSet.put(blocked, job.ordering_key))
            else
              {:ok, job, next_state}
            end

          _ ->
            pop_next_job(next_state, remaining - 1, blocked)
        end
    end
  end

  defp remove_job(state, job) do
    if is_reference(job.queue_timer), do: Process.cancel_timer(job.queue_timer)
    if is_reference(Map.get(job, :execution_timer)), do: Process.cancel_timer(job.execution_timer)
    if is_reference(job.lease_ref), do: Process.demonitor(job.lease_ref, [:flush])
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
    key_bytes =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.agent_id == agent_id))
      |> Enum.reduce(0, &(&1.retained_bytes + &2))

    cond do
      map_size(state.jobs) >= state.config[:max_items] ->
        {:error, :count_full}

      state.admitted_bytes + retained_bytes > state.config[:max_bytes] ->
        {:error, :configured_byte_full}

      key_bytes + retained_bytes >
          (state.config[:max_bytes_per_agent] || state.config[:max_bytes]) ->
        {:error, :per_agent_byte_full}

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

  defp ordering_key(%{source: source, service_type: type, sweep_group_id: group} = status)
       when source in ["results", :results] and type in ["sweep", :sweep],
       do: {agent_id(status), group}

  defp ordering_key(status), do: agent_id(status)

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

  defp normalize_result({:ok, _result} = result, true), do: result
  defp normalize_result(:ok, _), do: :ok
  defp normalize_result({:ok, _result}, _), do: :ok
  defp normalize_result({:error, _reason} = error, _), do: error
  defp normalize_result(other, _), do: {:error, {:unexpected_worker_result, other}}

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
    pending_jobs = state.jobs |> Map.values() |> Enum.filter(&(&1.phase in [:reserved, :queued]))
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
    runtime_measurements =
      case measurements do
        %{wait_ms: wait} -> Map.put(measurements, :queue_wait_ms, wait)
        measurements -> measurements
      end

    runtime_measurements =
      if suffix == :completion do
        accepted = metadata[:result] == :ok or match?({:ok, _}, metadata[:result])
        Map.put(runtime_measurements, :outcome, if(accepted, do: :accepted, else: :not_accepted))
      else
        runtime_measurements
      end

    ServiceRadar.Ingestion.RuntimeMetrics.record(
      lane,
      suffix,
      Map.put(runtime_measurements, :reason, metadata[:reason])
    )

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
