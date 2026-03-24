defmodule ServiceRadarCoreElx.CameraRelay.AnalysisHTTPDispatchWorker do
  @moduledoc """
  Per-branch worker that receives analysis input envelopes and dispatches them
  to an external HTTP worker with bounded in-flight concurrency.
  """

  use GenServer

  alias ServiceRadar.Camera.AnalysisResultIngestor
  alias ServiceRadar.Telemetry
  alias ServiceRadarCoreElx.CameraRelay.AnalysisBranchManager
  alias ServiceRadarCoreElx.CameraRelay.AnalysisHTTPAdapter
  alias ServiceRadarCoreElx.CameraRelay.AnalysisWorkerResolver

  @default_max_in_flight 1
  @default_timeout_ms 2_000
  @default_max_failovers 1

  def child_spec(opts) do
    %{
      id: {__MODULE__, {Map.get(opts, :relay_session_id), Map.get(opts, :branch_id)}},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def close(pid) when is_pid(pid) do
    GenServer.call(pid, :close)
  end

  @impl true
  def init(opts) do
    relay_session_id = required_string!(opts, :relay_session_id)
    branch_id = required_string!(opts, :branch_id)

    worker = %{
      worker_id: required_string!(opts, :worker_id),
      endpoint_url: required_string!(opts, :endpoint_url),
      headers: Map.get(opts, :headers, %{}),
      timeout_ms: positive_integer(Map.get(opts, :timeout_ms), @default_timeout_ms),
      max_in_flight: positive_integer(Map.get(opts, :max_in_flight), @default_max_in_flight),
      selection_mode: Map.get(opts, :selection_mode, "direct"),
      requested_capability: Map.get(opts, :requested_capability),
      registry_managed?: Map.get(opts, :registry_managed?, false)
    }

    state = %{
      relay_session_id: relay_session_id,
      branch_id: branch_id,
      worker: worker,
      policy: Map.get(opts, :policy, %{}),
      adapter: Map.get(opts, :adapter, AnalysisHTTPAdapter),
      adapter_opts: Map.get(opts, :adapter_opts, []),
      result_ingestor: Map.get(opts, :result_ingestor, AnalysisResultIngestor),
      telemetry_module: Map.get(opts, :telemetry_module, Telemetry),
      worker_resolver: Map.get(opts, :worker_resolver, AnalysisWorkerResolver),
      task_supervisor: Map.get(opts, :task_supervisor, ServiceRadarCoreElx.CameraRelay.AnalysisDispatchTaskSupervisor),
      inflight: %{},
      failover_attempts: 0,
      max_failovers: positive_integer(Map.get(opts, :max_failovers), @default_max_failovers),
      excluded_worker_ids: [worker.worker_id]
    }

    case AnalysisBranchManager.open_branch(%{
           relay_session_id: relay_session_id,
           branch_id: branch_id,
           subscriber: self(),
           policy: state.policy
         }) do
      {:ok, _branch} ->
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:close, _from, state) do
    _ = AnalysisBranchManager.close_branch(state.relay_session_id, state.branch_id)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:camera_analysis_input, input}, state) do
    if map_size(state.inflight) >= state.worker.max_in_flight do
      emit_dispatch_event(state, :dispatch_dropped, input,
        reason: "max_in_flight",
        inflight_count: map_size(state.inflight)
      )

      {:noreply, state}
    else
      {:noreply, start_dispatch_task(state, input)}
    end
  end

  def handle_info({ref, {:ok, results}}, state) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.inflight, ref) do
      {nil, inflight} ->
        {:noreply, %{state | inflight: inflight}}

      {%{input: input}, inflight} ->
        result =
          Enum.reduce_while(results, :ok, fn worker_result, :ok ->
            payload = enrich_result(worker_result, input, state.worker.worker_id)

            case state.result_ingestor.ingest(payload) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case result do
          :ok ->
            state = maybe_mark_worker_healthy(state)
            emit_dispatch_event(state, :dispatch_succeeded, input, inflight_count: map_size(inflight))
            {:noreply, %{state | inflight: inflight}}

          {:error, reason} ->
            maybe_retry_failed_dispatch(state, input, inflight, reason)
        end
    end
  end

  def handle_info({ref, {:error, :timeout}}, state) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.inflight, ref) do
      {nil, inflight} ->
        {:noreply, %{state | inflight: inflight}}

      {%{input: input}, inflight} ->
        maybe_retry_failed_dispatch(state, input, inflight, :timeout)
    end
  end

  def handle_info({ref, {:error, reason}}, state) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.inflight, ref) do
      {nil, inflight} ->
        {:noreply, %{state | inflight: inflight}}

      {%{input: input}, inflight} ->
        maybe_retry_failed_dispatch(state, input, inflight, reason)
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.inflight, ref) do
      {nil, inflight} ->
        {:noreply, %{state | inflight: inflight}}

      {%{input: input}, inflight} ->
        maybe_retry_failed_dispatch(state, input, inflight, reason)
    end
  end

  defp enrich_result(worker_result, input, worker_id) when is_map(worker_result) do
    worker_result
    |> Map.put_new("schema", "camera_analysis_result.v1")
    |> Map.put_new("relay_session_id", input.relay_session_id)
    |> Map.put_new("branch_id", input.branch_id)
    |> Map.put_new("worker_id", worker_id)
    |> Map.put_new("media_ingest_id", input.media_ingest_id)
    |> Map.put_new("sequence", input.sequence)
  end

  defp emit_dispatch_event(state, event, input, measurements) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      event,
      %{
        relay_boundary: "core_elx",
        relay_session_id: state.relay_session_id,
        branch_id: state.branch_id,
        worker_id: state.worker.worker_id,
        reason: measurements[:reason],
        failover_attempt: measurements[:failover_attempt]
      },
      %{
        inflight_count: measurements[:inflight_count] || 0,
        sequence: input.sequence || 0,
        timeout_ms: state.worker.timeout_ms
      }
    )
  end

  defp start_dispatch_task(state, input) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        state.adapter.deliver(input, state.worker, state.adapter_opts)
      end)

    inflight =
      Map.put(state.inflight, task.ref, %{
        task_pid: task.pid,
        input: input
      })

    %{state | inflight: inflight}
  end

  defp maybe_retry_failed_dispatch(state, input, inflight, reason) do
    next_state = %{state | inflight: inflight}

    if failover_eligible?(state, reason) do
      mark_reason = format_reason(reason)
      _ = state.worker_resolver.mark_worker_unhealthy(state.worker.worker_id, mark_reason)

      emit_worker_health_changed(next_state, "unhealthy", mark_reason)

      selection_attrs = %{
        required_capability: state.worker.requested_capability,
        excluded_worker_ids: Enum.uniq([state.worker.worker_id | state.excluded_worker_ids])
      }

      case state.worker_resolver.resolve_http_worker(selection_attrs) do
        {:ok, replacement_worker} ->
          failover_attempt = state.failover_attempts + 1

          emit_failover_event(
            next_state,
            :worker_failover_succeeded,
            state.worker.worker_id,
            replacement_worker.worker_id,
            failover_attempt,
            mark_reason
          )

          replacement_state =
            next_state
            |> Map.put(
              :worker,
              Map.merge(next_state.worker, %{
                worker_id: replacement_worker.worker_id,
                endpoint_url: replacement_worker.endpoint_url,
                headers: replacement_worker.headers,
                selection_mode: replacement_worker.selection_mode,
                requested_capability: replacement_worker.requested_capability,
                registry_managed?: replacement_worker.registry_managed?
              })
            )
            |> Map.put(:failover_attempts, failover_attempt)
            |> Map.put(
              :excluded_worker_ids,
              Enum.uniq([replacement_worker.worker_id | selection_attrs.excluded_worker_ids])
            )
            |> start_dispatch_task(input)

          {:noreply, replacement_state}

        {:error, failover_reason} ->
          failover_attempt = state.failover_attempts + 1

          emit_failover_event(
            next_state,
            :worker_failover_failed,
            state.worker.worker_id,
            nil,
            failover_attempt,
            format_reason(failover_reason)
          )

          emit_terminal_dispatch_failure(next_state, input, reason, map_size(inflight), failover_attempt)
      end
    else
      emit_terminal_dispatch_failure(next_state, input, reason, map_size(inflight), state.failover_attempts)
    end
  end

  defp failover_eligible?(state, reason) do
    state.worker.selection_mode == "capability" and
      state.worker.registry_managed? and
      is_binary(state.worker.requested_capability) and
      state.failover_attempts < state.max_failovers and
      unavailable_reason?(reason)
  end

  defp unavailable_reason?(:timeout), do: true
  defp unavailable_reason?({:http_status, status, _body}) when status >= 500, do: true
  defp unavailable_reason?({:transport_error, _reason}), do: true
  defp unavailable_reason?(:noconnection), do: true
  defp unavailable_reason?(_reason), do: false

  defp maybe_mark_worker_healthy(state) do
    if state.worker.registry_managed? do
      case state.worker_resolver.mark_worker_healthy(state.worker.worker_id) do
        {:ok, _worker} ->
          emit_worker_health_changed(state, "healthy", nil)
          %{state | failover_attempts: 0, excluded_worker_ids: [state.worker.worker_id]}

        {:error, _reason} ->
          state
      end
    else
      state
    end
  end

  defp emit_worker_health_changed(state, health_status, reason) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      :worker_health_changed,
      %{
        relay_boundary: "core_elx",
        relay_session_id: state.relay_session_id,
        branch_id: state.branch_id,
        worker_id: state.worker.worker_id,
        health_status: health_status,
        reason: reason
      },
      %{
        failover_attempt: state.failover_attempts
      }
    )
  end

  defp emit_failover_event(state, event, from_worker_id, to_worker_id, failover_attempt, reason) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      event,
      %{
        relay_boundary: "core_elx",
        relay_session_id: state.relay_session_id,
        branch_id: state.branch_id,
        worker_id: from_worker_id,
        replacement_worker_id: to_worker_id,
        reason: reason
      },
      %{
        failover_attempt: failover_attempt
      }
    )
  end

  defp emit_terminal_dispatch_failure(state, input, reason, inflight_count, failover_attempt) do
    emit_dispatch_event(state, dispatch_failure_event(reason), input,
      reason: format_reason(reason),
      inflight_count: inflight_count,
      failover_attempt: failover_attempt
    )

    {:noreply, state}
  end

  defp dispatch_failure_event(:timeout), do: :dispatch_timed_out
  defp dispatch_failure_event(_reason), do: :dispatch_failed

  defp format_reason({:http_status, status, _body}), do: "http_status_#{status}"
  defp format_reason({:transport_error, reason}), do: "transport_error:#{reason}"
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp required_string!(opts, key) do
    case opts |> Map.get(key, Map.get(opts, to_string(key), "")) |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
end
