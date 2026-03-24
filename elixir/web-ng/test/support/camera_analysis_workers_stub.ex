defmodule ServiceRadarWebNG.TestSupport.CameraAnalysisWorkersStub do
  @moduledoc false

  def list_workers(opts) do
    send(test_pid(), {:camera_analysis_workers_list, opts})
    {:ok, workers()}
  end

  def get_worker(id, opts) do
    send(test_pid(), {:camera_analysis_workers_get, id, opts})

    case Enum.find(workers(), &(to_string(&1.id) == to_string(id))) do
      nil -> {:ok, nil}
      worker -> {:ok, worker}
    end
  end

  def create_worker(attrs, opts) do
    send(test_pid(), {:camera_analysis_workers_create, attrs, opts})
    {:ok, build_worker(Map.put(attrs, :id, Ecto.UUID.generate()))}
  end

  def update_worker(id, attrs, opts) do
    send(test_pid(), {:camera_analysis_workers_update, id, attrs, opts})

    case Enum.find(workers(), &(to_string(&1.id) == to_string(id))) do
      nil -> {:error, :not_found}
      worker -> {:ok, build_worker(Map.merge(Map.from_struct(worker), attrs))}
    end
  end

  def set_enabled(id, enabled, opts) do
    send(test_pid(), {:camera_analysis_workers_set_enabled, id, enabled, opts})

    case Enum.find(workers(), &(to_string(&1.id) == to_string(id))) do
      nil -> {:error, :not_found}
      worker -> {:ok, build_worker(Map.put(Map.from_struct(worker), :enabled, enabled))}
    end
  end

  defp workers do
    [
      build_worker(%{
        id: "00000000-0000-0000-0000-000000000101",
        worker_id: "worker-alpha",
        display_name: "Alpha Detector",
        adapter: "http",
        endpoint_url: "http://alpha.local/analyze",
        capabilities: ["object_detection", "people_count"],
        enabled: true,
        health_status: "healthy",
        health_reason: nil,
        consecutive_failures: 0,
        last_healthy_at: DateTime.from_unix!(1_800_000_000),
        last_failure_at: nil,
        last_health_transition_at: DateTime.from_unix!(1_800_000_000),
        inserted_at: DateTime.from_unix!(1_800_000_000),
        updated_at: DateTime.from_unix!(1_800_000_000),
        headers: %{"authorization" => "Bearer secret"},
        metadata: %{"pool" => "default"}
      }),
      build_worker(%{
        id: "00000000-0000-0000-0000-000000000102",
        worker_id: "worker-beta",
        display_name: "Beta Detector",
        adapter: "http",
        endpoint_url: "http://beta.local/analyze",
        capabilities: ["plate_read"],
        enabled: false,
        health_status: "unhealthy",
        health_reason: "http_status_503",
        consecutive_failures: 3,
        last_healthy_at: DateTime.from_unix!(1_800_000_050),
        last_failure_at: DateTime.from_unix!(1_800_000_100),
        last_health_transition_at: DateTime.from_unix!(1_800_000_100),
        inserted_at: DateTime.from_unix!(1_800_000_000),
        updated_at: DateTime.from_unix!(1_800_000_100),
        headers: %{},
        metadata: %{"pool" => "overflow"}
      })
    ]
  end

  defp build_worker(attrs) do
    struct!(
      ServiceRadar.Camera.AnalysisWorker,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          worker_id: "worker",
          display_name: nil,
          adapter: "http",
          endpoint_url: "http://worker.local/analyze",
          capabilities: [],
          enabled: true,
          health_status: "healthy",
          health_reason: nil,
          consecutive_failures: 0,
          last_healthy_at: nil,
          last_failure_at: nil,
          last_health_transition_at: nil,
          inserted_at: nil,
          updated_at: nil,
          headers: %{},
          metadata: %{}
        },
        attrs
      )
    )
  end

  defp test_pid do
    Application.fetch_env!(:serviceradar_web_ng, :camera_analysis_workers_test_pid)
  end
end
