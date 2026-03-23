defmodule ServiceRadar.Camera.InventoryIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.InventoryIngestor

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
               profile_upsert: profile_upsert
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
               profile_upsert: profile_upsert
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
               profile_upsert: profile_upsert
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
               profile_upsert: profile_upsert
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
               profile_upsert: profile_upsert
             )

    assert_receive {:source_upsert, source_attrs}
    assert source_attrs.vendor_camera_id == "cam-3"
    refute_receive {:source_upsert, %{vendor_camera_id: nil}}
  end
end
