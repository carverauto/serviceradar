defmodule ServiceRadarWebNGWeb.Api.CameraRelayWebRTCControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0]

  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.CameraRelayWebRTCSignalingManagerStub

  setup %{conn: conn} do
    previous_enabled = Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled)
    previous_ice_servers = Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_ice_servers)

    previous_manager =
      Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_signaling_manager)

    previous_create_result =
      Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_create_result)

    previous_answer_result =
      Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_answer_result)

    previous_candidate_result =
      Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_candidate_result)

    previous_close_result =
      Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_close_result)

    previous_fetcher = Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetcher)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_test_pid)

    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled, true)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_ice_servers,
      [%{urls: ["stun:stun.example.com:3478"]}]
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_signaling_manager,
      CameraRelayWebRTCSignalingManagerStub
    )

    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_test_pid, self())

    on_exit(fn ->
      restore_env(:camera_relay_webrtc_enabled, previous_enabled)
      restore_env(:camera_relay_webrtc_ice_servers, previous_ice_servers)
      restore_env(:camera_relay_webrtc_signaling_manager, previous_manager)
      restore_env(:camera_relay_webrtc_create_result, previous_create_result)
      restore_env(:camera_relay_webrtc_answer_result, previous_answer_result)
      restore_env(:camera_relay_webrtc_candidate_result, previous_candidate_result)
      restore_env(:camera_relay_webrtc_close_result, previous_close_result)
      restore_env(:camera_relay_session_fetcher, previous_fetcher)
      restore_env(:camera_relay_webrtc_test_pid, previous_test_pid)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    relay_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_fetcher,
      fn session_id, _opts ->
        {:ok,
         %{
           id: session_id,
           camera_source_id: Ecto.UUID.generate(),
           stream_profile_id: Ecto.UUID.generate(),
           status: :active,
           media_ingest_id: "core-media-1",
           viewer_count: 1
         }}
      end
    )

    %{conn: conn, relay_session_id: relay_session_id}
  end

  test "creates a relay-scoped webrtc signaling session", %{conn: conn, relay_session_id: relay_session_id} do
    viewer_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_create_result,
      {:ok,
       %{
         viewer_session_id: viewer_session_id,
         signaling_state: "offer_created",
         offer_sdp: "v=0\r\n..."
       }}
    )

    conn = post(conn, ~p"/api/camera-relay-sessions/#{relay_session_id}/webrtc/session", %{})
    body = json_response(conn, 201)

    assert body["data"]["relay_session_id"] == relay_session_id
    assert body["data"]["viewer_session_id"] == viewer_session_id
    assert body["data"]["transport"] == "membrane_webrtc"
    assert body["data"]["signaling_state"] == "offer_created"
    assert body["data"]["offer_sdp"] == "v=0\r\n..."
    assert body["data"]["signaling_path"] == "/api/camera-relay-sessions/#{relay_session_id}/webrtc/session"
    assert body["data"]["ice_servers"] == [%{"urls" => ["stun:stun.example.com:3478"]}]

    assert_receive {:webrtc_create_session, ^relay_session_id, opts}
    assert opts[:scope]
    assert opts[:ice_servers] == [%{urls: ["stun:stun.example.com:3478"]}]
  end

  test "submits a relay-scoped webrtc answer", %{conn: conn, relay_session_id: relay_session_id} do
    viewer_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_answer_result,
      {:ok, %{signaling_state: "answer_applied"}}
    )

    conn =
      post(
        conn,
        ~p"/api/camera-relay-sessions/#{relay_session_id}/webrtc/session/#{viewer_session_id}/answer",
        %{"sdp" => "v=0\r\nanswer"}
      )

    body = json_response(conn, 200)

    assert body["data"]["relay_session_id"] == relay_session_id
    assert body["data"]["signaling_state"] == "answer_applied"

    assert_receive {:webrtc_submit_answer, ^relay_session_id, ^viewer_session_id, "v=0\r\nanswer", opts}
    assert opts[:scope]
  end

  test "adds a relay-scoped webrtc ice candidate", %{conn: conn, relay_session_id: relay_session_id} do
    viewer_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_candidate_result,
      {:ok, %{signaling_state: "candidate_buffered"}}
    )

    conn =
      post(
        conn,
        ~p"/api/camera-relay-sessions/#{relay_session_id}/webrtc/session/#{viewer_session_id}/candidates",
        %{"candidate" => "candidate:1 1 UDP 1234 10.0.0.1 4000 typ host"}
      )

    body = json_response(conn, 200)

    assert body["data"]["relay_session_id"] == relay_session_id
    assert body["data"]["signaling_state"] == "candidate_buffered"

    assert_receive {:webrtc_add_candidate, ^relay_session_id, ^viewer_session_id,
                    "candidate:1 1 UDP 1234 10.0.0.1 4000 typ host", opts}

    assert opts[:scope]
  end

  test "returns 422 when webrtc playback is disabled", %{conn: conn, relay_session_id: relay_session_id} do
    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled, false)

    conn = post(conn, ~p"/api/camera-relay-sessions/#{relay_session_id}/webrtc/session", %{})
    body = json_response(conn, 422)

    assert body["error"] == "webrtc_unavailable"
  end

  test "returns 409 while the relay session is still activating", %{
    conn: conn,
    relay_session_id: relay_session_id
  } do
    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_fetcher,
      fn session_id, _opts ->
        {:ok,
         %{
           id: session_id,
           camera_source_id: Ecto.UUID.generate(),
           stream_profile_id: Ecto.UUID.generate(),
           status: :opening,
           media_ingest_id: nil,
           viewer_count: 0
         }}
      end
    )

    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_create_result, {:error, :not_found})

    conn = post(conn, ~p"/api/camera-relay-sessions/#{relay_session_id}/webrtc/session", %{})
    body = json_response(conn, 409)

    assert body["error"] == "relay_session_activating"
    assert body["message"] == "relay session is still activating"
  end

  test "closes a relay-scoped webrtc signaling session", %{conn: conn, relay_session_id: relay_session_id} do
    viewer_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_close_result,
      {:ok, %{viewer_session_id: viewer_session_id, signaling_state: "closed"}}
    )

    conn =
      delete(
        conn,
        ~p"/api/camera-relay-sessions/#{relay_session_id}/webrtc/session/#{viewer_session_id}"
      )

    body = json_response(conn, 200)

    assert body["data"]["relay_session_id"] == relay_session_id
    assert body["data"]["viewer_session_id"] == viewer_session_id
    assert body["data"]["signaling_state"] == "closed"

    assert_receive {:webrtc_close_session, ^relay_session_id, ^viewer_session_id, opts}
    assert opts[:scope]
  end
end
