defmodule ServiceRadarCoreElx.RemoteDesktop.MediaSessionManagerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCoreElx.RemoteDesktop.MediaSessionManager

  defmodule OfferProviderStub do
    @moduledoc false

    def add_webrtc_viewer(session_id, viewer_session_id, signaling, opts) do
      send(
        test_pid(),
        {:offer_provider_add_viewer, session_id, viewer_session_id, signaling, opts}
      )

      :ok
    end

    def remove_webrtc_viewer(session_id, viewer_session_id, _opts) do
      send(test_pid(), {:offer_provider_remove_viewer, session_id, viewer_session_id})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_media_manager_test_pid)
    end
  end

  defmodule ControlForwarderStub do
    @moduledoc false

    def forward_browser_control(session, viewer_session_id, frame, opts) do
      send(test_pid(), {:control_forwarder_frame, session, viewer_session_id, frame, opts})

      Application.get_env(
        :serviceradar_core_elx,
        :remote_desktop_media_manager_control_forwarder_result,
        :ok
      )
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_media_manager_test_pid)
    end
  end

  setup do
    previous_test_pid =
      Application.get_env(:serviceradar_core_elx, :remote_desktop_media_manager_test_pid)

    previous_forwarder_result =
      Application.get_env(
        :serviceradar_core_elx,
        :remote_desktop_media_manager_control_forwarder_result
      )

    Application.put_env(:serviceradar_core_elx, :remote_desktop_media_manager_test_pid, self())

    on_exit(fn ->
      restore_env(:remote_desktop_media_manager_test_pid, previous_test_pid)

      restore_env(
        :remote_desktop_media_manager_control_forwarder_result,
        previous_forwarder_result
      )
    end)

    :ok
  end

  test "fails closed for WebRTC viewers when the offer provider is disabled" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})

    assert {:error, "desktop media plane is not available"} =
             MediaSessionManager.add_webrtc_viewer(
               "desktop-manager-closed-1",
               "viewer-1",
               %{pid: self()},
               server: server,
               offer_provider: false
             )
  end

  test "tracks configured viewers and waits for browser credit before granting frame credit" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})

    assert :ok =
             MediaSessionManager.add_webrtc_viewer(
               "desktop-manager-viewer-1",
               "viewer-1",
               %{pid: self()},
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
              credit_bytes: 0,
              pause: false
            }} =
             MediaSessionManager.forward_frame(
               "desktop-manager-viewer-1",
               frame("desktop-manager-viewer-1"),
               server: server,
               session: session("desktop-manager-viewer-1")
             )

    assert %{
             viewer_count: 1,
             last_sequence: 4,
             forwarded_bytes: 5,
             forwarded_frames: 1,
             pending_credit_bytes: 0,
             last_frame: %{bytes: 5, sequence: 4, payload_family: "dirty_rect"}
           } = MediaSessionManager.fetch_session("desktop-manager-viewer-1", server: server)

    assert {:ok, %{pending_credit_bytes: 1024, last_accepted_sequence: 4, paused: false}} =
             MediaSessionManager.apply_browser_ack(
               "desktop-manager-viewer-1",
               "viewer-1",
               %{
                 "media_session_id" => "media-desktop-manager-viewer-1",
                 "last_accepted_seq" => 4,
                 "credit_bytes" => 1024
               },
               server: server
             )

    assert {:ok, %Desktopmedia.DesktopMediaAck{credit_bytes: 1024, pause: false}} =
             MediaSessionManager.forward_frame(
               "desktop-manager-viewer-1",
               frame("desktop-manager-viewer-1", sequence: 5),
               server: server,
               session: session("desktop-manager-viewer-1")
             )

    assert %{pending_credit_bytes: 0} =
             MediaSessionManager.fetch_session("desktop-manager-viewer-1", server: server)

    assert :ok =
             MediaSessionManager.remove_webrtc_viewer("desktop-manager-viewer-1", "viewer-1", server: server)

    assert MediaSessionManager.fetch_session("desktop-manager-viewer-1", server: server) == nil
    assert_receive {:offer_provider_remove_viewer, "desktop-manager-viewer-1", "viewer-1"}
  end

  test "retains active siblings but deletes all state after the last viewer leaves" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})
    session_id = "desktop-manager-viewer-lifecycle-1"

    for viewer_id <- ["viewer-1", "viewer-2"] do
      assert :ok =
               MediaSessionManager.add_webrtc_viewer(
                 session_id,
                 viewer_id,
                 %{pid: self()},
                 server: server,
                 offer_provider: OfferProviderStub,
                 transport: "webrtc_desktop_media"
               )
    end

    assert :ok = MediaSessionManager.remove_webrtc_viewer(session_id, "viewer-1", server: server)
    assert %{viewer_count: 1} = MediaSessionManager.fetch_session(session_id, server: server)

    assert :ok = MediaSessionManager.remove_webrtc_viewer(session_id, "viewer-2", server: server)
    assert MediaSessionManager.fetch_session(session_id, server: server) == nil
  end

  test "terminal cleanup closes every provider and deletes session accounting" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})
    session_id = "desktop-manager-terminal-1"

    for viewer_id <- ["viewer-1", "viewer-2"] do
      assert :ok =
               MediaSessionManager.add_webrtc_viewer(
                 session_id,
                 viewer_id,
                 %{pid: self()},
                 server: server,
                 offer_provider: OfferProviderStub,
                 transport: "webrtc_desktop_media"
               )
    end

    assert :ok = MediaSessionManager.close_session(session_id, server: server)
    assert_receive {:offer_provider_remove_viewer, ^session_id, "viewer-1"}
    assert_receive {:offer_provider_remove_viewer, ^session_id, "viewer-2"}
    assert MediaSessionManager.fetch_session(session_id, server: server) == nil
    assert :ok = MediaSessionManager.close_session(session_id, server: server)
  end

  test "accepts frames without viewers but marks acknowledgement paused" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})

    assert {:ok,
            %Desktopmedia.DesktopMediaAck{
              last_accepted_sequence: 4,
              credit_bytes: 0,
              pause: true
            }} =
             MediaSessionManager.forward_frame(
               "desktop-manager-paused-1",
               frame("desktop-manager-paused-1"),
               server: server,
               session: session("desktop-manager-paused-1")
             )

    assert %{
             viewer_count: 0,
             forwarded_bytes: 5,
             pending_credit_bytes: 0,
             paused: true,
             last_frame: %{bytes: 5}
           } = MediaSessionManager.fetch_session("desktop-manager-paused-1", server: server)
  end

  test "rejects stale or mismatched browser acknowledgements" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})

    assert :ok =
             MediaSessionManager.add_webrtc_viewer(
               "desktop-manager-ack-reject-1",
               "viewer-1",
               %{pid: self()},
               server: server,
               offer_provider: OfferProviderStub,
               transport: "webrtc_desktop_media"
             )

    assert {:ok, %Desktopmedia.DesktopMediaAck{}} =
             MediaSessionManager.forward_frame(
               "desktop-manager-ack-reject-1",
               frame("desktop-manager-ack-reject-1"),
               server: server,
               session: session("desktop-manager-ack-reject-1")
             )

    assert {:error, :media_session_mismatch} =
             MediaSessionManager.apply_browser_ack(
               "desktop-manager-ack-reject-1",
               "viewer-1",
               %{
                 "media_session_id" => "media-other",
                 "last_accepted_seq" => 4,
                 "credit_bytes" => 10
               },
               server: server
             )

    assert {:ok, %{pending_credit_bytes: 10}} =
             MediaSessionManager.apply_browser_ack(
               "desktop-manager-ack-reject-1",
               "viewer-1",
               %{
                 "media_session_id" => "media-desktop-manager-ack-reject-1",
                 "last_accepted_seq" => 4,
                 "credit_bytes" => 10
               },
               server: server
             )

    assert {:error, :duplicate_credit_ack} =
             MediaSessionManager.apply_browser_ack(
               "desktop-manager-ack-reject-1",
               "viewer-1",
               %{
                 "media_session_id" => "media-desktop-manager-ack-reject-1",
                 "last_accepted_seq" => 4,
                 "credit_bytes" => 1
               },
               server: server
             )

    assert {:error, :replayed_ack} =
             MediaSessionManager.apply_browser_ack(
               "desktop-manager-ack-reject-1",
               "viewer-1",
               %{
                 "media_session_id" => "media-desktop-manager-ack-reject-1",
                 "last_accepted_seq" => 3,
                 "credit_bytes" => 0
               },
               server: server
             )
  end

  test "accepts session-bound browser control frames from attached viewers" do
    server = unique_server_name()

    start_supervised!(
      {MediaSessionManager,
       name: server, control_forwarder: ControlForwarderStub, control_forwarder_opts: [route: "route-1"]}
    )

    assert :ok =
             MediaSessionManager.add_webrtc_viewer(
               "desktop-manager-control-1",
               "viewer-1",
               %{pid: self()},
               server: server,
               offer_provider: OfferProviderStub,
               transport: "webrtc_desktop_media"
             )

    assert_receive {:offer_provider_add_viewer, "desktop-manager-control-1", "viewer-1", %{pid: pid}, _opts}

    assert pid == self()

    frame = %{
      "session_id" => "desktop-manager-control-1",
      "protocol" => "rdp",
      "frame_type" => "desktop.input",
      "input" => %{
        "kind" => "pointer",
        "x" => 100,
        "y" => 120,
        "button" => "left",
        "down" => true
      }
    }

    safe_frame = %{
      "session_id" => "desktop-manager-control-1",
      "protocol" => "rdp",
      "frame_type" => "desktop.input",
      "input" => %{"kind" => "pointer", "x" => 100, "y" => 120, "down" => true}
    }

    assert {:ok,
            %{
              control_frame_count: 1,
              last_control_frame: ^safe_frame
            }} =
             MediaSessionManager.apply_browser_control(
               "desktop-manager-control-1",
               "viewer-1",
               frame,
               server: server
             )

    assert_receive {:control_forwarder_frame, session, "viewer-1", ^frame, [route: "route-1"]}
    assert session.session_id == "desktop-manager-control-1"
    assert session.viewer_count == 1

    assert %{
             control_frame_count: 1,
             last_control_frame: ^safe_frame
           } = MediaSessionManager.fetch_session("desktop-manager-control-1", server: server)
  end

  test "fails browser control frames closed when the configured forwarder rejects them" do
    server = unique_server_name()

    Application.put_env(
      :serviceradar_core_elx,
      :remote_desktop_media_manager_control_forwarder_result,
      {:error, :route_unavailable}
    )

    start_supervised!({MediaSessionManager, name: server, control_forwarder: ControlForwarderStub})

    assert :ok =
             MediaSessionManager.add_webrtc_viewer(
               "desktop-manager-control-forward-reject-1",
               "viewer-1",
               %{
                 pid: self()
               },
               server: server,
               offer_provider: OfferProviderStub,
               transport: "webrtc_desktop_media"
             )

    assert_receive {:offer_provider_add_viewer, "desktop-manager-control-forward-reject-1", "viewer-1", %{pid: pid},
                    _opts}

    assert pid == self()

    frame = %{
      "session_id" => "desktop-manager-control-forward-reject-1",
      "protocol" => "rdp",
      "frame_type" => "desktop.input",
      "input" => %{"kind" => "key", "key" => "Enter", "down" => true}
    }

    assert {:error, :route_unavailable} =
             MediaSessionManager.apply_browser_control(
               "desktop-manager-control-forward-reject-1",
               "viewer-1",
               frame,
               server: server
             )

    assert_receive {:control_forwarder_frame, session, "viewer-1", ^frame, []}
    assert session.session_id == "desktop-manager-control-forward-reject-1"

    assert %{control_frame_count: 0, last_control_frame: nil} =
             MediaSessionManager.fetch_session("desktop-manager-control-forward-reject-1",
               server: server
             )
  end

  test "rejects browser control frames with wrong viewer, session, or shape" do
    server = unique_server_name()
    start_supervised!({MediaSessionManager, name: server})

    assert :ok =
             MediaSessionManager.add_webrtc_viewer(
               "desktop-manager-control-reject-1",
               "viewer-1",
               %{pid: self()},
               server: server,
               offer_provider: OfferProviderStub,
               transport: "webrtc_desktop_media"
             )

    valid_frame = %{
      "session_id" => "desktop-manager-control-reject-1",
      "protocol" => "rdp",
      "frame_type" => "desktop.input",
      "input" => %{"kind" => "focus", "focused" => true}
    }

    assert {:error, :viewer_session_not_found} =
             MediaSessionManager.apply_browser_control(
               "desktop-manager-control-reject-1",
               "viewer-missing",
               valid_frame,
               server: server
             )

    assert {:error, :invalid_control_frame} =
             MediaSessionManager.apply_browser_control(
               "desktop-manager-control-reject-1",
               "viewer-1",
               %{valid_frame | "session_id" => "other-session"},
               server: server
             )

    assert {:error, :invalid_control_frame} =
             MediaSessionManager.apply_browser_control(
               "desktop-manager-control-reject-1",
               "viewer-1",
               %{valid_frame | "input" => %{"kind" => "clipboard"}},
               server: server
             )

    assert %{control_frame_count: 0, last_control_frame: nil} =
             MediaSessionManager.fetch_session("desktop-manager-control-reject-1", server: server)
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
    frame(desktop_session_id, [])
  end

  defp frame(desktop_session_id, opts) do
    %Desktopmedia.DesktopMediaFrameChunk{
      desktop_session_id: desktop_session_id,
      media_session_id: "media-#{desktop_session_id}",
      media_ingest_id: "ingest-#{desktop_session_id}",
      agent_id: "agent-1",
      sequence: Keyword.get(opts, :sequence, 4),
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
