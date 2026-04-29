defmodule ServiceRadar.Camera.InventoryIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.InventoryIngestor

  describe "merge_local_relay_metadata/2" do
    test "preserves local relay metadata when incoming plugin metadata omits it" do
      assert %{"source" => "protect-bootstrap", "insecure_skip_verify" => true} =
               InventoryIngestor.merge_local_relay_metadata(
                 %{"insecure_skip_verify" => true},
                 %{"source" => "protect-bootstrap"}
               )
    end

    test "keeps incoming relay metadata when the plugin provides it" do
      assert %{"insecure_skip_verify" => false} =
               InventoryIngestor.merge_local_relay_metadata(
                 %{"insecure_skip_verify" => true},
                 %{"insecure_skip_verify" => false}
               )
    end
  end

  test "upserts normalized sources and profiles from plugin camera descriptors" do
    parent = self()

    source_upsert = fn attrs, _actor ->
      send(parent, {:source_upsert, attrs})
      {:ok, %{id: Ecto.UUID.generate()}}
    end

    profile_upsert = fn attrs, _actor ->
      send(parent, {:profile_upsert, attrs})
      {:ok, attrs}
    end

    payload = %{
      "camera_descriptors" => [
        %{
          "device_uid" => "device-1",
          "vendor" => "axis",
          "camera_id" => "cam-1",
          "name" => "Front Door",
          "source_url" => "rtsp://camera.local/front",
          "stream_profiles" => [
            %{
              "name" => "main",
              "profile_id" => "main-1",
              "rtsp_transport" => "tcp",
              "codec" => "h264"
            }
          ]
        }
      ]
    }

    status = %{agent_id: "agent-1", gateway_id: "gateway-1"}

    assert :ok =
             InventoryIngestor.ingest(payload, status,
               source_upsert: source_upsert,
               profile_upsert: profile_upsert,
               device_sync: fn _, _, _, _ -> :ok end
             )

    assert_receive {:source_upsert, source_attrs}
    assert source_attrs.device_uid == "device-1"
    assert source_attrs.vendor == "axis"
    assert source_attrs.vendor_camera_id == "cam-1"
    assert source_attrs.assigned_agent_id == "agent-1"
    assert source_attrs.assigned_gateway_id == "gateway-1"

    assert_receive {:profile_upsert, profile_attrs}
    assert profile_attrs.profile_name == "main"
    assert profile_attrs.vendor_profile_id == "main-1"
    assert profile_attrs.rtsp_transport == "tcp"
    assert profile_attrs.codec_hint == "h264"
  end

  test "creates a default profile when descriptors omit explicit stream profiles" do
    parent = self()

    source_upsert = fn attrs, _actor ->
      send(parent, {:source_upsert, attrs})
      {:ok, %{id: Ecto.UUID.generate()}}
    end

    profile_upsert = fn attrs, _actor ->
      send(parent, {:profile_upsert, attrs})
      {:ok, attrs}
    end

    payload = %{
      "cameras" => [
        %{
          "device_uid" => "device-2",
          "vendor" => "protect",
          "camera_id" => "cam-2",
          "source_url" => "rtsp://camera.local/protect",
          "codec_hint" => "h264"
        }
      ]
    }

    assert :ok =
             InventoryIngestor.ingest(payload, %{},
               source_upsert: source_upsert,
               profile_upsert: profile_upsert,
               device_sync: fn _, _, _, _ -> :ok end
             )

    assert_receive {:source_upsert, _}
    assert_receive {:profile_upsert, profile_attrs}
    assert profile_attrs.profile_name == "default"
    assert profile_attrs.codec_hint == "h264"
  end

  test "ingests camera descriptors embedded in plugin details JSON" do
    parent = self()

    source_upsert = fn attrs, _actor ->
      send(parent, {:source_upsert, attrs})
      {:ok, %{id: Ecto.UUID.generate()}}
    end

    profile_upsert = fn attrs, _actor ->
      send(parent, {:profile_upsert, attrs})
      {:ok, attrs}
    end

    payload = %{
      "status" => "OK",
      "details" =>
        Jason.encode!(%{
          "camera_descriptors" => [
            %{
              "device_uid" => "device-embedded-1",
              "vendor" => "axis",
              "camera_id" => "cam-embedded-1",
              "display_name" => "Embedded Camera",
              "stream_profiles" => [
                %{
                  "profile_name" => "main",
                  "source_url_override" => "rtsp://camera.local/embedded-main",
                  "codec_hint" => "h264"
                }
              ]
            }
          ]
        })
    }

    assert :ok =
             InventoryIngestor.ingest(payload, %{},
               source_upsert: source_upsert,
               profile_upsert: profile_upsert,
               device_sync: fn _, _, _, _ -> :ok end
             )

    assert_receive {:source_upsert, source_attrs}
    assert source_attrs.device_uid == "device-embedded-1"
    assert source_attrs.vendor_camera_id == "cam-embedded-1"

    assert_receive {:profile_upsert, profile_attrs}
    assert profile_attrs.profile_name == "main"
    assert profile_attrs.source_url_override == "rtsp://camera.local/embedded-main"
    assert profile_attrs.codec_hint == "h264"
  end

  test "derives axis camera descriptors from legacy plugin details JSON" do
    parent = self()

    source_upsert = fn attrs, _actor ->
      send(parent, {:source_upsert, attrs})
      {:ok, %{id: Ecto.UUID.generate()}}
    end

    profile_upsert = fn attrs, _actor ->
      send(parent, {:profile_upsert, attrs})
      {:ok, attrs}
    end

    payload = %{
      "status" => "OK",
      "details" =>
        Jason.encode!(%{
          "camera_host" => "10.0.0.50",
          "device_info" => %{
            "SerialNumber" => "axis-serial-1",
            "ProductFullName" => "AXIS P1465-LE"
          },
          "streams" => [
            %{
              "id" => "main",
              "protocol" => "rtsp",
              "url" => "rtsp://10.0.0.50/axis-media/media.amp?videocodec=h264"
            }
          ],
          "metadata" => %{"plugin" => "axis-camera"}
        })
    }

    assert :ok =
             InventoryIngestor.ingest(payload, %{},
               source_upsert: source_upsert,
               profile_upsert: profile_upsert,
               device_sync: fn _, _, _, _ -> :ok end
             )

    assert_receive {:source_upsert, source_attrs}
    assert source_attrs.device_uid == "axis-serial-1"
    assert source_attrs.vendor == "axis"
    assert source_attrs.vendor_camera_id == "axis-serial-1"
    assert source_attrs.source_url == "rtsp://10.0.0.50/axis-media/media.amp?videocodec=h264"

    assert_receive {:profile_upsert, profile_attrs}
    assert profile_attrs.profile_name == "main"
    assert profile_attrs.rtsp_transport == "tcp"
    assert profile_attrs.codec_hint == "h264"
  end

  test "derives camera descriptors from generic device enrichment and resolves canonical device uid" do
    parent = self()

    source_upsert = fn attrs, _actor ->
      send(parent, {:source_upsert, attrs})
      {:ok, %{id: Ecto.UUID.generate()}}
    end

    profile_upsert = fn attrs, _actor ->
      send(parent, {:profile_upsert, attrs})
      {:ok, attrs}
    end

    resolve_device_uid = fn descriptor, status, _actor ->
      send(parent, {:resolve_device_uid, descriptor, status})
      "device-canonical-42"
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
                "url" => "rtsp://10.0.0.50/axis-media/media.amp?videocodec=h264",
                "auth_mode" => "digest",
                "credential_reference_id" => "secretref:password:axis-42"
              }
            ],
            "source" => %{
              "plugin_id" => "axis-camera",
              "camera_host" => "10.0.0.50"
            }
          }
        })
    }

    assert :ok =
             InventoryIngestor.ingest(payload, %{agent_id: "agent-42", gateway_id: "gateway-42"},
               source_upsert: source_upsert,
               profile_upsert: profile_upsert,
               resolve_device_uid: resolve_device_uid,
               device_sync: fn _, _, _, _ -> :ok end
             )

    assert_receive {:resolve_device_uid, descriptor, status}
    assert descriptor["vendor"] == "axis"
    assert descriptor["camera_id"] == "axis-serial-42"
    assert status.agent_id == "agent-42"

    assert_receive {:source_upsert, source_attrs}
    assert source_attrs.device_uid == "device-canonical-42"
    assert source_attrs.vendor == "axis"
    assert source_attrs.vendor_camera_id == "axis-serial-42"
    assert source_attrs.source_url == "rtsp://10.0.0.50/axis-media/media.amp?videocodec=h264"
    assert source_attrs.assigned_agent_id == "agent-42"
    assert source_attrs.assigned_gateway_id == "gateway-42"

    assert_receive {:profile_upsert, profile_attrs}
    assert profile_attrs.profile_name == "main"
    assert profile_attrs.rtsp_transport == "tcp"
    assert profile_attrs.codec_hint == "h264"
    assert profile_attrs.metadata["auth_mode"] == "digest"
    assert profile_attrs.metadata["credential_reference_id"] == "secretref:password:axis-42"
    assert profile_attrs.metadata["protocol"] == "rtsp"
  end

  test "replaces explicit vendor device uid when identity resolution returns a canonical uid" do
    parent = self()

    source_upsert = fn attrs, _actor ->
      send(parent, {:source_upsert, attrs})
      {:ok, %{id: Ecto.UUID.generate()}}
    end

    profile_upsert = fn attrs, _actor ->
      send(parent, {:profile_upsert, attrs})
      {:ok, attrs}
    end

    resolve_device_uid = fn descriptor, status, _actor ->
      send(parent, {:resolve_device_uid, descriptor, status})
      "sr:camera-canonical-1"
    end

    device_sync = fn descriptor, status, observed_at, _actor ->
      send(parent, {:device_sync, descriptor, status, observed_at})
      :ok
    end

    observed_at = ~U[2026-03-25 20:00:00Z]

    payload = %{
      "camera_descriptors" => [
        %{
          "device_uid" => "aa:bb:cc:dd:ee:ff",
          "vendor" => "ubiquiti",
          "camera_id" => "protect-camera-1",
          "display_name" => "Front Door",
          "ip" => "192.168.1.90",
          "identity" => %{"mac" => "aa:bb:cc:dd:ee:ff"},
          "metadata" => %{"camera_host" => "192.168.1.90"},
          "stream_profiles" => [%{"profile_name" => "High", "codec_hint" => "h264"}]
        }
      ]
    }

    assert :ok =
             InventoryIngestor.ingest(payload, %{gateway_id: "gateway-1"},
               observed_at: observed_at,
               source_upsert: source_upsert,
               profile_upsert: profile_upsert,
               resolve_device_uid: resolve_device_uid,
               device_sync: device_sync
             )

    assert_receive {:resolve_device_uid, descriptor, status}
    assert descriptor["device_uid"] == "aa:bb:cc:dd:ee:ff"
    assert status.gateway_id == "gateway-1"

    assert_receive {:device_sync, synced_descriptor, _status, ^observed_at}
    assert synced_descriptor["device_uid"] == "sr:camera-canonical-1"

    assert_receive {:source_upsert, source_attrs}
    assert source_attrs.device_uid == "sr:camera-canonical-1"

    assert_receive {:profile_upsert, profile_attrs}
    assert profile_attrs.profile_name == "High"
  end

  test "extracts generic device enrichment descriptors from top-level payloads" do
    payload = %{
      "device_enrichment" => %{
        "identity" => %{"serial" => "protect-serial-1"},
        "camera" => %{"vendor" => "Ubiquiti", "display_name" => "South Lot"},
        "streams" => [
          %{
            "id" => "high",
            "url" => "rtsp://protect.local/live/high?videocodec=h265",
            "auth_mode" => "api_key",
            "insecure_skip_verify" => true
          }
        ],
        "source" => %{
          "plugin_id" => "unifi-protect",
          "camera_host" => "protect.local",
          "insecure_skip_verify" => true
        }
      }
    }

    assert [
             %{
               "vendor" => "ubiquiti",
               "camera_id" => "protect-serial-1",
               "display_name" => "South Lot",
               "source_url" => "rtsp://protect.local/live/high?videocodec=h265",
               "stream_profiles" => [
                 %{
                   "profile_name" => "high",
                   "metadata" => %{"insecure_skip_verify" => true}
                 }
               ],
               "metadata" => %{
                 "plugin_id" => "unifi-protect",
                 "insecure_skip_verify" => true
               }
             }
           ] = InventoryIngestor.extract_camera_descriptors(payload)
  end

  test "derives camera availability and activity state from plugin events" do
    parent = self()
    observed_at = ~U[2026-03-23 15:45:10Z]

    source_upsert = fn attrs, _actor ->
      send(parent, {:source_upsert, attrs})
      {:ok, %{id: Ecto.UUID.generate()}}
    end

    profile_upsert = fn attrs, _actor ->
      send(parent, {:profile_upsert, attrs})
      {:ok, attrs}
    end

    payload = %{
      "status" => "CRITICAL",
      "summary" => "camera stream unavailable",
      "camera_descriptors" => [
        %{
          "device_uid" => "device-state-1",
          "vendor" => "axis",
          "camera_id" => "cam-state-1",
          "display_name" => "Dock Camera",
          "stream_profiles" => [
            %{
              "profile_name" => "main",
              "profile_id" => "main-state-1",
              "codec_hint" => "h264"
            }
          ]
        }
      ],
      "events" => [
        %{
          "id" => "evt-camera-state-1",
          "time" => "2026-03-23T15:45:00Z",
          "class_uid" => 1008,
          "category_uid" => 1,
          "type_uid" => 100_801,
          "activity_id" => 1,
          "message" => "AXIS event: tns1:VideoSource/VideoLost",
          "unmapped" => %{
            "axis_ws_payload" => %{
              "params" => %{
                "notification" => %{
                  "topic" => "tns1:VideoSource/VideoLost"
                }
              }
            }
          }
        }
      ]
    }

    assert :ok =
             InventoryIngestor.ingest(payload, %{gateway_id: "gateway-state-1"},
               observed_at: observed_at,
               source_upsert: source_upsert,
               profile_upsert: profile_upsert,
               device_sync: fn _, _, _, _ -> :ok end
             )

    assert_receive {:source_upsert, source_attrs}
    assert source_attrs.availability_status == "unavailable"
    assert source_attrs.availability_reason == "AXIS event: tns1:VideoSource/VideoLost"
    assert source_attrs.last_activity_at == ~U[2026-03-23 15:45:00Z]
    assert source_attrs.last_event_at == ~U[2026-03-23 15:45:00Z]
    assert source_attrs.last_event_type == "tns1:VideoSource/VideoLost"
    assert source_attrs.last_event_message == "AXIS event: tns1:VideoSource/VideoLost"

    assert_receive {:profile_upsert, profile_attrs}
    assert profile_attrs.profile_name == "main"
  end

  test "skips malformed camera descriptors without failing ingestion" do
    parent = self()

    source_upsert = fn attrs, _actor ->
      send(parent, {:source_upsert, attrs})
      {:ok, %{id: Ecto.UUID.generate()}}
    end

    profile_upsert = fn attrs, _actor ->
      send(parent, {:profile_upsert, attrs})
      {:ok, attrs}
    end

    payload = %{
      "camera_descriptors" => [
        %{"name" => "missing-identifiers"},
        %{"device_uid" => "device-3", "vendor" => "axis", "camera_id" => "cam-3"}
      ]
    }

    assert :ok =
             InventoryIngestor.ingest(payload, %{},
               source_upsert: source_upsert,
               profile_upsert: profile_upsert,
               device_sync: fn _, _, _, _ -> :ok end
             )

    assert_receive {:source_upsert, source_attrs}
    assert source_attrs.vendor_camera_id == "cam-3"
    refute_receive {:source_upsert, %{vendor_camera_id: nil}}
  end
end
