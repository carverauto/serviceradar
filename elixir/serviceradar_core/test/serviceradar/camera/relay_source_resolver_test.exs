defmodule ServiceRadar.Camera.RelaySourceResolverTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelaySourceResolver

  describe "resolve_start_payload/2" do
    test "returns payload unchanged when source_url is already present" do
      payload = %{
        relay_session_id: "relay-1",
        camera_source_id: Ecto.UUID.generate(),
        stream_profile_id: Ecto.UUID.generate(),
        source_url: "rtsp://camera.local/main"
      }

      assert {:ok, ^payload} = RelaySourceResolver.resolve_start_payload(payload)
    end

    test "sanitizes source_url already present in payload" do
      payload = %{
        relay_session_id: "relay-1",
        camera_source_id: Ecto.UUID.generate(),
        stream_profile_id: Ecto.UUID.generate(),
        source_url: "rtsps://camera.local/main?enableSrtp"
      }

      assert {:ok, resolved} = RelaySourceResolver.resolve_start_payload(payload)
      assert resolved.source_url == "rtsps://camera.local/main"
    end

    test "fills source fields from inventory fetcher when source_url is omitted" do
      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()

      fetcher = fn ^camera_source_id, ^stream_profile_id ->
        {:ok,
         %{
           source_url_override: "rtsp://camera.local/override",
           rtsp_transport: "tcp",
           codec_hint: "h264",
           container_hint: "annexb",
           metadata: %{"insecure_skip_verify" => true},
           camera_source: %{source_url: "rtsp://camera.local/fallback"}
         }}
      end

      assert {:ok, payload} =
               RelaySourceResolver.resolve_start_payload(
                 %{
                   relay_session_id: "relay-1",
                   camera_source_id: camera_source_id,
                   stream_profile_id: stream_profile_id
                 },
                 camera_profile_fetcher: fetcher
               )

      assert payload.source_url == "rtsp://camera.local/override"
      assert payload.rtsp_transport == "tcp"
      assert payload.codec_hint == "h264"
      assert payload.container_hint == "annexb"
      assert payload.insecure_skip_verify == true
    end

    test "fills insecure TLS option from camera source metadata" do
      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()

      fetcher = fn ^camera_source_id, ^stream_profile_id ->
        {:ok,
         %{
           source_url_override: nil,
           camera_source: %{
             source_url: "rtsps://camera.local/fallback",
             metadata: %{"insecure_skip_verify" => "true"}
           }
         }}
      end

      assert {:ok, payload} =
               RelaySourceResolver.resolve_start_payload(
                 %{
                   relay_session_id: "relay-1",
                   camera_source_id: camera_source_id,
                   stream_profile_id: stream_profile_id
                 },
                 camera_profile_fetcher: fetcher
               )

      assert payload.source_url == "rtsps://camera.local/fallback"
      assert payload.insecure_skip_verify == true
    end

    test "sanitizes enableSrtp when filling source fields from inventory fetcher" do
      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()

      fetcher = fn ^camera_source_id, ^stream_profile_id ->
        {:ok,
         %{
           source_url_override: "rtsps://camera.local/override?enableSrtp",
           rtsp_transport: "tcp",
           codec_hint: "h264",
           container_hint: "annexb",
           camera_source: %{source_url: "rtsps://camera.local/fallback?enableSrtp"}
         }}
      end

      assert {:ok, payload} =
               RelaySourceResolver.resolve_start_payload(
                 %{
                   relay_session_id: "relay-1",
                   camera_source_id: camera_source_id,
                   stream_profile_id: stream_profile_id
                 },
                 camera_profile_fetcher: fetcher
               )

      assert payload.source_url == "rtsps://camera.local/override"
    end

    test "returns a friendly error when inventory has no usable source_url" do
      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()

      fetcher = fn ^camera_source_id, ^stream_profile_id ->
        {:ok,
         %{
           source_url_override: nil,
           camera_source: %{source_url: nil}
         }}
      end

      assert {:error, "camera relay source_url is not available in inventory"} =
               RelaySourceResolver.resolve_start_payload(
                 %{
                   relay_session_id: "relay-1",
                   camera_source_id: camera_source_id,
                   stream_profile_id: stream_profile_id
                 },
                 camera_profile_fetcher: fetcher
               )
    end
  end
end
