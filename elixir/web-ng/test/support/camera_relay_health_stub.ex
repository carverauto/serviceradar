defmodule ServiceRadarWebNG.CameraRelayHealthStub do
  @moduledoc false

  def overview(_opts) do
    {:ok,
     %{
       active_alerts: [
         %{
           id: "relay-alert-1",
           title: "Camera Relay Failure Burst",
           description: "Camera relay failure burst detected",
           status: "pending",
           severity: "warning",
           triggered_at: ~U[2026-03-24 12:05:00Z],
           notification_count: 2,
           last_notification_at: ~U[2026-03-24 12:06:00Z],
           log_name: "camera.relay.alert.failure_burst",
           log_provider: "serviceradar.core"
         }
       ],
       recent_events: [
         %{
           id: "relay-event-1",
           time: ~U[2026-03-24 12:07:00Z],
           message: "Camera relay session failed during request_open: agent_offline",
           log_name: "camera.relay.session.failed",
           severity: "High",
           status: "Failure",
           status_detail: "agent_offline",
           relay_health_kind: "session_failure",
           relay_session_id: "relay-ops-1",
           gateway_id: "gateway-ops-1",
           camera_source_id: "camera-ops-1",
           reason: "agent_offline"
         }
       ]
     }}
  end
end
