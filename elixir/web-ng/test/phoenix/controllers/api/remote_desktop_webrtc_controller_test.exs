defmodule ServiceRadarWebNGWeb.Api.RemoteDesktopWebRTCControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0]

  alias ServiceRadar.Edge.RemoteAccessSession
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.RemoteDesktopWebRTCSignalingManagerStub

  setup %{conn: conn} do
    previous_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)

    previous_ice_servers =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_ice_servers)

    previous_manager =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_signaling_manager)

    previous_create_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_create_result)

    previous_answer_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_answer_result)

    previous_candidate_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_candidate_result)

    previous_close_result =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_close_result)

    previous_fetcher = Application.get_env(:serviceradar_web_ng, :remote_access_session_fetcher)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_test_pid)

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_webrtc_ice_servers,
      [%{urls: ["stun:stun.example.com:3478"]}]
    )

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_webrtc_signaling_manager,
      RemoteDesktopWebRTCSignalingManagerStub
    )

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_test_pid, self())

    on_exit(fn ->
      restore_env(:remote_access_desktop_rdp_enabled, previous_enabled)
      restore_env(:remote_access_desktop_webrtc_ice_servers, previous_ice_servers)
      restore_env(:remote_access_desktop_webrtc_signaling_manager, previous_manager)
      restore_env(:remote_access_desktop_webrtc_create_result, previous_create_result)
      restore_env(:remote_access_desktop_webrtc_answer_result, previous_answer_result)
      restore_env(:remote_access_desktop_webrtc_candidate_result, previous_candidate_result)
      restore_env(:remote_access_desktop_webrtc_close_result, previous_close_result)
      restore_env(:remote_access_session_fetcher, previous_fetcher)
      restore_env(:remote_access_desktop_webrtc_test_pid, previous_test_pid)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts -> {:ok, desktop_session(requested_id, status: :active)} end
    )

    %{conn: conn, session_id: session_id}
  end

  test "creates a desktop webrtc signaling session", %{conn: conn, session_id: session_id} do
    viewer_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_webrtc_create_result,
      {:ok,
       %{
         viewer_session_id: viewer_session_id,
         signaling_state: "offer_created",
         offer_sdp: "v=0\r\n..."
       }}
    )

    conn = post(conn, ~p"/api/remote-access/sessions/#{session_id}/webrtc/session", %{})
    body = json_response(conn, 201)

    assert body["data"]["session_id"] == session_id
    assert body["data"]["viewer_session_id"] == viewer_session_id
    assert body["data"]["transport"] == "webrtc_desktop_media"
    assert body["data"]["signaling_state"] == "offer_created"
    assert body["data"]["offer_sdp"] == "v=0\r\n..."
    assert body["data"]["signaling_path"] == "/api/remote-access/sessions/#{session_id}/webrtc/session"
    assert body["data"]["ice_servers"] == [%{"urls" => ["stun:stun.example.com:3478"]}]

    assert_receive {:desktop_webrtc_create_session, ^session_id, opts}
    assert opts[:scope]
    assert opts[:ice_servers] == [%{urls: ["stun:stun.example.com:3478"]}]
  end

  test "submits a desktop webrtc answer", %{conn: conn, session_id: session_id} do
    viewer_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_webrtc_answer_result,
      {:ok, %{signaling_state: "answer_applied"}}
    )

    conn =
      post(
        conn,
        ~p"/api/remote-access/sessions/#{session_id}/webrtc/session/#{viewer_session_id}/answer",
        %{"sdp" => "v=0\r\nanswer"}
      )

    body = json_response(conn, 200)

    assert body["data"]["session_id"] == session_id
    assert body["data"]["signaling_state"] == "answer_applied"

    assert_receive {:desktop_webrtc_submit_answer, ^session_id, ^viewer_session_id, "v=0\r\nanswer", opts}
    assert opts[:scope]
  end

  test "adds a desktop webrtc ice candidate", %{conn: conn, session_id: session_id} do
    viewer_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_webrtc_candidate_result,
      {:ok, %{signaling_state: "candidate_buffered"}}
    )

    conn =
      post(
        conn,
        ~p"/api/remote-access/sessions/#{session_id}/webrtc/session/#{viewer_session_id}/candidates",
        %{"candidate" => "candidate:1 1 UDP 1234 10.0.0.1 4000 typ host"}
      )

    body = json_response(conn, 200)

    assert body["data"]["session_id"] == session_id
    assert body["data"]["signaling_state"] == "candidate_buffered"

    assert_receive {:desktop_webrtc_add_candidate, ^session_id, ^viewer_session_id,
                    %{"candidate" => "candidate:1 1 UDP 1234 10.0.0.1 4000 typ host"}, opts}

    assert opts[:scope]
  end

  test "returns 404 when RDP remote access is disabled", %{conn: conn, session_id: session_id} do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false)

    conn = post(conn, ~p"/api/remote-access/sessions/#{session_id}/webrtc/session", %{})
    body = json_response(conn, 404)

    assert body["error"] == "not_found"
    refute_receive {:desktop_webrtc_create_session, _session_id, _opts}
  end

  test "returns 422 for a non-RDP remote-access session", %{conn: conn, session_id: session_id} do
    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts -> {:ok, desktop_session(requested_id, protocol: :ssh, adapter: :ssh)} end
    )

    conn = post(conn, ~p"/api/remote-access/sessions/#{session_id}/webrtc/session", %{})
    body = json_response(conn, 422)

    assert body["error"] == "unsupported_remote_desktop_session"
    refute_receive {:desktop_webrtc_create_session, _session_id, _opts}
  end

  test "returns 409 while the desktop session is still activating", %{
    conn: conn,
    session_id: session_id
  } do
    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_session_fetcher,
      fn requested_id, _opts -> {:ok, desktop_session(requested_id, status: :opening)} end
    )

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_create_result, {:error, :not_found})

    conn = post(conn, ~p"/api/remote-access/sessions/#{session_id}/webrtc/session", %{})
    body = json_response(conn, 409)

    assert body["error"] == "remote_desktop_session_activating"
    assert body["message"] == "remote desktop session is still activating"
  end

  test "closes a desktop webrtc signaling session", %{conn: conn, session_id: session_id} do
    viewer_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :remote_access_desktop_webrtc_close_result,
      {:ok, %{viewer_session_id: viewer_session_id, signaling_state: "closed"}}
    )

    conn =
      delete(
        conn,
        ~p"/api/remote-access/sessions/#{session_id}/webrtc/session/#{viewer_session_id}"
      )

    body = json_response(conn, 200)

    assert body["data"]["session_id"] == session_id
    assert body["data"]["viewer_session_id"] == viewer_session_id
    assert body["data"]["signaling_state"] == "closed"

    assert_receive {:desktop_webrtc_close_session, ^session_id, ^viewer_session_id, opts}
    assert opts[:scope]
  end

  defp desktop_session(session_id, overrides) do
    defaults = %{
      id: session_id,
      device_uid: "windows-1",
      target_kind: :inventory_device,
      target_host: "windows-1.example.com",
      target_port: 3389,
      protocol: :rdp,
      adapter: :rdp,
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      credential_custody_mode: :user_present,
      status: :active,
      rbac_decision: :allowed,
      attach_expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
      idle_timeout_seconds: 900,
      absolute_timeout_seconds: 3600,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(RemoteAccessSession, Map.merge(defaults, Map.new(overrides)))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
