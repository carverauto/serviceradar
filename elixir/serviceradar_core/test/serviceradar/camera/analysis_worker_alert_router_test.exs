defmodule ServiceRadar.Camera.AnalysisWorkerAlertRouterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.AnalysisWorkerAlertRouter

  test "routes alert activation into an event and alert with normalized context" do
    parent = self()

    previous_worker =
      worker_fixture(%{
        worker_id: "worker-alpha",
        display_name: "Alpha Detector",
        adapter: "http",
        capabilities: ["object_detection"],
        health_status: "healthy",
        alert_active: false,
        alert_state: nil
      })

    updated_worker =
      worker_fixture(%{
        worker_id: "worker-alpha",
        display_name: "Alpha Detector",
        adapter: "http",
        capabilities: ["object_detection"],
        health_status: "unhealthy",
        health_reason: "http_status_503",
        consecutive_failures: 3,
        alert_active: true,
        alert_state: "unhealthy",
        alert_reason: "http_status_503"
      })

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, Map.put(attrs, :id, attrs.id)}
    end

    broadcast_event = fn event ->
      send(parent, {:broadcast_event, event})
      :ok
    end

    create_alert = fn attrs, _actor ->
      send(parent, {:create_alert, attrs})
      {:ok, attrs}
    end

    assert :ok =
             AnalysisWorkerAlertRouter.route_transition(
               previous_worker,
               updated_worker,
               record_event: record_event,
               broadcast_event: broadcast_event,
               create_alert: create_alert
             )

    assert_receive {:record_event, event_attrs}
    assert event_attrs.log_name == "camera.analysis.worker.alert"
    assert event_attrs.metadata["camera_analysis_worker_id"] == "worker-alpha"
    assert event_attrs.metadata["alert_transition"] == "activate"
    assert event_attrs.metadata["alert_state"] == "unhealthy"

    assert event_attrs.metadata["routed_alert_key"] ==
             "camera_analysis_worker:worker-alpha:unhealthy"

    event_id = event_attrs.id
    assert_receive {:broadcast_event, %{id: ^event_id}}

    assert_receive {:create_alert, alert_attrs}
    assert alert_attrs.source_type == :event
    assert alert_attrs.source_id == "camera_analysis_worker:worker-alpha:unhealthy"
    assert alert_attrs.metadata["camera_analysis_worker_id"] == "worker-alpha"
    assert alert_attrs.metadata["event_id"] == event_attrs.id
  end

  test "routes alert clear by recording a recovery event and resolving active alerts" do
    parent = self()

    previous_worker =
      worker_fixture(%{
        worker_id: "worker-beta",
        alert_active: true,
        alert_state: "flapping",
        alert_reason: "status_transitions_threshold",
        flapping: true,
        flapping_transition_count: 4
      })

    updated_worker =
      worker_fixture(%{
        worker_id: "worker-beta",
        alert_active: false,
        alert_state: nil,
        alert_reason: nil,
        flapping: false,
        health_status: "healthy"
      })

    alert = %{id: "alert-1", source_id: "camera_analysis_worker:worker-beta:flapping"}

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, Map.put(attrs, :id, attrs.id)}
    end

    broadcast_event = fn event ->
      send(parent, {:broadcast_event, event})
      :ok
    end

    list_active_alerts = fn routing_key, _actor ->
      send(parent, {:list_active_alerts, routing_key})
      {:ok, [alert]}
    end

    resolve_alert = fn resolved_alert, opts, event ->
      send(parent, {:resolve_alert, resolved_alert, opts, event})
      {:ok, resolved_alert}
    end

    assert :ok =
             AnalysisWorkerAlertRouter.route_transition(
               previous_worker,
               updated_worker,
               record_event: record_event,
               broadcast_event: broadcast_event,
               list_active_alerts: list_active_alerts,
               resolve_alert: resolve_alert
             )

    assert_receive {:record_event, event_attrs}
    assert event_attrs.log_name == "camera.analysis.worker.alert.clear"
    assert event_attrs.metadata["alert_transition"] == "clear"
    assert event_attrs.metadata["previous_alert_state"] == "flapping"

    assert_receive {:list_active_alerts, "camera_analysis_worker:worker-beta:flapping"}

    event_id = event_attrs.id
    assert_receive {:resolve_alert, %{id: "alert-1"}, opts, %{id: ^event_id}}
    assert opts[:resolved_by] == "camera_analysis_worker_alert_router"
    assert opts[:resolution_note] =~ "camera_analysis_worker:worker-beta:flapping"
  end

  test "routes state replacement as clear plus new activation" do
    parent = self()

    previous_worker =
      worker_fixture(%{
        worker_id: "worker-gamma",
        alert_active: true,
        alert_state: "unhealthy",
        alert_reason: "http_status_503"
      })

    updated_worker =
      worker_fixture(%{
        worker_id: "worker-gamma",
        alert_active: true,
        alert_state: "flapping",
        alert_reason: "status_transitions_threshold",
        flapping: true,
        flapping_transition_count: 3
      })

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, Map.put(attrs, :id, attrs.id)}
    end

    broadcast_event = fn _event -> :ok end

    create_alert = fn attrs, _actor ->
      send(parent, {:create_alert, attrs})
      {:ok, attrs}
    end

    list_active_alerts = fn routing_key, _actor ->
      send(parent, {:list_active_alerts, routing_key})
      {:ok, [%{id: "alert-old", source_id: routing_key}]}
    end

    resolve_alert = fn alert, _opts, _event ->
      send(parent, {:resolve_alert, alert})
      {:ok, alert}
    end

    assert :ok =
             AnalysisWorkerAlertRouter.route_transition(
               previous_worker,
               updated_worker,
               record_event: record_event,
               broadcast_event: broadcast_event,
               create_alert: create_alert,
               list_active_alerts: list_active_alerts,
               resolve_alert: resolve_alert
             )

    assert_receive {:record_event, clear_event}
    assert clear_event.metadata["alert_transition"] == "clear"
    assert clear_event.metadata["previous_alert_state"] == "unhealthy"

    assert_receive {:list_active_alerts, "camera_analysis_worker:worker-gamma:unhealthy"}
    assert_receive {:resolve_alert, %{id: "alert-old"}}

    assert_receive {:record_event, activate_event}
    assert activate_event.metadata["alert_transition"] == "activate"
    assert activate_event.metadata["alert_state"] == "flapping"

    assert_receive {:create_alert, %{source_id: "camera_analysis_worker:worker-gamma:flapping"}}
  end

  test "suppresses duplicate routing when the alert state is unchanged" do
    worker =
      worker_fixture(%{
        worker_id: "worker-delta",
        alert_active: true,
        alert_state: "flapping",
        alert_reason: "status_transitions_threshold"
      })

    assert :ok =
             AnalysisWorkerAlertRouter.route_transition(
               worker,
               worker,
               record_event: fn _attrs, _actor ->
                 flunk("should not record event")
               end
             )
  end

  test "builds routed alert context for API/UI correlation" do
    worker =
      worker_fixture(%{
        worker_id: "worker-epsilon",
        display_name: "Epsilon Detector",
        alert_active: true,
        alert_state: "failover_exhausted"
      })

    context = AnalysisWorkerAlertRouter.routed_alert_context(worker)

    assert context.routed_alert_active == true
    assert context.routed_alert_key == "camera_analysis_worker:worker-epsilon:failover_exhausted"
    assert context.routed_alert_source_type == "event"

    assert context.routed_alert_source_id ==
             "camera_analysis_worker:worker-epsilon:failover_exhausted"

    assert context.routed_alert_title =~ "Epsilon Detector"
  end

  defp worker_fixture(overrides) do
    Map.merge(
      %{
        worker_id: "worker",
        display_name: nil,
        adapter: "http",
        capabilities: [],
        health_status: "healthy",
        health_reason: nil,
        consecutive_failures: 0,
        flapping: false,
        flapping_transition_count: 0,
        requested_capability: nil,
        selection_mode: "worker_id",
        endpoint_url: "http://worker.local/analyze",
        alert_active: false,
        alert_state: nil,
        alert_reason: nil
      },
      overrides
    )
  end
end
