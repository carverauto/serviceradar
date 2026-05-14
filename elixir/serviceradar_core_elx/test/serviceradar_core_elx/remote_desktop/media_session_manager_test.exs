defmodule ServiceRadarCoreElx.RemoteDesktop.MediaSessionManagerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.RemoteDesktop.MediaSessionManager

  defmodule OfferProviderStub do
    @moduledoc false

    def add_webrtc_viewer(session_id, viewer_session_id, signaling, opts) do
      send(test_pid(), {:offer_provider_add_viewer, session_id, viewer_session_id, signaling, opts})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_media_manager_test_pid)
    end
  end

  setup do
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :remote_desktop_media_manager_test_pid)
    Application.put_env(:serviceradar_core_elx, :remote_desktop_media_manager_test_pid, self())

    on_exit(fn ->
      restore_env(:remote_desktop_media_manager_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "fails closed for WebRTC viewers until an offer provider is configured" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})

    assert {:error, "desktop media plane is not available"} =
             MediaSessionManager.add_webrtc_viewer("desktop-manager-closed-1", "viewer-1", %{pid: self()}, server: server)
  end

  test "tracks configured viewers and returns unpaused frame acknowledgements" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})

    assert :ok =
             MediaSessionManager.add_webrtc_viewer("desktop-manager-viewer-1", "viewer-1", %{pid: self()},
               server: server,
               offer_provider: OfferProviderStub,
               transport: "webrtc_desktop_media"
             )

    assert_receive {:offer_provider_add_viewer, "desktop-manager-viewer-1", "viewer-1", %{pid: pid}, opts}
    assert pid == self()
    assert opts[:transport] == "webrtc_desktop_media"

    assert {:ok,
            %Desktopmedia.DesktopMediaAck{
              desktop_session_id: "desktop-manager-viewer-1",
              media_session_id: "media-desktop-manager-viewer-1",
              media_ingest_id: "ingest-desktop-manager-viewer-1",
              gateway_id: "gateway-1",
              last_accepted_sequence: 4,
              credit_bytes: 5,
              pause: false
            }} =
             MediaSessionManager.forward_frame("desktop-manager-viewer-1", frame("desktop-manager-viewer-1"),
               server: server,
               session: session("desktop-manager-viewer-1")
             )

    assert %{
             viewer_count: 1,
             last_sequence: 4,
             forwarded_bytes: 5,
             forwarded_frames: 1,
             last_frame: %{bytes: 5, sequence: 4, payload_family: "dirty_rect"}
           } = MediaSessionManager.fetch_session("desktop-manager-viewer-1", server: server)

    assert :ok = MediaSessionManager.remove_webrtc_viewer("desktop-manager-viewer-1", "viewer-1", server: server)
    assert %{viewer_count: 0} = MediaSessionManager.fetch_session("desktop-manager-viewer-1", server: server)
  end

  test "accepts frames without viewers but marks acknowledgement paused" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})

    assert {:ok,
            %Desktopmedia.DesktopMediaAck{
              last_accepted_sequence: 4,
              credit_bytes: 5,
              pause: true
            }} =
             MediaSessionManager.forward_frame("desktop-manager-paused-1", frame("desktop-manager-paused-1"),
               server: server,
               session: session("desktop-manager-paused-1")
             )

    assert %{
             viewer_count: 0,
             forwarded_bytes: 5,
             last_frame: %{bytes: 5}
           } = MediaSessionManager.fetch_session("desktop-manager-paused-1", server: server)
  end

  defp session(desktop_session_id) do
    %{
      desktop_session_id: desktop_session_id,
      media_session_id: "media-#{desktop_session_id}",
      media_ingest_id: "ingest-#{desktop_session_id}",
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }
  end

  defp frame(desktop_session_id) do
    %Desktopmedia.DesktopMediaFrameChunk{
      desktop_session_id: desktop_session_id,
      media_session_id: "media-#{desktop_session_id}",
      media_ingest_id: "ingest-#{desktop_session_id}",
      agent_id: "agent-1",
      sequence: 4,
      payload_family: "dirty_rect",
      encoding: "raw_rgba",
      metadata: <<1, 2>>,
      payload: <<3, 4, 5>>
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
  defp unique_server_name, do: :"remote_desktop_media_manager_test_#{System.unique_integer([:positive])}"
end
