defmodule ServiceRadarAgentGateway.StatusBuffer do
  @moduledoc """
  Buffers status payloads when their downstream consumer is unavailable.

  This is an in-memory, bounded queue intended to reduce data loss
  during short core outages. It is not durable across restarts.

  Statuses are delivered one at a time by a monitored process, never inside
  this server. A core call can take up to the reservation deadline (or the
  whole core call timeout), while `enqueue/1` callers on the PushStatus path
  wait at most one second; delivering inline made every enqueue that arrived
  during one slow core call time out and count as a drop. The buffer holds at
  most `max_entries` queued statuses plus the one being delivered.
  """

  use GenServer

  alias ServiceRadarAgentGateway.StatusProcessor

  require Logger

  @default_max_entries 100
  @default_flush_interval_ms 5_000

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

  @doc """
  Asks the buffer to forward queued statuses now.

  Best-effort PushStatus enqueues and returns before core accepts. The
  periodic flush still runs. This wakes it so a recovered core is not
  waiting on the interval.
  """
  @spec request_flush() :: :ok
  def request_flush do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        send(pid, :request_flush)
        :ok

      _missing ->
        :ok
    end
  end

  @impl true
  def init(opts) do
    max_entries = Keyword.get(opts, :max_entries, env_int("GATEWAY_RESULTS_BUFFER_LIMIT", @default_max_entries))

    flush_interval_ms =
      Keyword.get(opts, :flush_interval_ms, env_int("GATEWAY_RESULTS_BUFFER_FLUSH_MS", @default_flush_interval_ms))

    schedule_flush(flush_interval_ms)
    emit_buffer_depth(0, 0)

    {:ok,
     %{
       queue: :queue.new(),
       retained_bytes: 0,
       max_entries: max_entries,
       flush_interval_ms: flush_interval_ms,
       delivery: nil
     }}
  end

  @impl true
  def handle_call({:enqueue, status}, _from, state) do
    if state.max_entries <= 0 do
      Logger.warning("Status buffer disabled; dropping status")
      emit_buffer_drop(status, :disabled)
      {:reply, :ok, state}
    else
      status_bytes = encoded_status_bytes(status)
      {queue, dropped} = enqueue_status(state.queue, status, state.max_entries)

      retained_bytes =
        state.retained_bytes + status_bytes -
          case dropped do
            nil -> 0
            dropped_status -> encoded_status_bytes(dropped_status)
          end

      if dropped do
        Logger.warning("Status buffer full; dropping oldest status")
        emit_buffer_drop(dropped, :overflow)
      end

      state = %{state | queue: queue, retained_bytes: retained_bytes}
      emit_buffer_depth(depth(state), retained_bytes)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:size, _from, state) do
    {:reply, depth(state), state}
  end

  @impl true
  def handle_info(:flush, state) do
    schedule_flush(state.flush_interval_ms)
    {:noreply, start_delivery(state)}
  end

  @impl true
  def handle_info(:request_flush, state) do
    {:noreply, start_delivery(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{delivery: %{ref: ref} = delivery} = state) do
    state = %{state | delivery: nil}

    case delivery_result(reason) do
      :ok ->
        retained_bytes = state.retained_bytes - encoded_status_bytes(delivery.status)
        state = %{state | retained_bytes: retained_bytes}
        emit_buffer_depth(depth(state), retained_bytes)
        {:noreply, start_delivery(state)}

      {:error, error} ->
        # Pause until the next flush tick or request: retrying at once would
        # repeat the call into a core that just failed to answer it. A request
        # that arrived during the failed delivery is honored now.
        Logger.debug("Results buffer flush paused: #{inspect(error)}")
        state = requeue_oldest(state, delivery.status)
        {:noreply, if(delivery.requested_again?, do: start_delivery(state), else: state)}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue_status(queue, status, max_entries) do
    if :queue.len(queue) >= max_entries do
      {{:value, dropped}, reduced} = :queue.out(queue)
      {:queue.in(status, reduced), dropped}
    else
      {:queue.in(status, queue), nil}
    end
  end

  defp start_delivery(%{delivery: %{} = delivery} = state), do: %{state | delivery: %{delivery | requested_again?: true}}

  defp start_delivery(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, status}, rest} ->
        # The result travels in the exit reason, so the one :DOWN message also
        # covers a delivery that crashed without returning.
        {_pid, ref} =
          spawn_monitor(fn ->
            exit({:delivery_result, StatusProcessor.process(status, buffer_on_failure: false, from_buffer: true)})
          end)

        %{state | queue: rest, delivery: %{ref: ref, status: status, requested_again?: false}}
    end
  end

  defp delivery_result({:delivery_result, :ok}), do: :ok
  defp delivery_result({:delivery_result, {:ok, _result}}), do: :ok
  defp delivery_result({:delivery_result, {:error, reason}}), do: {:error, reason}
  defp delivery_result(reason), do: {:error, {:delivery_exited, reason}}

  # The failed status is the oldest one owned. If statuses enqueued during its
  # delivery filled the queue, it is the one overflow evicts.
  defp requeue_oldest(state, status) do
    if :queue.len(state.queue) >= state.max_entries do
      Logger.warning("Status buffer full; dropping oldest status")
      emit_buffer_drop(status, :overflow)
      retained_bytes = state.retained_bytes - encoded_status_bytes(status)
      emit_buffer_depth(depth(state), retained_bytes)
      %{state | retained_bytes: retained_bytes}
    else
      %{state | queue: :queue.in_r(status, state.queue)}
    end
  end

  defp depth(%{queue: queue, delivery: nil}), do: :queue.len(queue)
  defp depth(%{queue: queue}), do: :queue.len(queue) + 1

  defp schedule_flush(flush_interval_ms) do
    Process.send_after(self(), :flush, max(flush_interval_ms, 1_000))
  end

  defp emit_buffer_drop(status, reason) do
    :telemetry.execute(
      [:serviceradar, :agent_gateway, :results, :buffer, :dropped],
      %{count: 1, bytes: encoded_status_bytes(status)},
      buffer_metadata(status, reason)
    )
  end

  defp emit_buffer_depth(depth, retained_bytes) do
    :telemetry.execute(
      [:serviceradar, :agent_gateway, :results, :buffer, :depth],
      %{depth: depth, bytes: retained_bytes},
      %{gateway_id: ServiceRadarAgentGateway.Config.gateway_id()}
    )

    ServiceRadarAgentGateway.RuntimeMetrics.report_buffer_depth(depth)
  end

  defp buffer_metadata(status, reason) do
    %{
      reason: bounded_reason(reason),
      gateway_id: status[:gateway_id] || ServiceRadarAgentGateway.Config.gateway_id(),
      partition: status[:partition] || "default",
      source: bounded_source(status[:source]),
      service_type: bounded_service_type(status[:service_type])
    }
  end

  defp encoded_status_bytes(status), do: :erlang.external_size(status)

  defp bounded_source(source)
       when source in [
              "status",
              :status,
              "results",
              :results,
              "plugin-result",
              :plugin_result,
              "sysmon-metrics",
              :sysmon_metrics,
              "snmp-metrics",
              :snmp_metrics,
              "icmp-metrics",
              :icmp_metrics,
              "rperf-metrics",
              :rperf_metrics,
              "mtr-metrics",
              :mtr_metrics,
              "sweep-metrics",
              :sweep_metrics,
              "workload-identity",
              :workload_identity
            ], do: source |> to_string() |> String.replace("_", "-")

  defp bounded_source("addon:" <> _addon_id), do: "addon"
  defp bounded_source("plugin:" <> _plugin_id), do: "plugin"
  defp bounded_source(_source), do: "other"

  defp bounded_service_type(service_type)
       when service_type in [
              "agent",
              :agent,
              "check",
              :check,
              "inventory",
              :inventory,
              "metrics",
              :metrics,
              "native-addon",
              :native_addon,
              "plugin",
              :plugin,
              "process",
              :process,
              "status",
              :status,
              "sync",
              :sync
            ], do: service_type |> to_string() |> String.replace("_", "-")

  defp bounded_service_type(_service_type), do: "other"

  defp bounded_reason(reason) when reason in [:disabled, :overflow, :unavailable], do: reason
  defp bounded_reason(_reason), do: :other

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
