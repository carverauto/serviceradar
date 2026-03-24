defmodule ServiceRadarCoreElx.CameraRelay.AnalysisWorkerProbeManagerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.CameraRelay.AnalysisWorkerProbeManager

  defmodule ResourceStub do
    @moduledoc false

    def list_enabled(_opts) do
      {:ok, Application.fetch_env!(:serviceradar_core_elx, :analysis_probe_workers)}
    end
  end

  defmodule ResolverStub do
    @moduledoc false

    def mark_worker_healthy(worker_id), do: mark_worker_healthy(worker_id, [])

    def mark_worker_healthy(worker_id, opts) do
      send(test_pid(), {:mark_worker_healthy, worker_id, opts})

      {:ok,
       Map.merge(
         %{
           worker_id: worker_id,
           health_status: "healthy",
           flapping: false,
           flapping_transition_count: 0,
           flapping_window_size: 0
         },
         updated_worker({:healthy, worker_id})
       )}
    end

    def mark_worker_unhealthy(worker_id, reason), do: mark_worker_unhealthy(worker_id, reason, [])

    def mark_worker_unhealthy(worker_id, reason, opts) do
      send(test_pid(), {:mark_worker_unhealthy, worker_id, reason, opts})

      {:ok,
       Map.merge(
         %{
           worker_id: worker_id,
           health_status: "unhealthy",
           health_reason: reason,
           flapping: false,
           flapping_transition_count: 0,
           flapping_window_size: 0
         },
         updated_worker({:unhealthy, worker_id})
       )}
    end

    defp updated_worker(key) do
      :serviceradar_core_elx
      |> Application.get_env(:analysis_probe_updated_workers, %{})
      |> Map.get(key, %{})
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :analysis_probe_test_pid)
    end
  end

  defmodule AdapterStub do
    @moduledoc false

    def probe_health(worker, _opts) do
      send(test_pid(), {:probe_health, worker.worker_id, worker.adapter})

      case Map.get(modes(), worker.worker_id, :ok) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp modes do
      Application.get_env(:serviceradar_core_elx, :analysis_probe_modes, %{})
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :analysis_probe_test_pid)
    end
  end

  defmodule TelemetryStub do
    @moduledoc false

    def emit_camera_relay_analysis_event(event, metadata, measurements) do
      send(test_pid(), {:telemetry_event, event, metadata, measurements})
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :analysis_probe_test_pid)
    end
  end

  defmodule AlertRouterStub do
    @moduledoc false

    def route_transition(previous_worker, updated_worker, opts) do
      send(test_pid(), {:route_worker_alert, previous_worker, updated_worker, opts})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :analysis_probe_test_pid)
    end
  end

  setup do
    previous_workers = Application.get_env(:serviceradar_core_elx, :analysis_probe_workers)
    previous_modes = Application.get_env(:serviceradar_core_elx, :analysis_probe_modes)
    previous_updated_workers = Application.get_env(:serviceradar_core_elx, :analysis_probe_updated_workers)
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :analysis_probe_test_pid)

    Application.put_env(:serviceradar_core_elx, :analysis_probe_test_pid, self())
    Application.put_env(:serviceradar_core_elx, :analysis_probe_modes, %{})
    Application.put_env(:serviceradar_core_elx, :analysis_probe_updated_workers, %{})

    task_supervisor = start_supervised!({Task.Supervisor, name: unique_name("analysis-probe-task-supervisor")})

    on_exit(fn ->
      restore_env(:analysis_probe_workers, previous_workers)
      restore_env(:analysis_probe_modes, previous_modes)
      restore_env(:analysis_probe_updated_workers, previous_updated_workers)
      restore_env(:analysis_probe_test_pid, previous_test_pid)
    end)

    %{task_supervisor: task_supervisor}
  end

  test "probes enabled workers and updates health state from probe results", %{task_supervisor: task_supervisor} do
    Application.put_env(
      :serviceradar_core_elx,
      :analysis_probe_workers,
      [
        %{
          worker_id: "worker-steady",
          adapter: "http",
          endpoint_url: "http://steady.local/analyze",
          health_endpoint_url: "http://steady.local/readyz",
          health_timeout_ms: 1400,
          probe_interval_ms: 1000,
          enabled: true,
          health_status: "healthy",
          headers: %{},
          metadata: %{}
        },
        %{
          worker_id: "worker-recovering",
          adapter: "http",
          endpoint_url: "http://recover.local/analyze",
          health_path: "/status",
          probe_interval_ms: 1000,
          enabled: true,
          health_status: "unhealthy",
          health_reason: "http_status_503",
          headers: %{},
          metadata: %{}
        },
        %{
          worker_id: "worker-failing",
          adapter: "http",
          endpoint_url: "http://fail.local/analyze",
          probe_interval_ms: 1000,
          enabled: true,
          health_status: "healthy",
          headers: %{},
          metadata: %{}
        }
      ]
    )

    Application.put_env(
      :serviceradar_core_elx,
      :analysis_probe_modes,
      %{
        "worker-steady" => :ok,
        "worker-recovering" => :ok,
        "worker-failing" => {:error, {:http_status, 503, %{"error" => "down"}}}
      }
    )

    manager =
      start_supervised!(
        {AnalysisWorkerProbeManager,
         name: unique_name("analysis-worker-probe-manager"),
         schedule: false,
         resource: ResourceStub,
         worker_resolver: ResolverStub,
         telemetry_module: TelemetryStub,
         task_supervisor: task_supervisor,
         adapter_modules: %{"http" => AdapterStub},
         max_concurrency: 2}
      )

    assert :ok = AnalysisWorkerProbeManager.probe_now(manager)

    assert_receive {:probe_health, "worker-steady", "http"}
    assert_receive {:probe_health, "worker-recovering", "http"}
    assert_receive {:probe_health, "worker-failing", "http"}

    assert_receive {:mark_worker_healthy, "worker-steady", steady_opts}
    assert steady_opts[:record_probe_history] == true
    assert steady_opts[:probe_history_limit] == 5

    assert_receive {:mark_worker_healthy, "worker-recovering", recovering_opts}
    assert recovering_opts[:record_probe_history] == true
    assert recovering_opts[:probe_history_limit] == 5

    assert_receive {:mark_worker_unhealthy, "worker-failing", "http_status_503", failing_opts}
    assert failing_opts[:record_probe_history] == true
    assert failing_opts[:probe_history_limit] == 5

    assert_receive {:telemetry_event, :worker_probe_succeeded, %{worker_id: "worker-steady"}, %{}}
    assert_receive {:telemetry_event, :worker_probe_succeeded, %{worker_id: "worker-recovering"}, %{}}

    assert_receive {:telemetry_event, :worker_probe_failed, %{worker_id: "worker-failing", reason: "http_status_503"},
                    %{}}

    assert_receive {:telemetry_event, :worker_health_changed,
                    %{worker_id: "worker-recovering", previous_health_status: "unhealthy", health_status: "healthy"}, %{}}

    assert_receive {:telemetry_event, :worker_health_changed,
                    %{
                      worker_id: "worker-failing",
                      previous_health_status: "healthy",
                      health_status: "unhealthy",
                      reason: "http_status_503"
                    }, %{}}

    refute_receive {:telemetry_event, :worker_health_changed, %{worker_id: "worker-steady"}, %{}}
  end

  test "marks unsupported adapters unhealthy and emits probe failure", %{task_supervisor: task_supervisor} do
    Application.put_env(
      :serviceradar_core_elx,
      :analysis_probe_workers,
      [
        %{
          worker_id: "worker-grpc",
          adapter: "grpc",
          endpoint_url: "grpc://worker-grpc.local/analyze",
          probe_interval_ms: 1000,
          enabled: true,
          health_status: "healthy",
          headers: %{},
          metadata: %{}
        }
      ]
    )

    manager =
      start_supervised!(
        {AnalysisWorkerProbeManager,
         name: unique_name("analysis-worker-probe-manager-unsupported"),
         schedule: false,
         resource: ResourceStub,
         worker_resolver: ResolverStub,
         alert_router: AlertRouterStub,
         telemetry_module: TelemetryStub,
         task_supervisor: task_supervisor,
         adapter_modules: %{"http" => AdapterStub}}
      )

    assert :ok = AnalysisWorkerProbeManager.probe_now(manager)

    assert_receive {:mark_worker_unhealthy, "worker-grpc", "unsupported_worker_adapter:grpc", opts}
    assert opts[:record_probe_history] == true
    assert opts[:probe_history_limit] == 5

    assert_receive {:telemetry_event, :worker_probe_failed,
                    %{worker_id: "worker-grpc", adapter: "grpc", reason: "unsupported_worker_adapter:grpc"}, %{}}

    assert_receive {:telemetry_event, :worker_health_changed,
                    %{worker_id: "worker-grpc", previous_health_status: "healthy", health_status: "unhealthy"}, %{}}
  end

  test "respects per-worker probe intervals between probe cycles", %{task_supervisor: task_supervisor} do
    Application.put_env(
      :serviceradar_core_elx,
      :analysis_probe_workers,
      [
        %{
          worker_id: "worker-slow",
          adapter: "http",
          endpoint_url: "http://slow.local/analyze",
          probe_interval_ms: 60_000,
          enabled: true,
          health_status: "healthy",
          headers: %{},
          metadata: %{}
        }
      ]
    )

    manager =
      start_supervised!(
        {AnalysisWorkerProbeManager,
         name: unique_name("analysis-worker-probe-manager-interval"),
         schedule: false,
         resource: ResourceStub,
         worker_resolver: ResolverStub,
         telemetry_module: TelemetryStub,
         task_supervisor: task_supervisor,
         adapter_modules: %{"http" => AdapterStub}}
      )

    assert :ok = AnalysisWorkerProbeManager.probe_now(manager)
    assert_receive {:probe_health, "worker-slow", "http"}
    assert_receive {:mark_worker_healthy, "worker-slow", opts}
    assert opts[:record_probe_history] == true
    assert opts[:probe_history_limit] == 5

    assert :ok = AnalysisWorkerProbeManager.probe_now(manager)
    refute_receive {:probe_health, "worker-slow", "http"}
  end

  test "emits flapping transition telemetry when derived flapping state changes", %{task_supervisor: task_supervisor} do
    Application.put_env(
      :serviceradar_core_elx,
      :analysis_probe_workers,
      [
        %{
          worker_id: "worker-flappy",
          adapter: "http",
          endpoint_url: "http://flappy.local/analyze",
          probe_interval_ms: 1000,
          enabled: true,
          health_status: "healthy",
          flapping: false,
          headers: %{},
          metadata: %{}
        }
      ]
    )

    Application.put_env(
      :serviceradar_core_elx,
      :analysis_probe_modes,
      %{"worker-flappy" => {:error, {:http_status, 503, %{"error" => "down"}}}}
    )

    Application.put_env(
      :serviceradar_core_elx,
      :analysis_probe_updated_workers,
      %{
        {:unhealthy, "worker-flappy"} => %{
          flapping: true,
          alert_active: true,
          alert_state: "flapping",
          alert_reason: "status_transitions_threshold",
          flapping_transition_count: 3,
          flapping_window_size: 5
        }
      }
    )

    manager =
      start_supervised!(
        {AnalysisWorkerProbeManager,
         name: unique_name("analysis-worker-probe-manager-flapping"),
         schedule: false,
         resource: ResourceStub,
         worker_resolver: ResolverStub,
         alert_router: AlertRouterStub,
         telemetry_module: TelemetryStub,
         task_supervisor: task_supervisor,
         adapter_modules: %{"http" => AdapterStub}}
      )

    assert :ok = AnalysisWorkerProbeManager.probe_now(manager)

    assert_receive {:telemetry_event, :worker_flapping_changed,
                    %{
                      worker_id: "worker-flappy",
                      previous_flapping: false,
                      flapping: true,
                      flapping_state: "flapping"
                    }, %{flapping_transition_count: 3, flapping_window_size: 5}}

    assert_receive {:telemetry_event, :worker_alert_changed,
                    %{
                      worker_id: "worker-flappy",
                      previous_alert_state: nil,
                      alert_state: "flapping",
                      alert_active: true,
                      reason: "status_transitions_threshold"
                    }, %{consecutive_failures: 0, flapping_transition_count: 3}}

    assert_receive {:route_worker_alert, previous_worker, updated_worker, opts}
    assert previous_worker.worker_id == "worker-flappy"
    assert updated_worker.alert_state == "flapping"
    assert opts[:transition_source] == "worker_probe"
    assert opts[:relay_boundary] == "core_elx"
  end

  defp unique_name(prefix) do
    :"#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
end
