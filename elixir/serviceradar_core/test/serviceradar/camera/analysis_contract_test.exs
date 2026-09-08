defmodule ServiceRadar.Camera.AnalysisContractTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.AnalysisContract

  test "build_input normalizes bounded analysis worker input" do
    input =
      AnalysisContract.build_input(%{
        relay_session_id: "relay-1",
        branch_id: "branch-1",
        media_ingest_id: "core-media-1",
        sequence: "7",
        pts: "1000",
        dts: 500,
        codec: "h264",
        payload_format: "annexb",
        track_id: "video",
        keyframe: true,
        payload: <<1, 2, 3>>,
        policy: %{"sample_interval_ms" => "2000", "max_queue_len" => "16"}
      })

    assert input.schema == AnalysisContract.input_schema()
    assert input.relay_session_id == "relay-1"
    assert input.branch_id == "branch-1"
    assert input.sequence == 7
    assert input.pts == 1000
    assert input.dts == 500
    assert input.payload == <<1, 2, 3>>
    assert input.policy == %{sample_interval_ms: 2000, max_queue_len: 16}
  end

  test "normalize_result coerces worker outputs into the shared result contract" do
    observed_at = DateTime.from_naive!(~N[2026-03-24 12:34:56], "Etc/UTC")

    result =
      AnalysisContract.normalize_result(%{
        "relay_session_id" => "relay-1",
        "branch_id" => "branch-1",
        "worker_id" => "detector-1",
        "camera_source_id" => "camera-1",
        "camera_device_uid" => "device-1",
        "stream_profile_id" => "profile-1",
        "media_ingest_id" => "core-media-1",
        "sequence" => "9",
        "observed_at" => observed_at,
        "detection" => %{
          "kind" => "object_detection",
          "label" => "person",
          "confidence" => "0.88",
          "bbox" => %{"x" => 1},
          "attributes" => %{"zone" => "front"}
        },
        "metadata" => %{"pipeline" => "default"}
      })

    assert result.schema == AnalysisContract.result_schema()
    assert result.relay_session_id == "relay-1"
    assert result.branch_id == "branch-1"
    assert result.worker_id == "detector-1"
    assert result.sequence == 9
    assert result.observed_at == observed_at
    assert result.detection.kind == "object_detection"
    assert result.detection.label == "person"
    assert result.detection.confidence == 0.88
    assert result.detection.bbox == %{"x" => 1}
    assert result.detection.attributes == %{"zone" => "front"}
    assert result.metadata == %{"pipeline" => "default"}
  end

  test "transport helpers encode and decode bounded payloads for external workers" do
    input =
      AnalysisContract.build_input(%{
        relay_session_id: "relay-1",
        branch_id: "branch-1",
        codec: "h264",
        payload_format: "annexb",
        keyframe: true,
        payload: <<0, 255, 1, 2>>
      })

    encoded = AnalysisContract.encode_transport_input(input)

    assert encoded.payload_encoding == "base64"
    assert is_binary(encoded.payload)

    assert {:ok, decoded} = AnalysisContract.decode_transport_input(encoded)
    assert decoded.payload == <<0, 255, 1, 2>>
    assert decoded.relay_session_id == "relay-1"
    assert decoded.branch_id == "branch-1"
  end
end
