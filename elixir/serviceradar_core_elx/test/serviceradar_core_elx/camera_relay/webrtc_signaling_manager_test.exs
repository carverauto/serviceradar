defmodule ServiceRadarCoreElx.CameraRelay.WebRTCSignalingManagerTest do
  use ExUnit.Case, async: false

  alias Membrane.WebRTC.Signaling
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadar.WebRTC.IceCredentials
  alias ServiceRadar.WebRTC.IceCredentials.MintLimiter
  alias ServiceRadar.WebRTC.IceCredentials.StaticSecret
  alias ServiceRadarCoreElx.CameraRelay.WebRTCSignalingManager

  defmodule SessionTrackerStub do
    @moduledoc false
    def fetch_session(relay_session_id) do
      send(test_pid(), {:fetch_session, relay_session_id})

      case Application.get_env(:serviceradar_core_elx, :camera_relay_webrtc_fetch_result, :ok) do
        :ok -> {:ok, %{relay_session_id: relay_session_id, media_ingest_id: "core-media-1"}}
        other -> other
      end
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
    end
  end

  defmodule BareSessionTrackerStub do
    @moduledoc false

    def fetch_session(relay_session_id) do
      send(test_pid(), {:fetch_session, relay_session_id})
      %{relay_session_id: relay_session_id, media_ingest_id: "core-media-1"}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
    end
  end

  defmodule MissingSessionTrackerStub do
    @moduledoc false

    def fetch_session(relay_session_id) do
      send(test_pid(), {:fetch_session, relay_session_id})
      nil
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
    end
  end

  defmodule PipelineManagerStub do
    @moduledoc false

    def add_webrtc_viewer(relay_session_id, viewer_session_id, signaling, opts) do
      send(test_pid(), {:add_webrtc_viewer, relay_session_id, viewer_session_id})
      send(test_pid(), {:webrtc_sink_ice_servers, viewer_session_id, Keyword.fetch!(opts, :ice_servers)})
      :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())

      :ok =
        Signaling.signal(
          signaling,
          %{"type" => "sdp_offer", "data" => %{"type" => "offer", "sdp" => "v=0\r\nstub-offer"}}
        )

      :ok
    end

    def remove_webrtc_viewer(relay_session_id, viewer_session_id) do
      send(test_pid(), {:remove_webrtc_viewer, relay_session_id, viewer_session_id})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
    end
  end

  # Stands in for the WebRTC sink on the far side of the signaling channel:
  # sends the offer and reports every message the manager signals to it.
  defmodule SinkPeerPipelineManagerStub do
    @moduledoc false

    def add_webrtc_viewer(relay_session_id, viewer_session_id, signaling, _opts) do
      test_pid = Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
      send(test_pid, {:add_webrtc_viewer, relay_session_id, viewer_session_id})

      spawn(fn ->
        :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())

        :ok =
          Signaling.signal(
            signaling,
            %{"type" => "sdp_offer", "data" => %{"type" => "offer", "sdp" => "v=0\r\nstub-offer"}}
          )

        send(test_pid, {:sink_peer, self()})
        forward_signals(test_pid, signaling)
      end)

      :ok
    end

    def remove_webrtc_viewer(relay_session_id, viewer_session_id) do
      test_pid = Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
      send(test_pid, {:remove_webrtc_viewer, relay_session_id, viewer_session_id})
      :ok
    end

    defp forward_signals(test_pid, signaling) do
      receive do
        {:membrane_webrtc_signaling, _pid, message, _metadata} ->
          send(test_pid, {:sink_received, message})
          forward_signals(test_pid, signaling)

        # Trickles candidates the way the real sink does after its offer. The
        # :sys round trip returns once Signaling has forwarded them, so the
        # manager holds them before the test's next call.
        {:trickle, candidates} ->
          Enum.each(candidates, &Signaling.signal(signaling, %{"type" => "ice_candidate", "data" => &1}))
          _ = :sys.get_state(signaling.pid)
          send(test_pid, :trickled)
          forward_signals(test_pid, signaling)
      end
    end
  end

  # Registers like the real WebRTC sink (an element peer), so when this process
  # dies the Signaling process stops with its crash reason, exactly as it does
  # when a viewer's sink crashes in the relay pipeline.
  defmodule ElementPeerPipelineManagerStub do
    @moduledoc false

    def add_webrtc_viewer(relay_session_id, viewer_session_id, signaling, _opts) do
      test_pid = Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)

      element =
        spawn(fn ->
          :ok = Signaling.register_element(signaling)

          :ok =
            Signaling.signal(signaling, %ExWebRTC.SessionDescription{type: :offer, sdp: "v=0\r\nstub-offer"})

          receive do
            :never -> :ok
          end
        end)

      send(test_pid, {:element_peer, viewer_session_id, element})
      send(test_pid, {:add_webrtc_viewer, relay_session_id, viewer_session_id})
      :ok
    end

    def remove_webrtc_viewer(relay_session_id, viewer_session_id) do
      test_pid = Application.fetch_env!(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)
      send(test_pid, {:remove_webrtc_viewer, relay_session_id, viewer_session_id})
      :ok
    end
  end

  setup do
    previous_fetch_result = Application.get_env(:serviceradar_core_elx, :camera_relay_webrtc_fetch_result)
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :camera_relay_webrtc_test_pid)

    Application.put_env(:serviceradar_core_elx, :camera_relay_webrtc_test_pid, self())
    :ok = RelayPubSub.subscribe_viewer_control()

    on_exit(fn ->
      restore_env(:camera_relay_webrtc_fetch_result, previous_fetch_result)
      restore_env(:camera_relay_webrtc_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "creates and closes relay-scoped viewer sessions owned by core-elx" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:ok,
            %{viewer_session_id: viewer_session_id, signaling_state: "offer_created", offer_sdp: "v=0\r\nstub-offer"}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:fetch_session, ^relay_session_id}
    assert_receive {:add_webrtc_viewer, ^relay_session_id, ^viewer_session_id}

    assert_receive {:camera_relay_viewer_join,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id, transport: "membrane_webrtc"}}

    assert {:ok, %{viewer_session_id: ^viewer_session_id, signaling_state: "closed"}} =
             WebRTCSignalingManager.close_session(relay_session_id, viewer_session_id, server: server_name)

    assert_receive {:camera_relay_viewer_leave,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id, reason: reason}}

    assert_receive {:remove_webrtc_viewer, ^relay_session_id, ^viewer_session_id}
    assert reason == "viewer closed webrtc signaling session"
  end

  test "configures the viewer's sink with TURN credentials minted for this peer" do
    secret = String.duplicate("p", 32)
    previous_ice_config = Application.get_env(:serviceradar_core, IceCredentials)

    Application.put_env(:serviceradar_core, IceCredentials,
      backend: :static_secret,
      turn_urls: ["turn:serviceradar-turn.example.svc:3478?transport=udp"],
      static_secret: [secret: secret]
    )

    on_exit(fn -> restore_core_env(IceCredentials, previous_ice_config) end)
    # `elixir -r` runs leave serviceradar_core, whose tree owns the limiter, down.
    if is_nil(Process.whereis(MintLimiter)), do: start_supervised!(MintLimiter)

    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()
    stun = %{urls: ["stun:stun.example.com:3478"]}

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name, ice_servers: [stun])

    assert_receive {:webrtc_sink_ice_servers, ^viewer_session_id, [^stun, turn]}
    assert turn.urls == ["turn:serviceradar-turn.example.svc:3478?transport=udp"]
    assert [_expiry, digest] = String.split(turn.username, ":")
    assert digest == IceCredentials.subject_digest({"camera_relay_peer", relay_session_id, viewer_session_id})
    assert turn.credential == StaticSecret.turn_credential(secret, turn.username)
  end

  test "mints a peer credential for every viewer of one relay when the shared actor would otherwise share a bucket" do
    secret = String.duplicate("p", 32)
    previous_ice_config = Application.get_env(:serviceradar_core, IceCredentials)

    Application.put_env(:serviceradar_core, IceCredentials,
      backend: :static_secret,
      turn_urls: ["turn:serviceradar-turn.example.svc:3478?transport=udp"],
      rate_limit: %{max_mints: 1, window_seconds: 60},
      static_secret: [secret: secret]
    )

    on_exit(fn -> restore_core_env(IceCredentials, previous_ice_config) end)
    if is_nil(Process.whereis(MintLimiter)), do: start_supervised!(MintLimiter)

    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()
    stun = %{urls: ["stun:stun.example.com:3478"]}

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: first_viewer}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name, ice_servers: [stun])

    assert {:ok, %{viewer_session_id: second_viewer}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name, ice_servers: [stun])

    assert_receive {:webrtc_sink_ice_servers, ^first_viewer, [^stun, first_turn]}
    assert_receive {:webrtc_sink_ice_servers, ^second_viewer, [^stun, second_turn]}
    assert first_turn.urls == ["turn:serviceradar-turn.example.svc:3478?transport=udp"]
    assert second_turn.urls == ["turn:serviceradar-turn.example.svc:3478?transport=udp"]

    assert [_expiry, first_digest] = String.split(first_turn.username, ":")
    assert [_expiry, second_digest] = String.split(second_turn.username, ":")

    assert first_digest ==
             IceCredentials.subject_digest({"camera_relay_peer", relay_session_id, first_viewer})

    assert second_digest ==
             IceCredentials.subject_digest({"camera_relay_peer", relay_session_id, second_viewer})

    refute first_digest == second_digest
  end

  test "expires idle viewer signaling sessions" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    manager_opts = [
      name: server_name,
      session_tracker: SessionTrackerStub,
      pipeline_manager: PipelineManagerStub,
      session_ttl_ms: 10
    ]

    start_supervised!({WebRTCSignalingManager, manager_opts})

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:camera_relay_viewer_join, %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id}},
                   100

    assert_receive {:camera_relay_viewer_leave,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id, reason: reason}},
                   250

    assert_receive {:remove_webrtc_viewer, ^relay_session_id, ^viewer_session_id}
    assert reason == "webrtc signaling session expired"
  end

  test "rejects signaling sessions for missing relay sessions" do
    Application.put_env(:serviceradar_core_elx, :camera_relay_webrtc_fetch_result, {:error, :not_found})
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:error, :not_found} =
             WebRTCSignalingManager.create_session(Ecto.UUID.generate(), server: server_name)
  end

  test "rejects nil relay sessions from the real tracker contract" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: MissingSessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:error, :not_found} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:fetch_session, ^relay_session_id}
  end

  test "accepts relay sessions from the real tracker contract" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: BareSessionTrackerStub,
       pipeline_manager: PipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:ok,
            %{viewer_session_id: viewer_session_id, signaling_state: "offer_created", offer_sdp: "v=0\r\nstub-offer"}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:fetch_session, ^relay_session_id}
    assert_receive {:add_webrtc_viewer, ^relay_session_id, ^viewer_session_id}
  end

  test "holds browser ICE candidates until the SDP answer and forwards them after it, in order" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       pipeline_manager: SinkPeerPipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    first = %{"candidate" => "candidate:1 1 UDP 2122252543 192.0.2.10 49152 typ host", "sdpMid" => "0"}
    second = %{"candidate" => "candidate:2 1 UDP 2122252542 192.0.2.11 49153 typ host", "sdpMid" => "0"}

    assert {:ok, _session} =
             WebRTCSignalingManager.add_ice_candidate(relay_session_id, viewer_session_id, first, server: server_name)

    assert {:ok, _session} =
             WebRTCSignalingManager.add_ice_candidate(relay_session_id, viewer_session_id, second, server: server_name)

    # The sink cannot apply a candidate without a remote description.
    refute_receive {:sink_received, %{"type" => "ice_candidate"}}, 100

    assert {:ok, %{signaling_state: "answer_applied"}} =
             WebRTCSignalingManager.submit_answer(relay_session_id, viewer_session_id, "v=0\r\nanswer",
               server: server_name
             )

    assert_receive {:sink_received, %{"type" => "sdp_answer"}}
    assert_receive {:sink_received, %{"type" => "ice_candidate", "data" => ^first}}
    assert_receive {:sink_received, %{"type" => "ice_candidate", "data" => ^second}}

    third = %{"candidate" => "candidate:3 1 UDP 2122252541 192.0.2.12 49154 typ host", "sdpMid" => "0"}

    assert {:ok, _session} =
             WebRTCSignalingManager.add_ice_candidate(relay_session_id, viewer_session_id, third, server: server_name)

    assert_receive {:sink_received, %{"type" => "ice_candidate", "data" => ^third}}
  end

  test "returns every ICE candidate the sink trickles after the offer, not only the latest" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    start_supervised!(
      {WebRTCSignalingManager,
       name: server_name,
       session_tracker: SessionTrackerStub,
       pipeline_manager: SinkPeerPipelineManagerStub,
       session_ttl_ms: 5_000}
    )

    assert {:ok, %{viewer_session_id: viewer_session_id, remote_ice_candidates: []}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:sink_peer, sink}

    host = %{"candidate" => "candidate:1 1 UDP 2122252543 192.0.2.20 40000 typ host", "sdpMid" => "0"}

    relay = %{
      "candidate" => "candidate:2 1 UDP 16777215 198.51.100.30 49200 typ relay raddr 192.0.2.20 rport 40000",
      "sdpMid" => "0"
    }

    send(sink, {:trickle, [host, relay]})
    assert_receive :trickled

    # A browser behind TURN can only reach the relay candidate, so losing it to
    # a later candidate leaves the viewer unable to connect.
    assert {:ok, %{remote_ice_candidates: [^host, ^relay]}} =
             WebRTCSignalingManager.get_session(relay_session_id, viewer_session_id, server: server_name)

    assert {:ok, %{remote_ice_candidates: [^host, ^relay]}} =
             WebRTCSignalingManager.submit_answer(relay_session_id, viewer_session_id, "v=0\r\nanswer",
               server: server_name
             )

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.get_session(relay_session_id, Ecto.UUID.generate(), server: server_name)
  end

  test "releases a viewer whose sink crashed inside the relay pipeline" do
    relay_session_id = Ecto.UUID.generate()
    :ok = RelayPubSub.subscribe(relay_session_id)
    server_name = unique_server_name()

    manager =
      start_supervised!(
        {WebRTCSignalingManager,
         name: server_name,
         session_tracker: SessionTrackerStub,
         pipeline_manager: PipelineManagerStub,
         session_ttl_ms: 5_000}
      )

    assert {:ok, %{viewer_session_id: viewer_session_id}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    send(
      manager,
      {:camera_relay_member_crashed, :webrtc_viewer, relay_session_id, viewer_session_id,
       {:membrane_child_crash, :webrtc, {:shutdown, :connection_failed}}}
    )

    assert_receive {:camera_relay_viewer_leave,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^viewer_session_id, reason: reason}}

    assert reason == "webrtc viewer connection failed"

    assert_receive {:camera_relay_webrtc_closed,
                    %{
                      relay_session_id: ^relay_session_id,
                      viewer_id: ^viewer_session_id,
                      reason: "webrtc viewer connection failed"
                    }}

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.close_session(relay_session_id, viewer_session_id, server: server_name)
  end

  test "survives a viewer whose signaling peer crashed and releases only that viewer" do
    relay_session_id = Ecto.UUID.generate()
    server_name = unique_server_name()

    manager =
      start_supervised!(
        {WebRTCSignalingManager,
         name: server_name,
         session_tracker: SessionTrackerStub,
         pipeline_manager: ElementPeerPipelineManagerStub,
         session_ttl_ms: 5_000}
      )

    assert {:ok, %{viewer_session_id: crashed_viewer}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert {:ok, %{viewer_session_id: other_viewer}} =
             WebRTCSignalingManager.create_session(relay_session_id, server: server_name)

    assert_receive {:element_peer, ^crashed_viewer, element}
    Process.exit(element, :sink_crashed)

    assert_receive {:camera_relay_viewer_leave,
                    %{relay_session_id: ^relay_session_id, viewer_id: ^crashed_viewer, reason: reason}}

    assert reason == "webrtc viewer connection failed"
    # Same process: one viewer's crash must not restart the manager and drop
    # every other viewer's session.
    assert GenServer.whereis(server_name) == manager

    assert {:error, :viewer_session_not_found} =
             WebRTCSignalingManager.close_session(relay_session_id, crashed_viewer, server: server_name)

    assert {:ok, %{viewer_session_id: ^other_viewer, signaling_state: "closed"}} =
             WebRTCSignalingManager.close_session(relay_session_id, other_viewer, server: server_name)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
  defp restore_core_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_core_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
  defp unique_server_name, do: :"camera_relay_webrtc_core_test_#{System.unique_integer([:positive])}"
end
