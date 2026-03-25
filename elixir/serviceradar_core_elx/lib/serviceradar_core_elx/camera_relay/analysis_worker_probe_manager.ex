defmodule ServiceRadarCoreElx.CameraRelay.AnalysisWorkerProbeManager do
  @moduledoc """
  Periodically probes registered analysis workers so registry health stays fresh
  even when no relay-scoped analysis dispatch is active.
  """

  use GenServer

  alias ServiceRadar.Camera.AnalysisWorker
  alias ServiceRadar.Camera.AnalysisWorkerAlertRouter
  alias ServiceRadar.Telemetry
  alias ServiceRadarCoreElx.CameraRelay.AnalysisHTTPAdapter
  alias ServiceRadarCoreElx.CameraRelay.AnalysisWorkerResolver

  @default_probe_interval_ms 30_000
  @default_max_concurrency 4
  @default_task_timeout_ms 5_000
  @default_probe_history_limit 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def probe_now(server \\ __MODULE__) do
    GenServer.call(server, :probe_now, :infinity)
  end

  @impl true
  def init(opts) do
    state = %{
      resource: Keyword.get(opts, :resource, AnalysisWorker),
      telemetry_module: Keyword.get(opts, :telemetry_module, Telemetry),
      worker_resolver: Keyword.get(opts, :worker_resolver, AnalysisWorkerResolver),
      alert_router: Keyword.get(opts, :alert_router, AnalysisWorkerAlertRouter),
      task_supervisor:
        Keyword.get(opts, :task_supervisor, ServiceRadarCoreElx.CameraRelay.AnalysisDispatchTaskSupervisor),
      adapter_modules: Keyword.get(opts, :adapter_modules, %{"http" => AnalysisHTTPAdapter}),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      probe_interval_ms: positive_integer(Keyword.get(opts, :probe_interval_ms), @default_probe_interval_ms),
      probe_history_limit: positive_integer(Keyword.get(opts, :probe_history_limit), @default_probe_history_limit),
      max_concurrency: positive_integer(Keyword.get(opts, :max_concurrency), @default_max_concurrency),
      task_timeout_ms: positive_integer(Keyword.get(opts, :task_timeout_ms), @default_task_timeout_ms),
      schedule?: Keyword.get(opts, :schedule, true),
      last_probe_started_at: %{}
    }

    if state.schedule? do
      schedule_probe(state.probe_interval_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:probe_now, _from, state) do
    case run_probe_cycle(state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:probe_workers, state) do
    next_state =
      case run_probe_cycle(state) do
        {:ok, updated_state} -> updated_state
        {:error, _reason} -> state
      end

    schedule_probe(state.probe_interval_ms)
    {:noreply, next_state}
  end

  defp run_probe_cycle(state) do
    case state.resource.list_enabled([]) do
      {:ok, workers} ->
        now = DateTime.utc_now()

        due_workers =
          Enum.filter(workers, fn worker ->
            due_for_probe?(normalize_worker(worker), state, now)
          end)

        next_state =
          Enum.reduce(due_workers, state, fn worker, acc ->
            normalized_worker = normalize_worker(worker)
            put_in(acc.last_probe_started_at[normalized_worker.worker_id], now)
          end)

        state.task_supervisor
        |> Task.Supervisor.async_stream_nolink(
          due_workers,
          &probe_worker(&1, next_state),
          max_concurrency: state.max_concurrency,
          ordered: false,
          timeout: state.task_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.each(fn
          {:ok, {:probe_result, worker, result}} ->
            apply_probe_result(next_state, worker, result)

          {:exit, reason} ->
            emit_probe_failure(next_state, %{worker_id: "unknown", adapter: "unknown"}, format_reason(reason))
        end)

        {:ok, next_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp probe_worker(worker, state) do
    normalized_worker = normalize_worker(worker)

    result =
      case Map.get(state.adapter_modules, normalized_worker.adapter) do
        nil -> {:error, {:unsupported_worker_adapter, normalized_worker.adapter}}
        adapter -> adapter.probe_health(normalized_worker, state.adapter_opts)
      end

    {:probe_result, normalized_worker, result}
  end

  defp apply_probe_result(state, worker, :ok) do
    case mark_worker_healthy(state, worker.worker_id) do
      {:ok, updated_worker} ->
        emit_probe_success(state, worker)

        if worker.health_status != "healthy" do
          emit_health_transition(state, worker, "healthy", nil)
        end

        maybe_emit_flapping_transition(state, worker, updated_worker)
        maybe_emit_alert_transition(state, worker, updated_worker)

      {:error, _reason} ->
        :ok
    end
  end

  defp apply_probe_result(state, worker, {:error, reason}) do
    normalized_reason = format_reason(reason)

    case mark_worker_unhealthy(state, worker.worker_id, normalized_reason) do
      {:ok, updated_worker} ->
        emit_probe_failure(state, worker, normalized_reason)

        if worker.health_status != "unhealthy" do
          emit_health_transition(state, worker, "unhealthy", normalized_reason)
        end

        maybe_emit_flapping_transition(state, worker, updated_worker)
        maybe_emit_alert_transition(state, worker, updated_worker)

      {:error, _reason} ->
        :ok
    end
  end

  defp emit_probe_success(state, worker) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      :worker_probe_succeeded,
      %{
        relay_boundary: "core_elx",
        worker_id: worker.worker_id,
        adapter: worker.adapter
      },
      %{}
    )
  end

  defp emit_probe_failure(state, worker, reason) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      :worker_probe_failed,
      %{
        relay_boundary: "core_elx",
        worker_id: worker.worker_id,
        adapter: worker.adapter,
        reason: reason
      },
      %{}
    )
  end

  defp emit_health_transition(state, worker, health_status, reason) do
    state.telemetry_module.emit_camera_relay_analysis_event(
      :worker_health_changed,
      %{
        relay_boundary: "core_elx",
        worker_id: worker.worker_id,
        previous_health_status: worker.health_status,
        health_status: health_status,
        reason: reason
      },
      %{}
    )
  end

  defp maybe_emit_flapping_transition(state, worker, updated_worker) do
    previous_flapping = map_value(worker, :flapping, false)
    flapping = map_value(updated_worker, :flapping, false)

    if previous_flapping != flapping do
      state.telemetry_module.emit_camera_relay_analysis_event(
        :worker_flapping_changed,
        %{
          relay_boundary: "core_elx",
          worker_id: worker.worker_id,
          previous_flapping: previous_flapping,
          flapping: flapping,
          flapping_state: if(flapping, do: "flapping", else: "stable")
        },
        %{
          flapping_transition_count: map_value(updated_worker, :flapping_transition_count, 0),
          flapping_window_size: map_value(updated_worker, :flapping_window_size, 0)
        }
      )
    end
  end

  defp maybe_emit_alert_transition(state, worker, updated_worker) do
    previous_alert_state = map_value(worker, :alert_state)
    alert_state = map_value(updated_worker, :alert_state)

    if previous_alert_state != alert_state do
      state.telemetry_module.emit_camera_relay_analysis_event(
        :worker_alert_changed,
        %{
          relay_boundary: "core_elx",
          worker_id: worker.worker_id,
          previous_alert_state: previous_alert_state,
          alert_state: alert_state,
          alert_active: map_value(updated_worker, :alert_active, false),
          reason: map_value(updated_worker, :alert_reason)
        },
        %{
          consecutive_failures: map_value(updated_worker, :consecutive_failures, 0),
          flapping_transition_count: map_value(updated_worker, :flapping_transition_count, 0)
        }
      )

      _ =
        state.alert_router.route_transition(worker, updated_worker,
          relay_boundary: "core_elx",
          transition_source: "worker_probe"
        )
    end
  end

  defp normalize_worker(worker) when is_map(worker) do
    %{
      worker_id: map_value(worker, :worker_id),
      display_name: map_value(worker, :display_name),
      adapter: map_value(worker, :adapter, "http"),
      endpoint_url: map_value(worker, :endpoint_url),
      health_endpoint_url: map_value(worker, :health_endpoint_url),
      health_path: map_value(worker, :health_path),
      health_timeout_ms: map_value(worker, :health_timeout_ms),
      probe_interval_ms: map_value(worker, :probe_interval_ms),
      capabilities: map_value(worker, :capabilities, []),
      enabled: map_value(worker, :enabled, true),
      health_status: map_value(worker, :health_status, "healthy"),
      health_reason: map_value(worker, :health_reason),
      flapping: map_value(worker, :flapping, false),
      flapping_transition_count: map_value(worker, :flapping_transition_count, 0),
      flapping_window_size: map_value(worker, :flapping_window_size, 0),
      alert_active: map_value(worker, :alert_active, false),
      alert_state: map_value(worker, :alert_state),
      alert_reason: map_value(worker, :alert_reason),
      consecutive_failures: map_value(worker, :consecutive_failures, 0),
      headers: map_value(worker, :headers, %{}),
      metadata: map_value(worker, :metadata, %{})
    }
  end

  defp format_reason({:unsupported_worker_adapter, adapter}), do: "unsupported_worker_adapter:#{adapter}"
  defp format_reason({:http_status, status, _body}), do: "http_status_#{status}"
  defp format_reason({:transport_error, reason}), do: "transport_error:#{reason}"
  defp format_reason(:timeout), do: "timeout"
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp due_for_probe?(worker, state, now) do
    interval_ms = positive_integer(worker.probe_interval_ms, state.probe_interval_ms)

    case Map.get(state.last_probe_started_at, worker.worker_id) do
      nil -> true
      %DateTime{} = last_probe_started_at -> DateTime.diff(now, last_probe_started_at, :millisecond) >= interval_ms
    end
  end

  defp map_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp mark_worker_healthy(state, worker_id) do
    if function_exported?(state.worker_resolver, :mark_worker_healthy, 2) do
      state.worker_resolver.mark_worker_healthy(
        worker_id,
        record_probe_history: true,
        probe_history_limit: state.probe_history_limit
      )
    else
      state.worker_resolver.mark_worker_healthy(worker_id)
    end
  end

  defp mark_worker_unhealthy(state, worker_id, reason) do
    if function_exported?(state.worker_resolver, :mark_worker_unhealthy, 3) do
      state.worker_resolver.mark_worker_unhealthy(
        worker_id,
        reason,
        record_probe_history: true,
        probe_history_limit: state.probe_history_limit
      )
    else
      state.worker_resolver.mark_worker_unhealthy(worker_id, reason)
    end
  end

  defp schedule_probe(probe_interval_ms) do
    Process.send_after(self(), :probe_workers, probe_interval_ms)
  end
end
