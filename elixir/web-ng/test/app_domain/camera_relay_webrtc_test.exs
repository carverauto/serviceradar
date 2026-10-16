defmodule ServiceRadarWebNG.CameraRelayWebRTCTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.WebRTC.IceCredentials
  alias ServiceRadar.WebRTC.IceCredentials.MintLimiter
  alias ServiceRadar.WebRTC.IceCredentials.StaticSecret
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.CameraRelayWebRTC
  alias ServiceRadarWebNG.TestSupport.CameraRelayWebRTCSignalingManagerStub

  @moduletag :db_free

  @stun %{urls: ["stun:stun.example.com:3478"]}
  @secret String.duplicate("x", 32)

  setup do
    web_keys = [
      :camera_relay_webrtc_enabled,
      :camera_relay_webrtc_ice_servers,
      :camera_relay_webrtc_signaling_manager,
      :camera_relay_webrtc_create_result,
      :camera_relay_webrtc_test_pid
    ]

    previous_web = Map.new(web_keys, &{&1, Application.get_env(:serviceradar_web_ng, &1)})
    previous_ice = Application.get_env(:serviceradar_core, IceCredentials)

    on_exit(fn ->
      Enum.each(previous_web, fn
        {key, nil} -> Application.delete_env(:serviceradar_web_ng, key)
        {key, value} -> Application.put_env(:serviceradar_web_ng, key, value)
      end)

      if is_nil(previous_ice),
        do: Application.delete_env(:serviceradar_core, IceCredentials),
        else: Application.put_env(:serviceradar_core, IceCredentials, previous_ice)
    end)

    # db_free runs do not start serviceradar_core, whose tree owns the limiter.
    if is_nil(Process.whereis(MintLimiter)), do: start_supervised!(MintLimiter)

    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_enabled, true)
    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_ice_servers, [@stun])

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_signaling_manager,
      CameraRelayWebRTCSignalingManagerStub
    )

    Application.put_env(:serviceradar_web_ng, :camera_relay_webrtc_test_pid, self())

    relay_session_id = Ecto.UUID.generate()
    viewer_session_id = Ecto.UUID.generate()

    Application.put_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_create_result,
      {:ok, %{viewer_session_id: viewer_session_id, signaling_state: "offer_created", offer_sdp: "v=0\r\n..."}}
    )

    %{
      relay_session_id: relay_session_id,
      viewer_session_id: viewer_session_id,
      scope: %Scope{user: %{id: Ecto.UUID.generate()}}
    }
  end

  test "returns TURN credentials minted for this viewer in the signaling session only", ctx do
    Application.put_env(:serviceradar_core, IceCredentials,
      backend: :static_secret,
      turn_urls: ["turn:turn.example.com:3478?transport=udp"],
      static_secret: [secret: @secret]
    )

    assert {:ok, %{ice_servers: [@stun, turn], ice_credentials: "minted"} = session} =
             CameraRelayWebRTC.create_session(ctx.relay_session_id, scope: ctx.scope)

    assert session.viewer_session_id == ctx.viewer_session_id
    assert turn.urls == ["turn:turn.example.com:3478?transport=udp"]
    assert [_expiry, digest] = String.split(turn.username, ":")

    assert digest ==
             IceCredentials.subject_digest({"camera_relay", ctx.relay_session_id, ctx.viewer_session_id})

    assert turn.credential == StaticSecret.turn_credential(@secret, turn.username)

    # core-elx mints its own peer credentials; the browser's never reach it.
    assert_receive {:webrtc_create_session, relay_session_id, opts}
    assert relay_session_id == ctx.relay_session_id
    assert opts[:ice_servers] == [@stun]

    # Page metadata stays credential-free for every viewer.
    assert CameraRelayWebRTC.metadata(ctx.relay_session_id).webrtc_ice_servers == [@stun]
  end

  test "falls back to the STUN-only list when credentials cannot be minted", ctx do
    missing = Path.join(System.tmp_dir!(), "camera-relay-turn-absent-#{System.unique_integer([:positive])}")

    for {config, status} <- [
          {[backend: :none], "not_configured"},
          {[backend: :static_secret, turn_urls: ["turn:t.example.com"], static_secret: [secret_file: missing]],
           "unavailable"}
        ] do
      Application.put_env(:serviceradar_core, IceCredentials, config)

      assert {:ok, %{ice_servers: [@stun], ice_credentials: ^status}} =
               CameraRelayWebRTC.create_session(ctx.relay_session_id, scope: ctx.scope)
    end
  end
end
