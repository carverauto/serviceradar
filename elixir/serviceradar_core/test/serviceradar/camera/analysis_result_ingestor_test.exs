defmodule ServiceRadar.Camera.AnalysisResultIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.AnalysisContract
  alias ServiceRadar.Camera.AnalysisResultIngestor

  test "normalizes worker detections into OCSF event attrs with relay provenance" do
    parent = self()

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, attrs}
    end

    broadcast_event = fn event ->
      send(parent, {:broadcast_event, event})
      :ok
    end

    observed_at = DateTime.from_naive!(~N[2026-03-24 10:42:00.123456], "Etc/UTC")

    result = %{
      schema: AnalysisContract.result_schema(),
      relay_session_id: "relay-analysis-1",
      branch_id: "analysis-branch-1",
      worker_id: "object-detector-1",
      camera_source_id: "camera-source-1",
      camera_device_uid: "device-camera-1",
      stream_profile_id: "profile-main-1",
      media_ingest_id: "core-media-analysis",
      sequence: 33,
      observed_at: observed_at,
      detection: %{
        kind: "object_detection",
        label: "person",
        confidence: 0.98,
        bbox: %{"x" => 100, "y" => 50, "width" => 40, "height" => 80},
        attributes: %{"zone" => "north-lobby"}
      },
      metadata: %{"pipeline" => "default"},
      raw_payload: %{"vendor" => "demo"}
    }

    assert :ok =
             AnalysisResultIngestor.ingest(
               result,
               record_event: record_event,
               broadcast_event: broadcast_event
             )

    assert_receive {:record_event, attrs}
    assert attrs.message == "Camera analysis detection: person"
    assert attrs.metadata["relay_session_id"] == "relay-analysis-1"
    assert attrs.metadata["analysis_branch_id"] == "analysis-branch-1"
    assert attrs.metadata["analysis_worker_id"] == "object-detector-1"
    assert attrs.metadata["camera_source_id"] == "camera-source-1"
    assert attrs.metadata["camera_device_uid"] == "device-camera-1"
    assert attrs.metadata["stream_profile_id"] == "profile-main-1"
    assert attrs.metadata["sequence"] == 33
    assert attrs.metadata["pipeline"] == "default"
    assert attrs.device["uid"] == "device-camera-1"
    assert attrs.log_name == "camera.analysis.detection"
    assert attrs.log_provider == "object-detector-1"
    assert attrs.unmapped["detection"]["label"] == "person"
    assert Enum.any?(attrs.observables, &(&1["value"] == "relay-analysis-1"))

    assert_receive {:broadcast_event, broadcast_event_attrs}
    assert broadcast_event_attrs.metadata["analysis_worker_id"] == "object-detector-1"
  end
end
