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

  @default_max_in_flight 1
  @default_timeout_ms 2_000

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
      max_in_flight: positive_integer(Map.get(opts, :max_in_flight), @default_max_in_flight)
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
      task_supervisor: Map.get(opts, :task_supervisor, ServiceRadarCoreElx.CameraRelay.AnalysisDispatchTaskSupervisor),
      inflight: %{}
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
      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          state.adapter.deliver(input, state.worker, state.adapter_opts)
        end)

      inflight =
        Map.put(state.inflight, task.ref, %{
          task_pid: task.pid,
          input: input
        })

      {:noreply, %{state | inflight: inflight}}
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
            emit_dispatch_event(state, :dispatch_succeeded, input, inflight_count: map_size(inflight))

          {:error, reason} ->
            emit_dispatch_event(state, :dispatch_failed, input,
              reason: format_reason(reason),
              inflight_count: map_size(inflight)
            )
        end

        {:noreply, %{state | inflight: inflight}}
    end
  end

  def handle_info({ref, {:error, :timeout}}, state) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.inflight, ref) do
      {nil, inflight} ->
        {:noreply, %{state | inflight: inflight}}

      {%{input: input}, inflight} ->
        emit_dispatch_event(state, :dispatch_timed_out, input, inflight_count: map_size(inflight))
        {:noreply, %{state | inflight: inflight}}
    end
  end

  def handle_info({ref, {:error, reason}}, state) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.inflight, ref) do
      {nil, inflight} ->
        {:noreply, %{state | inflight: inflight}}

      {%{input: input}, inflight} ->
        emit_dispatch_event(state, :dispatch_failed, input,
          reason: format_reason(reason),
          inflight_count: map_size(inflight)
        )

        {:noreply, %{state | inflight: inflight}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.inflight, ref) do
      {nil, inflight} ->
        {:noreply, %{state | inflight: inflight}}

      {%{input: input}, inflight} ->
        emit_dispatch_event(state, :dispatch_failed, input,
          reason: format_reason(reason),
          inflight_count: map_size(inflight)
        )

        {:noreply, %{state | inflight: inflight}}
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
        reason: measurements[:reason]
      },
      %{
        inflight_count: measurements[:inflight_count] || 0,
        sequence: input.sequence || 0,
        timeout_ms: state.worker.timeout_ms
      }
    )
  end

  defp format_reason({:http_status, status, _body}), do: "http_status_#{status}"
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
