defmodule ServiceRadar.ResultsRouter do
  @moduledoc "Routes ingestion to bounded workers and batches completed service-state writes."
  use GenServer

  alias ServiceRadar.Admission.Lane
  alias ServiceRadar.Ingestion.Admission
  alias ServiceRadar.Ingestion.ResultIngestor
  alias ServiceRadar.Ingestion.RuntimeMetrics
  alias ServiceRadar.Ingestion.WorkerBudget
  alias ServiceRadar.Observability.ServiceStateRegistry
  alias ServiceRadar.Observability.ServiceStateRegistry.StatusNormalizer
  alias ServiceRadar.Observability.ServiceStatusPubSub

  require Logger

  @max_bytes 32 * 1_024 * 1_024
  @max_items 200
  @reservation_ms 2_000
  @worker_ms 10_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  defdelegate process_retained_plugin(status), to: ResultIngestor
  defdelegate census_service_types(), to: ResultIngestor
  defdelegate mdns_service_types(), to: ResultIngestor
  defdelegate passive_netprobe_service_types(), to: ResultIngestor

  def publish_completed(status) do
    descriptor =
      Map.put(
        Lane.descriptor(status, 15_000),
        :observation,
        StatusNormalizer.pending_observation(status)
      )

    with {:ok, id} <- GenServer.call(__MODULE__, {:reserve_publish, descriptor}, 1_000) do
      GenServer.call(__MODULE__, {:publish_completed, id, status}, 1_000)
    end
  catch
    :exit, reason -> {:error, {:service_state_queue_unavailable, reason}}
  end

  @impl true
  def init(_opts) do
    if !(is_integer(max_items()) and max_items() > 0 and is_integer(max_bytes()) and
           max_bytes() > 0 and
           is_integer(flush_interval_ms()) and flush_interval_ms() > 0) do
      raise ArgumentError, "invalid service-state queue limits"
    end

    {:ok, %{buffer: :queue.new(), reservations: %{}, bytes: 0, timer: nil, active: nil}}
  end

  @impl true
  def handle_call({:results_update, status}, from, state) do
    handoff_reply(Admission.admit(status, from), state)
  end

  def handle_call({:results_update_async_reply, status, reply_to}, _from, state) do
    {:reply, Admission.admit(status, reply_to), state}
  end

  def handle_call(
        {:reserve_publish, %{headers: headers, retained_bytes: bytes} = descriptor},
        {owner, _},
        state
      )
      when is_map(headers) and is_integer(bytes) and bytes > 0 do
    if :erlang.external_size(descriptor) > 4_096 or
         map_size(state.reservations) >= max_items() or state.bytes + bytes > max_bytes() do
      RuntimeMetrics.record(:service_state, :rejected, %{reason: :service_state_queue_full})
      {:reply, {:error, :service_state_queue_full}, state}
    else
      id = make_ref()
      timer = Process.send_after(self(), {:publish_reservation_expired, id}, @reservation_ms)

      reservation = %{
        headers: headers,
        bytes: bytes,
        monitor: Process.monitor(owner),
        timer: timer,
        phase: :reserved,
        observation: validated_observation(descriptor[:observation])
      }

      RuntimeMetrics.record(:service_state, :admitted, %{})

      {:reply, {:ok, id},
       record_state(%{
         state
         | reservations: Map.put(state.reservations, id, reservation),
           bytes: state.bytes + bytes
       })}
    end
  end

  def handle_call({:reserve_publish, _descriptor}, _from, state) do
    {:reply, {:error, :invalid_admission_descriptor}, state}
  end

  def handle_call({:publish_completed, id, status}, _from, state) do
    descriptor = Lane.descriptor(status, 1)

    case state.reservations[id] do
      %{phase: :reserved, headers: headers, bytes: bytes} = reservation
      when headers == descriptor.headers and bytes == descriptor.retained_bytes ->
        Process.cancel_timer(reservation.timer)
        Process.demonitor(reservation.monitor, [:flush])
        reservation = %{reservation | phase: :pending, monitor: nil, timer: nil}
        state = %{state | reservations: Map.put(state.reservations, id, reservation)}
        state = coalesce_pending(state, id, status, reservation.observation)
        {:reply, :ok, maybe_flush(state)}

      _ ->
        {:reply, {:error, :service_state_reservation_expired}, state}
    end
  end

  @impl true
  def handle_cast({:results_update, status}, state) do
    _ = Admission.admit(status, nil)
    {:noreply, state}
  end

  @impl true
  def handle_info({:flush_results, token}, %{timer: {_ref, token}} = state) do
    {:noreply, flush(%{state | timer: nil})}
  end

  def handle_info({:flush_results, _stale}, state), do: {:noreply, state}
  def handle_info(:flush_results, state), do: {:noreply, state}

  def handle_info({:publish_reservation_expired, id}, state) do
    case state.reservations[id] do
      %{phase: :reserved} -> {:noreply, release(state, [id])}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:service_batch_result, pid, result}, %{active: %{pid: pid} = active} = state) do
    {:noreply, %{state | active: Map.put(active, :result, result)}}
  end

  def handle_info({:service_batch_timeout, pid}, %{active: %{pid: pid}} = state) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:service_batch_timeout, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active: %{ref: ref} = active} = state) do
    Process.cancel_timer(active.timer)
    state = %{state | active: nil}

    if reason == :normal and active.result == :ok do
      ids = Enum.map(active.items, &elem(&1, 0))
      {:noreply, state |> release(ids) |> maybe_flush()}
    else
      Logger.warning("Service-state batch failed; retaining bounded batch for retry",
        reason: inspect(reason),
        result: inspect(active.result)
      )

      buffer = :queue.join(:queue.from_list(active.items), state.buffer)
      {:noreply, arm(%{state | buffer: buffer})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    ids = for {id, %{monitor: monitor}} <- state.reservations, monitor == ref, do: id
    {:noreply, release(state, ids)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Only completed current-state projections may coalesce; type ingestion and
  # retained markers have already run and never enter this buffer.
  defp coalesce_pending(state, id, status, nil),
    do: %{state | buffer: :queue.in({id, status}, state.buffer)}

  defp coalesce_pending(state, id, status, {key, observed_at}) do
    existing =
      Enum.find(:queue.to_list(state.buffer), fn {old_id, _status} ->
        case state.reservations[old_id].observation do
          {^key, _} -> true
          _ -> false
        end
      end)

    case existing do
      nil ->
        %{state | buffer: :queue.in({id, status}, state.buffer)}

      {old_id, _old_status} ->
        {_key, old_observed_at} = state.reservations[old_id].observation

        if DateTime.before?(observed_at, old_observed_at) do
          release(state, [id])
        else
          buffer =
            state.buffer
            |> :queue.to_list()
            |> Enum.map(fn
              {^old_id, _} -> {id, status}
              item -> item
            end)
            |> :queue.from_list()

          release(%{state | buffer: buffer}, [old_id])
        end
    end
  end

  defp handoff_reply(:ok, state), do: {:noreply, state}
  defp handoff_reply({:error, _} = error, state), do: {:reply, error, state}

  defp maybe_flush(state) do
    if :queue.len(state.buffer) >= max_items(),
      do: flush(invalidate_timer(state)),
      else: arm(state)
  end

  defp flush(%{active: active} = state) when not is_nil(active), do: arm(state)

  defp flush(state) do
    if :queue.is_empty(state.buffer) do
      state
    else
      items = :queue.to_list(state.buffer)
      owner = self()

      fun = fn ->
        result =
          WorkerBudget.run(WorkerBudget, :service_state, fn ->
            statuses = Enum.map(items, &elem(&1, 1))

            with :ok <- ServiceStateRegistry.bulk_upsert_from_statuses_strict(statuses) do
              ServiceStatusPubSub.broadcast_batch(statuses)
            end
          end)

        send(owner, {:service_batch_result, self(), result})
      end

      case Task.Supervisor.start_child(ServiceRadar.Ingestion.ServiceStateTaskSupervisor, fun) do
        {:ok, pid} ->
          timer = Process.send_after(self(), {:service_batch_timeout, pid}, @worker_ms)

          record_state(%{
            state
            | buffer: :queue.new(),
              active: %{
                pid: pid,
                ref: Process.monitor(pid),
                timer: timer,
                items: items,
                result: nil
              }
          })

        {:error, _} ->
          arm(state)
      end
    end
  catch
    :exit, _ -> arm(state)
  end

  defp arm(%{timer: timer} = state) when not is_nil(timer), do: state

  defp arm(state) do
    if :queue.is_empty(state.buffer) do
      state
    else
      token = make_ref()
      ms = flush_interval_ms()
      %{state | timer: {Process.send_after(self(), {:flush_results, token}, ms), token}}
    end
  end

  defp invalidate_timer(%{timer: {ref, _}} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp invalidate_timer(state), do: state

  defp release(state, ids) do
    ids
    |> Enum.reduce(state, fn id, acc ->
      case Map.pop(acc.reservations, id) do
        {nil, _} ->
          acc

        {reservation, rest} ->
          if is_reference(reservation.monitor),
            do: Process.demonitor(reservation.monitor, [:flush])

          if is_reference(reservation.timer), do: Process.cancel_timer(reservation.timer)
          %{acc | reservations: rest, bytes: acc.bytes - reservation.bytes}
      end
    end)
    |> record_state()
  end

  defp record_state(state) do
    active_ids = if state.active, do: Enum.map(state.active.items, &elem(&1, 0)), else: []

    active_bytes =
      Enum.reduce(active_ids, 0, fn id, acc ->
        acc + (state.reservations[id] || %{bytes: 0}).bytes
      end)

    RuntimeMetrics.record(:service_state, :state, %{
      pending_count: map_size(state.reservations) - length(active_ids),
      pending_bytes: state.bytes - active_bytes,
      in_flight_count: length(active_ids),
      in_flight_bytes: active_bytes
    })

    state
  end

  defp validated_observation({key, %DateTime{} = observed_at})
       when is_tuple(key) and tuple_size(key) == 5 do
    if key |> Tuple.to_list() |> Enum.all?(&(is_binary(&1) and &1 != "")),
      do: {key, observed_at}
  end

  defp validated_observation(_), do: nil

  defp flush_interval_ms,
    do: Application.get_env(:serviceradar_core, :results_router_flush_interval_ms, 250)

  defp max_bytes,
    do: Application.get_env(:serviceradar_core, :results_router_max_bytes, @max_bytes)

  defp max_items,
    do: Application.get_env(:serviceradar_core, :results_router_max_buffer, @max_items)
end
