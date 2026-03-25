defmodule ServiceRadar.Camera.AnalysisWorkerNotificationAuditTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.AnalysisWorkerNotificationAudit

  test "returns notification audit state for workers with active routed alerts" do
    parent = self()
    last_notification_at = DateTime.from_unix!(1_800_000_120)
    suppressed_until = DateTime.from_unix!(1_800_000_420)

    workers = [
      %{worker_id: "worker-alpha", alert_active: false, alert_state: nil},
      %{worker_id: "worker-beta", alert_active: true, alert_state: "flapping"}
    ]

    list_alerts = fn keys, _scope ->
      send(parent, {:list_alerts, keys})

      {:ok,
       [
         %{
           id: "alert-worker-beta-flapping",
           source_id: "camera_analysis_worker:worker-beta:flapping",
           status: :pending,
           notification_count: 2,
           last_notification_at: last_notification_at,
           suppressed_until: suppressed_until
         }
       ]}
    end

    assert {:ok, audit_contexts} =
             AnalysisWorkerNotificationAudit.audit_contexts(
               workers,
               list_alerts: list_alerts
             )

    assert_receive {:list_alerts, ["camera_analysis_worker:worker-beta:flapping"]}

    assert audit_contexts["worker-alpha"] == %{
             notification_audit_active: false,
             notification_audit_alert_id: nil,
             notification_audit_alert_status: nil,
             notification_audit_notification_count: 0,
             notification_audit_last_notification_at: nil,
             notification_audit_suppressed_until: nil
           }

    assert audit_contexts["worker-beta"] == %{
             notification_audit_active: true,
             notification_audit_alert_id: "alert-worker-beta-flapping",
             notification_audit_alert_status: "pending",
             notification_audit_notification_count: 2,
             notification_audit_last_notification_at: last_notification_at,
             notification_audit_suppressed_until: suppressed_until
           }
  end

  test "does not query alerts when no workers have active routed alerts" do
    workers = [
      %{worker_id: "worker-alpha", alert_active: false, alert_state: nil}
    ]

    assert {:ok, audit_contexts} =
             AnalysisWorkerNotificationAudit.audit_contexts(
               workers,
               list_alerts: fn _keys, _scope ->
                 flunk("should not query alerts when no routed worker alerts are active")
               end
             )

    assert audit_contexts["worker-alpha"].notification_audit_active == false
  end

  test "returns inactive audit state when routed alert has no active standard alert record" do
    worker = %{worker_id: "worker-gamma", alert_active: true, alert_state: "unhealthy"}

    assert {:ok, context} =
             AnalysisWorkerNotificationAudit.audit_context(
               worker,
               list_alerts: fn ["camera_analysis_worker:worker-gamma:unhealthy"], _scope ->
                 {:ok, []}
               end
             )

    assert context.notification_audit_active == false
    assert context.notification_audit_notification_count == 0
    assert context.notification_audit_last_notification_at == nil
  end
end
