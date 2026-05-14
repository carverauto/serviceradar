defmodule ServiceRadarAgentGateway.DesktopMediaServerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.DesktopMediaServer
  alias ServiceRadarAgentGateway.DesktopMediaSessionTracker
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaAdapterStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaIdentityResolverStub

  setup do
    previous_identity_resolver =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_identity_resolver)

    previous_tracker =
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_session_tracker_module)

    previous_state =
      DesktopMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

    :sys.replace_state(DesktopMediaSessionTracker, fn state ->
      Map.put(state, :sessions, %{})
    end)

    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_identity_resolver,
      CameraMediaIdentityResolverStub
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :desktop_media_session_tracker_module,
      DesktopMediaSessionTracker
    )

    on_exit(fn ->
      DesktopMediaSessionTracker
      |> :sys.get_state()
      |> clear_sessions()

      :sys.replace_state(DesktopMediaSessionTracker, fn _state -> previous_state end)

      restore_env(:desktop_media_identity_resolver, previous_identity_resolver)
      restore_env(:desktop_media_session_tracker_module, previous_tracker)
    end)

    :ok
  end

  test "opens, heartbeats, and closes a route-bound desktop media session" do
    stream = test_stream()

    open_response =
      DesktopMediaServer.open_desktop_media_session(
        %Desktopmedia.OpenDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-1",
          media_session_id: "media-server-1",
          agent_id: "agent-1",
          target_id: "target-1",
          route_id: "route-1",
          lease_token: "lease-server-1",
          requested_initial_credit_bytes: 4096,
          requested_max_chunk_bytes: 1024,
          encoding_hint: "srdp-dirty-rect"
        },
        stream
      )

    assert open_response.accepted == true
    assert open_response.media_session_id == "media-server-1"
    assert open_response.media_ingest_id != ""
    assert open_response.initial_credit_bytes == 4096
    assert open_response.max_chunk_bytes == 1024
    assert open_response.max_ack_credit_bytes > 0

    heartbeat_response =
      DesktopMediaServer.heartbeat(
        %Desktopmedia.DesktopMediaHeartbeat{
          desktop_session_id: "desktop-server-1",
          media_session_id: "media-server-1",
          media_ingest_id: open_response.media_ingest_id,
          agent_id: "agent-1",
          last_sequence: 9,
          sent_bytes: 2048,
          received_credit_bytes: 1024,
          viewer_count: 1
        },
        stream
      )

    assert heartbeat_response.accepted == true
    assert heartbeat_response.lease_expires_at_unix > 0

    close_response =
      DesktopMediaServer.close_desktop_media_session(
        %Desktopmedia.CloseDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-1",
          media_session_id: "media-server-1",
          media_ingest_id: open_response.media_ingest_id,
          agent_id: "agent-1",
          reason: "test done"
        },
        stream
      )

    assert close_response.closed == true
    assert DesktopMediaSessionTracker.fetch_session("desktop-server-1") == nil
  end

  test "rejects desktop media open when certificate identity does not match requested agent" do
    assert_raise GRPC.RPCError, ~r/component identity mismatch/, fn ->
      DesktopMediaServer.open_desktop_media_session(
        %Desktopmedia.OpenDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-mismatch-1",
          media_session_id: "media-server-mismatch-1",
          agent_id: "agent-other",
          target_id: "target-1",
          route_id: "route-1",
          lease_token: "lease-server-mismatch-1"
        },
        test_stream()
      )
    end
  end

  test "rejects heartbeat for the wrong media session binding" do
    stream = test_stream()

    open_response =
      DesktopMediaServer.open_desktop_media_session(
        %Desktopmedia.OpenDesktopMediaSessionRequest{
          desktop_session_id: "desktop-server-media-mismatch-1",
          media_session_id: "media-server-owner-1",
          agent_id: "agent-1",
          target_id: "target-1",
          route_id: "route-1",
          lease_token: "lease-server-media-mismatch-1"
        },
        stream
      )

    assert open_response.accepted == true

    assert_raise GRPC.RPCError, ~r/media_session_id mismatch/, fn ->
      DesktopMediaServer.heartbeat(
        %Desktopmedia.DesktopMediaHeartbeat{
          desktop_session_id: "desktop-server-media-mismatch-1",
          media_session_id: "media-other",
          agent_id: "agent-1"
        },
        stream
      )
    end
  end

  test "fails closed when desktop media stream forwarding is not enabled" do
    assert_raise GRPC.RPCError, ~r/desktop media stream forwarding is not enabled/, fn ->
      DesktopMediaServer.stream_desktop_media([], test_stream())
    end
  end

  defp test_stream do
    %{adapter: CameraMediaAdapterStub, payload: :test}
  end

  defp clear_sessions(state) do
    Map.put(state, :sessions, %{})
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
