defmodule ServiceRadar.Camera.RelayHealthEventRouterTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelayHealthEventRouter

  test "records a structured relay session failure event" do
    test_pid = self()

    assert :ok =
             RelayHealthEventRouter.record_session_failure(
               %{
                 relay_boundary: "core_elx",
                 relay_session_id: "relay-1",
                 gateway_id: "gateway-1",
                 camera_source_id: "camera-1",
                 stream_profile_id: "high",
                 failure_reason: "pipeline_write_failed",
                 stage: "record_chunk",
                 viewer_count: 2
               },
               record_event: fn attrs, _actor ->
                 send(test_pid, {:record_event, attrs})
                 {:ok, Map.put(attrs, :persisted, true)}
               end,
               broadcast_event: fn event ->
                 send(test_pid, {:broadcast_event, event})
                 :ok
               end
             )

    assert_receive {:record_event, attrs}
    assert attrs.log_name == RelayHealthEventRouter.session_failure_log_name()
    assert attrs.message =~ "record_chunk"
    assert attrs.message =~ "pipeline_write_failed"
    assert attrs.metadata["relay_health_kind"] == "session_failure"
    assert attrs.metadata["relay_session_id"] == "relay-1"
    assert attrs.metadata["gateway_id"] == "gateway-1"
    assert attrs.metadata["viewer_count"] == 2

    assert_receive {:broadcast_event, event}
    assert event.persisted == true
  end

  test "records a structured gateway saturation denial event" do
    test_pid = self()

    assert :ok =
             RelayHealthEventRouter.record_gateway_saturation_denial(
               %{
                 relay_boundary: "agent_gateway",
                 relay_session_id: "relay-2",
                 gateway_id: "gateway-2",
                 agent_id: "agent-2",
                 limit_kind: "gateway",
                 limit: 32
               },
               record_event: fn attrs, _actor ->
                 send(test_pid, {:record_event, attrs})
                 {:ok, attrs}
               end,
               broadcast_event: fn event ->
                 send(test_pid, {:broadcast_event, event})
                 :ok
               end
             )

    assert_receive {:record_event, attrs}
    assert attrs.log_name == RelayHealthEventRouter.gateway_saturation_log_name()
    assert attrs.metadata["relay_health_kind"] == "gateway_saturation_denial"
    assert attrs.metadata["limit_kind"] == "gateway"
    assert attrs.metadata["limit"] == 32
    assert attrs.message =~ "gateway-2"

    assert_receive {:broadcast_event, event}
    assert event.log_name == RelayHealthEventRouter.gateway_saturation_log_name()
  end

  test "records a structured viewer idle termination event" do
    test_pid = self()

    assert :ok =
             RelayHealthEventRouter.record_viewer_idle_termination(
               %{
                 relay_boundary: "core_elx",
                 relay_session_id: "relay-3",
                 gateway_id: "gateway-3",
                 camera_source_id: "camera-3",
                 close_reason: "viewer idle timeout",
                 termination_kind: "viewer_idle"
               },
               record_event: fn attrs, _actor ->
                 send(test_pid, {:record_event, attrs})
                 {:ok, attrs}
               end,
               broadcast_event: fn event ->
                 send(test_pid, {:broadcast_event, event})
                 :ok
               end
             )

    assert_receive {:record_event, attrs}
    assert attrs.log_name == RelayHealthEventRouter.viewer_idle_log_name()
    assert attrs.status == "Success"
    assert attrs.metadata["relay_health_kind"] == "viewer_idle_termination"
    assert attrs.metadata["termination_kind"] == "viewer_idle"
    assert attrs.status_detail == "viewer idle timeout"

    assert_receive {:broadcast_event, event}
    assert event.log_name == RelayHealthEventRouter.viewer_idle_log_name()
  end
end
