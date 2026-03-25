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
        health_endpoint_url: "http://alpha.local/readyz",
        health_path: "/health",
        health_timeout_ms: 1500,
        probe_interval_ms: 10_000,
        capabilities: ["object_detection", "people_count"],
        enabled: true,
        health_status: "healthy",
        health_reason: nil,
        consecutive_failures: 0,
        last_healthy_at: DateTime.from_unix!(1_800_000_000),
        last_failure_at: nil,
        last_health_transition_at: DateTime.from_unix!(1_800_000_000),
        recent_probe_results: [
          %{"checked_at" => "2026-03-24T15:00:00Z", "status" => "healthy", "reason" => nil},
          %{"checked_at" => "2026-03-24T14:59:30Z", "status" => "healthy", "reason" => nil}
        ],
        active_assignment_count: 2,
        active_assignments: [
          %{
            relay_session_id: "relay-alpha-1",
            branch_id: "branch-alpha-1",
            worker_id: "worker-alpha",
            display_name: "Alpha Detector",
            adapter: "http",
            capabilities: ["object_detection"],
            selection_mode: "capability",
            requested_capability: "object_detection",
            registry_managed?: true
          },
          %{
            relay_session_id: "relay-alpha-2",
            branch_id: "branch-alpha-2",
            worker_id: "worker-alpha",
            display_name: "Alpha Detector",
            adapter: "http",
            capabilities: ["people_count"],
            selection_mode: "worker_id",
            requested_capability: nil,
            registry_managed?: true
          }
        ],
        notification_audit_active: false,
        notification_audit_alert_id: nil,
        notification_audit_alert_status: nil,
        notification_audit_notification_count: 0,
        notification_audit_last_notification_at: nil,
        notification_audit_suppressed_until: nil,
        flapping: false,
        flapping_transition_count: 0,
        flapping_window_size: 2,
        alert_active: false,
        alert_state: nil,
        alert_reason: nil,
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
        health_endpoint_url: nil,
        health_path: "/status",
        health_timeout_ms: 2500,
        probe_interval_ms: 30_000,
        capabilities: ["plate_read"],
        enabled: false,
        health_status: "unhealthy",
        health_reason: "http_status_503",
        consecutive_failures: 3,
        last_healthy_at: DateTime.from_unix!(1_800_000_050),
        last_failure_at: DateTime.from_unix!(1_800_000_100),
        last_health_transition_at: DateTime.from_unix!(1_800_000_100),
        recent_probe_results: [
          %{
            "checked_at" => "2026-03-24T15:00:00Z",
            "status" => "unhealthy",
            "reason" => "http_status_503"
          },
          %{"checked_at" => "2026-03-24T14:59:30Z", "status" => "healthy", "reason" => nil},
          %{
            "checked_at" => "2026-03-24T14:59:00Z",
            "status" => "unhealthy",
            "reason" => "http_status_503"
          },
          %{"checked_at" => "2026-03-24T14:58:30Z", "status" => "healthy", "reason" => nil},
          %{
            "checked_at" => "2026-03-24T14:58:00Z",
            "status" => "unhealthy",
            "reason" => "http_status_503"
          }
        ],
        active_assignment_count: 0,
        active_assignments: [],
        notification_audit_active: true,
        notification_audit_alert_id: "alert-worker-beta-flapping",
        notification_audit_alert_status: "pending",
        notification_audit_notification_count: 2,
        notification_audit_last_notification_at: DateTime.from_unix!(1_800_000_120),
        notification_audit_suppressed_until: DateTime.from_unix!(1_800_000_420),
        flapping: true,
        flapping_transition_count: 4,
        flapping_window_size: 5,
        alert_active: true,
        alert_state: "flapping",
        alert_reason: "status_transitions_threshold",
        inserted_at: DateTime.from_unix!(1_800_000_000),
        updated_at: DateTime.from_unix!(1_800_000_100),
        headers: %{},
        metadata: %{"pool" => "overflow"}
      })
    ]
  end

  defp build_worker(attrs) do
    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          worker_id: "worker",
          display_name: nil,
          adapter: "http",
          endpoint_url: "http://worker.local/analyze",
          health_endpoint_url: nil,
          health_path: nil,
          health_timeout_ms: nil,
          probe_interval_ms: nil,
          capabilities: [],
          enabled: true,
          health_status: "healthy",
          health_reason: nil,
          consecutive_failures: 0,
          last_healthy_at: nil,
          last_failure_at: nil,
          last_health_transition_at: nil,
          recent_probe_results: [],
          active_assignment_count: 0,
          active_assignments: [],
          notification_audit_active: false,
          notification_audit_alert_id: nil,
          notification_audit_alert_status: nil,
          notification_audit_notification_count: 0,
          notification_audit_last_notification_at: nil,
          notification_audit_suppressed_until: nil,
          flapping: false,
          flapping_transition_count: 0,
          flapping_window_size: 0,
          alert_active: false,
          alert_state: nil,
          alert_reason: nil,
          inserted_at: nil,
          updated_at: nil,
          headers: %{},
          metadata: %{}
        },
        attrs
      )

    worker =
      struct!(
        ServiceRadar.Camera.AnalysisWorker,
        Map.drop(attrs, [
          :active_assignment_count,
          :active_assignments,
          :notification_audit_active,
          :notification_audit_alert_id,
          :notification_audit_alert_status,
          :notification_audit_notification_count,
          :notification_audit_last_notification_at,
          :notification_audit_suppressed_until
        ])
      )

    worker
    |> Map.put(:active_assignment_count, Map.get(attrs, :active_assignment_count, 0))
    |> Map.put(:active_assignments, Map.get(attrs, :active_assignments, []))
    |> Map.put(:notification_audit_active, Map.get(attrs, :notification_audit_active, false))
    |> Map.put(:notification_audit_alert_id, Map.get(attrs, :notification_audit_alert_id))
    |> Map.put(:notification_audit_alert_status, Map.get(attrs, :notification_audit_alert_status))
    |> Map.put(
      :notification_audit_notification_count,
      Map.get(attrs, :notification_audit_notification_count, 0)
    )
    |> Map.put(
      :notification_audit_last_notification_at,
      Map.get(attrs, :notification_audit_last_notification_at)
    )
    |> Map.put(
      :notification_audit_suppressed_until,
      Map.get(attrs, :notification_audit_suppressed_until)
    )
  end

  defp test_pid do
    Application.fetch_env!(:serviceradar_web_ng, :camera_analysis_workers_test_pid)
  end
end
