defmodule ServiceRadarCoreElx.RemoteDesktop.DataChannelProviderTest do
  use ExUnit.Case, async: false

  alias ExWebRTC.DataChannel
  alias ExWebRTC.ICECandidate
  alias ExWebRTC.SessionDescription
  alias Membrane.WebRTC.Signaling
  alias ServiceRadarCoreElx.RemoteDesktop.DataChannelProvider

  defmodule PeerConnectionStub do
    @moduledoc false

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, {test_pid(), opts})

    def create_data_channel(pid, label, opts) do
      GenServer.call(pid, {:create_data_channel, label, opts})
    end

    def create_offer(pid), do: GenServer.call(pid, :create_offer)
    def set_local_description(pid, offer), do: GenServer.call(pid, {:set_local_description, offer})
    def set_remote_description(pid, answer), do: GenServer.call(pid, {:set_remote_description, answer})
    def add_ice_candidate(pid, candidate), do: GenServer.call(pid, {:add_ice_candidate, candidate})
    def close_data_channel(pid, channel_ref), do: GenServer.call(pid, {:close_data_channel, channel_ref})
    def send_data(pid, channel_ref, data, data_type), do: GenServer.call(pid, {:send_data, channel_ref, data, data_type})
    def close(pid), do: GenServer.stop(pid, :normal)

    @impl true
    def init({test_pid, opts}) do
      send(test_pid, {:pc_started, self(), opts})
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_call({:create_data_channel, label, opts}, _from, state) do
      channel = %DataChannel{
        id: nil,
        label: label,
        max_packet_life_time: nil,
        max_retransmits: nil,
        ordered: Keyword.get(opts, :ordered, :ordered),
        protocol: "",
        ready_state: :connecting,
        ref: make_ref()
      }

      send(state.test_pid, {:pc_create_data_channel, self(), label, channel.ref, opts})
      {:reply, {:ok, channel}, state}
    end

    def handle_call(:create_offer, _from, state) do
      offer = %SessionDescription{type: :offer, sdp: "v=0\r\ndesktop-datachannel-offer"}
      send(state.test_pid, {:pc_create_offer, self()})
      {:reply, {:ok, offer}, state}
    end

    def handle_call({:set_local_description, offer}, _from, state) do
      send(state.test_pid, {:pc_set_local_description, self(), offer})
      {:reply, :ok, state}
    end

    def handle_call({:set_remote_description, answer}, _from, state) do
      send(state.test_pid, {:pc_set_remote_description, self(), answer})
      {:reply, :ok, state}
    end

    def handle_call({:add_ice_candidate, candidate}, _from, state) do
      send(state.test_pid, {:pc_add_ice_candidate, self(), candidate})
      {:reply, :ok, state}
    end

    def handle_call({:close_data_channel, channel_ref}, _from, state) do
      send(state.test_pid, {:pc_close_data_channel, self(), channel_ref})
      {:reply, :ok, state}
    end

    def handle_call({:send_data, channel_ref, data, data_type}, _from, state) do
      send(state.test_pid, {:pc_send_data, self(), channel_ref, data, data_type})
      {:reply, :ok, state}
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_data_channel_provider_test_pid)
    end
  end

  defmodule SignalingManagerStub do
    @moduledoc false

    def apply_media_ack(session_id, viewer_session_id, ack, opts) do
      send(test_pid(), {:apply_media_ack, session_id, viewer_session_id, ack, opts})
      {:ok, %{pending_credit_bytes: Map.get(ack, "credit_bytes", 0)}}
    end

    def apply_control_frame(session_id, viewer_session_id, frame, opts) do
      send(test_pid(), {:apply_control_frame, session_id, viewer_session_id, frame, opts})
      {:ok, %{control_frame_count: 1, last_control_frame: frame}}
    end

    def provider_terminated(session_id, viewer_session_id, opts) do
      send(test_pid(), {:provider_terminated, session_id, viewer_session_id, opts})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:serviceradar_core_elx, :remote_desktop_data_channel_provider_test_pid)
    end
  end

  setup do
    previous_test_pid = Application.get_env(:serviceradar_core_elx, :remote_desktop_data_channel_provider_test_pid)
    Application.put_env(:serviceradar_core_elx, :remote_desktop_data_channel_provider_test_pid, self())

    registry = unique_name("desktop_datachannel_registry")
    supervisor = unique_name("desktop_datachannel_supervisor")
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor})

    on_exit(fn ->
      restore_env(:remote_desktop_data_channel_provider_test_pid, previous_test_pid)
    end)

    {:ok, registry: registry, supervisor: supervisor}
  end

  test "creates server-owned media and control DataChannels and emits an SDP offer", ctx do
    signaling = new_signaling()

    assert :ok =
             DataChannelProvider.add_webrtc_viewer("desktop-1", "viewer-1", signaling,
               registry: ctx.registry,
               supervisor: ctx.supervisor,
               peer_connection: PeerConnectionStub
             )

    assert_receive {:pc_started, pc, opts}
    assert opts[:controlling_process]
    assert_receive {:pc_create_data_channel, ^pc, "desktop-media", _media_ref, [ordered: true, protocol: "srdp"]}
    assert_receive {:pc_create_data_channel, ^pc, "desktop-control", _control_ref, [ordered: true, protocol: "srdp"]}
    assert_receive {:pc_create_offer, ^pc}
    assert_receive {:pc_set_local_description, ^pc, %SessionDescription{type: :offer}}

    assert_receive {:membrane_webrtc_signaling, _signaling_pid,
                    %{"type" => "sdp_offer", "data" => %{"sdp" => "v=0\r\ndesktop-datachannel-offer"}}, _metadata}

    :ok =
      Signaling.signal(signaling, %{
        "type" => "sdp_answer",
        "data" => %{"type" => "answer", "sdp" => valid_answer_sdp()}
      })

    assert_receive {:pc_set_remote_description, ^pc, %SessionDescription{type: :answer, sdp: answer_sdp}}
    assert answer_sdp == valid_answer_sdp()

    :ok =
      Signaling.signal(signaling, %{
        "type" => "ice_candidate",
        "data" => %{"candidate" => "candidate:1 1 UDP 1 8.8.8.8 5000 typ srflx", "sdpMid" => "0", "sdpMLineIndex" => 0}
      })

    assert_receive {:pc_add_ice_candidate, ^pc, %ICECandidate{candidate: "candidate:1 1 UDP 1 8.8.8.8 5000 typ srflx"}}
  end

  test "drops blocked browser ICE candidates before ExWebRTC", ctx do
    signaling = new_signaling()

    assert :ok =
             DataChannelProvider.add_webrtc_viewer("desktop-1", "viewer-1", signaling,
               registry: ctx.registry,
               supervisor: ctx.supervisor,
               peer_connection: PeerConnectionStub
             )

    assert_receive {:pc_started, pc, _opts}

    :ok =
      Signaling.signal(signaling, %{
        "type" => "ice_candidate",
        "data" => %{"candidate" => "candidate:1 1 UDP 1 127.0.0.1 5000 typ host", "sdpMid" => "0", "sdpMLineIndex" => 0}
      })

    refute_receive {:pc_add_ice_candidate, ^pc, %ICECandidate{}}, 100
  end

  test "drops blocked ExWebRTC ICE candidates before signaling to the browser", ctx do
    signaling = new_signaling()

    assert :ok =
             DataChannelProvider.add_webrtc_viewer("desktop-5", "viewer-5", signaling,
               registry: ctx.registry,
               supervisor: ctx.supervisor,
               peer_connection: PeerConnectionStub
             )

    assert_receive {:pc_started, pc, _opts}
    {:ok, provider_pid} = lookup(ctx.registry, "desktop-5", "viewer-5")

    send(
      provider_pid,
      {:ex_webrtc, pc, {:ice_candidate, %ICECandidate{candidate: "candidate:1 1 UDP 1 127.0.0.1 5000 typ host"}}}
    )

    refute_receive {:membrane_webrtc_signaling, _pid, %{"type" => "ice_candidate"}, _metadata}, 100

    send(
      provider_pid,
      {:ex_webrtc, pc, {:ice_candidate, %ICECandidate{candidate: "candidate:1 1 UDP 1 8.8.8.8 5000 typ srflx"}}}
    )

    assert_receive {:membrane_webrtc_signaling, _pid, %{"type" => "ice_candidate", "data" => %{"candidate" => candidate}},
                    _metadata}

    assert candidate == "candidate:1 1 UDP 1 8.8.8.8 5000 typ srflx"
  end

  test "refuses remote-created DataChannels", ctx do
    signaling = new_signaling()

    assert :ok =
             DataChannelProvider.add_webrtc_viewer("desktop-6", "viewer-6", signaling,
               registry: ctx.registry,
               supervisor: ctx.supervisor,
               peer_connection: PeerConnectionStub
             )

    assert_receive {:pc_started, pc, _opts}
    {:ok, provider_pid} = lookup(ctx.registry, "desktop-6", "viewer-6")

    channel = %DataChannel{
      id: 7,
      label: "unexpected",
      max_packet_life_time: nil,
      max_retransmits: nil,
      ordered: :ordered,
      protocol: "",
      ready_state: :open,
      ref: make_ref()
    }

    send(provider_pid, {:ex_webrtc, pc, {:data_channel, channel}})

    assert_receive {:pc_close_data_channel, ^pc, channel_ref}
    assert channel_ref == channel.ref
  end

  test "sends SRDP media frames only after the media DataChannel opens", ctx do
    signaling = new_signaling()

    assert :ok =
             DataChannelProvider.add_webrtc_viewer("desktop-2", "viewer-2", signaling,
               registry: ctx.registry,
               supervisor: ctx.supervisor,
               peer_connection: PeerConnectionStub
             )

    assert_receive {:pc_started, pc, _opts}
    assert_receive {:pc_create_data_channel, ^pc, "desktop-media", media_ref, _opts}
    assert_receive {:pc_create_data_channel, ^pc, "desktop-control", _control_ref, _opts}

    assert {:error, :media_data_channel_not_open} =
             DataChannelProvider.forward_frame("desktop-2", "viewer-2", frame("desktop-2", "media-2"),
               registry: ctx.registry
             )

    {:ok, provider_pid} = lookup(ctx.registry, "desktop-2", "viewer-2")
    send(provider_pid, {:ex_webrtc, pc, {:data_channel_state_change, media_ref, :open}})

    assert :ok =
             DataChannelProvider.forward_frame("desktop-2", "viewer-2", frame("desktop-2", "media-2"),
               registry: ctx.registry
             )

    assert_receive {:pc_send_data, ^pc, ^media_ref, <<"SRDP", 1, _rest::binary>>, :binary}
  end

  test "routes browser control-channel acknowledgements to the signaling manager", ctx do
    signaling = new_signaling()

    assert :ok =
             DataChannelProvider.add_webrtc_viewer("desktop-3", "viewer-3", signaling,
               registry: ctx.registry,
               supervisor: ctx.supervisor,
               peer_connection: PeerConnectionStub,
               signaling_manager: SignalingManagerStub,
               signaling_manager_opts: [server: :webrtc_manager_test]
             )

    assert_receive {:pc_started, pc, _opts}
    assert_receive {:pc_create_data_channel, ^pc, "desktop-media", _media_ref, _opts}
    assert_receive {:pc_create_data_channel, ^pc, "desktop-control", control_ref, _opts}
    {:ok, provider_pid} = lookup(ctx.registry, "desktop-3", "viewer-3")

    ack = %{
      "type" => "desktop_media_ack",
      "session_binding_id" => "desktop-3",
      "media_session_id" => "media-3",
      "last_accepted_seq" => 9,
      "credit_bytes" => 2048
    }

    send(provider_pid, {:ex_webrtc, pc, {:data, control_ref, Jason.encode!(ack)}})

    assert_receive {:apply_media_ack, "desktop-3", "viewer-3", ^ack, [server: :webrtc_manager_test]}
  end

  test "routes browser desktop control frames to the signaling manager", ctx do
    signaling = new_signaling()

    assert :ok =
             DataChannelProvider.add_webrtc_viewer("desktop-4", "viewer-4", signaling,
               registry: ctx.registry,
               supervisor: ctx.supervisor,
               peer_connection: PeerConnectionStub,
               signaling_manager: SignalingManagerStub,
               signaling_manager_opts: [server: :webrtc_manager_test]
             )

    assert_receive {:pc_started, pc, _opts}
    assert_receive {:pc_create_data_channel, ^pc, "desktop-media", _media_ref, _opts}
    assert_receive {:pc_create_data_channel, ^pc, "desktop-control", control_ref, _opts}
    {:ok, provider_pid} = lookup(ctx.registry, "desktop-4", "viewer-4")

    frame = %{
      "session_id" => "desktop-4",
      "protocol" => "rdp",
      "frame_type" => "desktop.input",
      "input" => %{"kind" => "key", "key" => "Enter", "down" => true}
    }

    send(provider_pid, {:ex_webrtc, pc, {:data, control_ref, Jason.encode!(frame)}})

    assert_receive {:apply_control_frame, "desktop-4", "viewer-4", ^frame, [server: :webrtc_manager_test]}
  end

  test "provider teardown promptly notifies the signaling manager", ctx do
    signaling = new_signaling()

    assert :ok =
             DataChannelProvider.add_webrtc_viewer("desktop-close", "viewer-close", signaling,
               registry: ctx.registry,
               supervisor: ctx.supervisor,
               peer_connection: PeerConnectionStub,
               signaling_manager: SignalingManagerStub,
               signaling_manager_opts: [actor_id: "actor-1"]
             )

    assert_receive {:pc_started, _pc, _opts}
    assert {:ok, provider_pid} = lookup(ctx.registry, "desktop-close", "viewer-close")
    monitor_ref = Process.monitor(provider_pid)

    assert :ok =
             DataChannelProvider.remove_webrtc_viewer("desktop-close", "viewer-close", registry: ctx.registry)

    assert_receive {:provider_terminated, "desktop-close", "viewer-close", [actor_id: "actor-1"]}
    assert_receive {:DOWN, ^monitor_ref, :process, ^provider_pid, :normal}
    _ = :sys.get_state(ctx.registry)
    assert :error = lookup(ctx.registry, "desktop-close", "viewer-close")
  end

  defp new_signaling do
    {:ok, signaling_pid} = Signaling.start_link([])
    signaling = Signaling.new(signaling_pid)
    :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())
    signaling
  end

  defp lookup(registry, session_id, viewer_session_id) do
    case Registry.lookup(registry, {session_id, viewer_session_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp frame(desktop_session_id, media_session_id) do
    %Desktopmedia.DesktopMediaFrameChunk{
      desktop_session_id: desktop_session_id,
      media_session_id: media_session_id,
      media_ingest_id: "ingest-1",
      agent_id: "agent-1",
      sequence: 1,
      timestamp_unix_nano: 1_778_000_000_000,
      width: 640,
      height: 480,
      payload_family: "dirty_rect",
      encoding: "rgba",
      metadata: <<1, 2>>,
      payload: <<3, 4>>,
      flags: 1
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp valid_answer_sdp do
    """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=fingerprint:sha-256 AA:BB:CC:DD
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    a=sctp-port:5000
    """
  end
end
