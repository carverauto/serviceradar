defmodule ServiceRadarWebNGWeb.Api.CameraRelaySessionControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.TestSupport.CameraRelaySessionManagerStub

  setup %{conn: conn} do
    previous_manager =
      Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager)

    previous_open_result =
      Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_open_result)

    previous_close_result =
      Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_close_result)

    previous_fetcher =
      Application.get_env(:serviceradar_web_ng, :camera_relay_session_fetcher)

    previous_test_pid =
      Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_test_pid)

    previous_webrtc_enabled =
      Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled)

    previous_webrtc_ice_servers =
      Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_ice_servers)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      CameraRelaySessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_test_pid,
      self()
    )

    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled, true)

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_ice_servers,
      [%{urls: ["stun:stun.example.com:3478"]}]
    )

    on_exit(fn ->
      restore_env(:camera_relay_session_manager, previous_manager)
      restore_env(:camera_relay_session_manager_open_result, previous_open_result)
      restore_env(:camera_relay_session_manager_close_result, previous_close_result)
      restore_env(:camera_relay_session_fetcher, previous_fetcher)
      restore_env(:camera_relay_session_manager_test_pid, previous_test_pid)
      restore_env(:camera_relay_webrtc_enabled, previous_webrtc_enabled)
      restore_env(:camera_relay_webrtc_ice_servers, previous_webrtc_ice_servers)
    end)

    user = admin_user_fixture()
    {:ok, token, _claims} = Guardian.create_access_token(user)

    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

    %{conn: conn}
  end

  describe "POST /api/camera-relay-sessions" do
    test "opens a relay session for a viewer-scoped device view", %{conn: _conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()
      relay_session_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: camera_source_id,
           stream_profile_id: stream_profile_id,
           agent_id: "agent-1",
           gateway_id: "gateway-1",
           status: :opening,
           viewer_count: 0,
           lease_expires_at: DateTime.from_unix!(1_800_000_000),
           inserted_at: DateTime.from_unix!(1_800_000_000),
           updated_at: DateTime.from_unix!(1_800_000_000)
         }}
      )

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/camera-relay-sessions", %{
          "camera_source_id" => camera_source_id,
          "stream_profile_id" => stream_profile_id
        })

      body = json_response(conn, 201)

      assert body["data"]["id"] == relay_session_id
      assert body["data"]["status"] == "opening"
      assert body["data"]["playback_state"] == "pending"
      assert body["data"]["viewer_count"] == 0
      assert body["data"]["agent_id"] == "agent-1"
      assert body["data"]["termination_kind"] == nil
      assert body["data"]["preferred_playback_transport"] == "websocket_h264_annexb_webcodecs"

      assert body["data"]["available_playback_transports"] == [
               "websocket_h264_annexb_webcodecs",
               "websocket_h264_annexb_jmuxer_mse"
             ]

      assert body["data"]["playback_codec_hint"] == "h264"
      assert body["data"]["playback_container_hint"] == "annexb"

      assert body["data"]["viewer_stream_path"] ==
               "/v1/camera-relay-sessions/#{relay_session_id}/stream"

      assert body["data"]["webrtc_enabled"] == true
      assert body["data"]["webrtc_playback_transport"] == "membrane_webrtc"

      assert body["data"]["webrtc_signaling_path"] ==
               "/api/camera-relay-sessions/#{relay_session_id}/webrtc/session"

      assert body["data"]["webrtc_ice_servers"] == [%{"urls" => ["stun:stun.example.com:3478"]}]

      assert_receive {:open_session, ^camera_source_id, ^stream_profile_id, opts}
      assert match?(%Scope{}, opts[:scope])
    end

    test "returns 400 when camera_source_id is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/camera-relay-sessions", %{"stream_profile_id" => Ecto.UUID.generate()})
      body = json_response(conn, 400)

      assert body["error"] == "invalid_request"
      assert body["message"] =~ "camera_source_id"
    end

    test "returns 409 when the assigned agent is offline", %{conn: conn} do
      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        {:error, {:agent_offline, "agent-1"}}
      )

      conn =
        post(conn, ~p"/api/camera-relay-sessions", %{
          "camera_source_id" => Ecto.UUID.generate(),
          "stream_profile_id" => Ecto.UUID.generate()
        })

      body = json_response(conn, 409)
      assert body["error"] == "agent_offline"
    end
  end

  describe "POST /api/camera-relay-sessions/:id/close" do
    test "closes a relay session", %{conn: conn} do
      relay_session_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_close_result,
        {:ok,
         %{
           id: relay_session_id,
           camera_source_id: Ecto.UUID.generate(),
           stream_profile_id: Ecto.UUID.generate(),
           agent_id: "agent-2",
           gateway_id: "gateway-2",
           status: :closing,
           termination_kind: "manual_stop",
           viewer_count: 0,
           close_reason: "viewer disconnected",
           updated_at: DateTime.from_unix!(1_800_000_100)
         }}
      )

      conn =
        post(conn, ~p"/api/camera-relay-sessions/#{relay_session_id}/close", %{
          "reason" => "viewer disconnected"
        })

      body = json_response(conn, 200)

      assert body["data"]["id"] == relay_session_id
      assert body["data"]["status"] == "closing"
      assert body["data"]["playback_state"] == "closing"
      assert body["data"]["viewer_count"] == 0
      assert body["data"]["close_reason"] == "viewer disconnected"
      assert body["data"]["termination_kind"] == "manual_stop"
      assert body["data"]["preferred_playback_transport"] == "websocket_h264_annexb_webcodecs"

      assert body["data"]["viewer_stream_path"] ==
               "/v1/camera-relay-sessions/#{relay_session_id}/stream"

      assert body["data"]["webrtc_enabled"] == true
      assert body["data"]["webrtc_playback_transport"] == "membrane_webrtc"

      assert_receive {:close_session, ^relay_session_id, opts}
      assert opts[:reason] == "viewer disconnected"
      assert match?(%Scope{}, opts[:scope])
    end

    test "returns 400 for an invalid relay session id", %{conn: conn} do
      conn = post(conn, ~p"/api/camera-relay-sessions/not-a-uuid/close", %{})
      body = json_response(conn, 400)

      assert body["error"] == "invalid_request"
      assert body["message"] =~ "valid UUID"
    end
  end

  describe "GET /api/camera-relay-sessions/:id" do
    test "returns relay session status for authenticated viewers", %{conn: _conn} do
      viewer = viewer_user_fixture()
      {:ok, token, _claims} = Guardian.create_access_token(viewer)

      relay_session_id = Ecto.UUID.generate()
      camera_source_id = Ecto.UUID.generate()
      stream_profile_id = Ecto.UUID.generate()

      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn session_id, opts ->
          send(self(), {:fetch_session, session_id, opts})

          {:ok,
           %{
             id: relay_session_id,
             camera_source_id: camera_source_id,
             stream_profile_id: stream_profile_id,
             agent_id: "agent-3",
             gateway_id: "gateway-3",
             status: :active,
             viewer_count: 2,
             media_ingest_id: "core-media-1",
             updated_at: DateTime.from_unix!(1_800_000_200)
           }}
        end
      )

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/camera-relay-sessions/#{relay_session_id}")

      body = json_response(conn, 200)

      assert body["data"]["id"] == relay_session_id
      assert body["data"]["status"] == "active"
      assert body["data"]["playback_state"] == "ready"
      assert body["data"]["viewer_count"] == 2
      assert body["data"]["agent_id"] == "agent-3"
      assert body["data"]["termination_kind"] == nil
      assert body["data"]["preferred_playback_transport"] == "websocket_h264_annexb_webcodecs"

      assert body["data"]["available_playback_transports"] == [
               "websocket_h264_annexb_webcodecs",
               "websocket_h264_annexb_jmuxer_mse"
             ]

      assert body["data"]["viewer_stream_path"] ==
               "/v1/camera-relay-sessions/#{relay_session_id}/stream"

      assert body["data"]["webrtc_enabled"] == true
      assert body["data"]["webrtc_playback_transport"] == "membrane_webrtc"

      assert_receive {:fetch_session, ^relay_session_id, opts}
      assert match?(%Scope{}, opts[:scope])
    end

    test "returns 400 for an invalid relay session id", %{conn: conn} do
      conn = get(conn, ~p"/api/camera-relay-sessions/not-a-uuid")
      body = json_response(conn, 400)

      assert body["error"] == "invalid_request"
      assert body["message"] =~ "valid UUID"
    end

    test "returns 404 when the relay session is missing", %{conn: conn} do
      Application.put_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn _session_id, _opts -> {:ok, nil} end
      )

      conn = get(conn, ~p"/api/camera-relay-sessions/#{Ecto.UUID.generate()}")
      body = json_response(conn, 404)

      assert body["error"] == "relay_session_not_found"
    end
  end

  describe "authentication" do
    test "requires authentication for create" do
      conn =
        post(build_conn(), ~p"/api/camera-relay-sessions", %{
          "camera_source_id" => Ecto.UUID.generate(),
          "stream_profile_id" => Ecto.UUID.generate()
        })

      assert conn.status == 401
    end

    test "requires authentication for show" do
      conn = get(build_conn(), ~p"/api/camera-relay-sessions/#{Ecto.UUID.generate()}")
      assert conn.status == 401
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
