defmodule ServiceRadar.Camera.EventIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.EventIngestor

  test "records correlated camera ocsf events with source and stream profile metadata" do
    parent = self()

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, attrs}
    end

    load_source = fn _descriptor, _actor ->
      %{
        source_id: "camera-source-1",
        device_uid: "device-camera-1",
        display_name: "North Lobby Camera",
        vendor: "axis",
        vendor_camera_id: "cam-axis-1",
        assigned_agent_id: "agent-camera-1",
        assigned_gateway_id: "gateway-camera-1",
        stream_profile_ids: ["profile-main-1", "profile-sub-1"],
        stream_profile_names: ["Main", "Substream"],
        plugin_id: "axis-camera"
      }
    end

    payload = %{
      "status" => "OK",
      "summary" => "camera event received",
      "observed_at" => "2026-03-23T16:00:00Z",
      "camera_descriptors" => [
        %{
          "device_uid" => "device-camera-1",
          "vendor" => "axis",
          "camera_id" => "cam-axis-1",
          "display_name" => "North Lobby Camera",
          "stream_profiles" => [
            %{"profile_name" => "Main", "profile_id" => "profile-main-1"},
            %{"profile_name" => "Substream", "profile_id" => "profile-sub-1"}
          ]
        }
      ],
      "events" => [
        %{
          "id" => "camera-event-1",
          "time" => "2026-03-23T15:59:45Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "activity_name" => "Create",
          "severity_id" => 1,
          "severity" => "Informational",
          "message" => "AXIS event: tns1:VideoSource/Motion",
          "metadata" => %{"source" => "axis"},
          "unmapped" => %{
            "axis_ws_payload" => %{
              "params" => %{
                "notification" => %{
                  "topic" => "tns1:VideoSource/Motion"
                }
              }
            }
          }
        }
      ]
    }

    assert :ok =
             EventIngestor.ingest(
               payload,
               %{agent_id: "agent-camera-1", gateway_id: "gateway-camera-1"},
               record_event: record_event,
               load_source: load_source
             )

    assert_receive {:record_event, attrs}
    assert attrs.id == "camera-event-1"
    assert attrs.device["uid"] == "device-camera-1"
    assert attrs.device["name"] == "North Lobby Camera"
    assert attrs.metadata["camera_source_id"] == "camera-source-1"
    assert attrs.metadata["camera_device_uid"] == "device-camera-1"
    assert attrs.metadata["camera_stream_profile_ids"] == ["profile-main-1", "profile-sub-1"]
    assert attrs.metadata["assigned_agent_id"] == "agent-camera-1"
    assert attrs.metadata["assigned_gateway_id"] == "gateway-camera-1"
    assert attrs.unmapped["camera_source_id"] == "camera-source-1"
    assert attrs.unmapped["camera_device_uid"] == "device-camera-1"
    assert attrs.log_provider == "axis-camera"
  end

  test "correlates events using camera descriptors derived from generic device enrichment" do
    parent = self()

    record_event = fn attrs, _actor ->
      send(parent, {:record_event, attrs})
      {:ok, attrs}
    end

    load_source = fn descriptor, _actor ->
      send(parent, {:load_source, descriptor})

      %{
        source_id: "camera-source-42",
        device_uid: "device-camera-42",
        display_name: "Dock Camera",
        vendor: "axis",
        vendor_camera_id: "axis-serial-42",
        assigned_agent_id: "agent-camera-42",
        assigned_gateway_id: "gateway-camera-42",
        stream_profile_ids: ["profile-main-42"],
        stream_profile_names: ["main"],
        plugin_id: "axis-camera"
      }
    end

    payload = %{
      "status" => "OK",
      "details" =>
        Jason.encode!(%{
          "camera_host" => "10.0.0.50",
          "device_enrichment" => %{
            "identity" => %{
              "serial" => "axis-serial-42",
              "mac" => "AA:BB:CC:DD:EE:FF"
            },
            "camera" => %{
              "vendor" => "AXIS",
              "model" => "P1465-LE"
            },
            "streams" => [
              %{
                "id" => "main",
                "protocol" => "rtsp",
                "url" => "rtsp://10.0.0.50/axis-media/media.amp?videocodec=h264"
              }
            ],
            "source" => %{
              "plugin_id" => "axis-camera",
              "camera_host" => "10.0.0.50"
            }
          }
        }),
      "events" => [
        %{
          "id" => "camera-event-42",
          "time" => "2026-03-23T15:59:45Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "activity_name" => "Create",
          "severity_id" => 1,
          "severity" => "Informational",
          "message" => "AXIS event: tns1:VideoSource/Motion",
          "unmapped" => %{
            "camera_id" => "axis-serial-42",
            "axis_ws_payload" => %{
              "params" => %{
                "notification" => %{
                  "topic" => "tns1:VideoSource/Motion"
                }
              }
            }
          }
        }
      ]
    }

    assert :ok =
             EventIngestor.ingest(
               payload,
               %{agent_id: "agent-camera-42", gateway_id: "gateway-camera-42"},
               record_event: record_event,
               load_source: load_source
             )

    assert_receive {:load_source, descriptor}
    assert descriptor["vendor"] == "axis"
    assert descriptor["camera_id"] == "axis-serial-42"

    assert_receive {:record_event, attrs}
    assert attrs.id == "camera-event-42"
    assert attrs.metadata["camera_source_id"] == "camera-source-42"
    assert attrs.metadata["camera_device_uid"] == "device-camera-42"
    assert attrs.log_provider == "axis-camera"
  end
end
