defmodule ServiceRadarCoreElx.CameraRelay.PipelineManagerTest do
  use ExUnit.Case, async: false

  alias ExWebRTC.ICECandidate
  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription
  alias Membrane.WebRTC.Signaling
  alias ServiceRadar.Camera.RelayHosts
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraRelay.AnalysisBranchManager
  alias ServiceRadarCoreElx.CameraRelay.BoomboxBranchManager
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager
  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry
  alias ServiceRadarCoreElx.CameraRelay.WebRTCSignalingManager

  defmodule RelaySessionLookup do
    @moduledoc false
    def fetch_session(relay_session_id), do: {:ok, %{relay_session_id: relay_session_id}}
  end

  setup do
    previous_analysis_state = :sys.get_state(AnalysisBranchManager)
    previous_boombox_state = :sys.get_state(BoomboxBranchManager)
    test_pid = self()

    on_exit(fn ->
      :telemetry.detach(telemetry_handler_id(test_pid))
      :sys.replace_state(AnalysisBranchManager, fn _ -> previous_analysis_state end)
      :sys.replace_state(BoomboxBranchManager, fn _ -> previous_boombox_state end)
    end)

    :ok
  end

  # web-ng sends a relay's WebRTC signaling to whichever node advertises it, so
  # the advertisement must exist while the pipeline runs and go away with it.
  test "advertises this node as the relay's host only while its pipeline runs" do
    relay_session_id = "relay-host-advertise-1"
    assert RelayHosts.host_node(relay_session_id) == nil

    assert {:ok, %{pipeline_pid: pipeline}} =
             PipelineManager.open_session(%{
               relay_session_id: relay_session_id,
               media_ingest_id: "synthetic-managed-ingest"
             })

    assert RelayHosts.host_node(relay_session_id) == node()
    assert {:ok, ^pipeline} = PipelineManager.recording_pipeline(relay_session_id, "synthetic-managed-ingest")
    assert {:error, :recording_ingest_mismatch} = PipelineManager.recording_pipeline(relay_session_id, "other-ingest")

    assert :ok = PipelineManager.close_session(relay_session_id)
    # :pg drops a member when it sees the process exit; a call to the scope
    # flushes that before the lookup.
    _ = :sys.get_state(:serviceradar_camera_relay_hosts)
    assert RelayHosts.host_node(relay_session_id) == nil

    assert {:error, :recording_ingest_mismatch} =
             PipelineManager.recording_pipeline(relay_session_id, "synthetic-managed-ingest")
  end

  # Removal used to be acknowledged before the child was gone, so re-adding the
  # same branch right away could collide with the old child's name.
  test "a removed analysis branch can be re-added under the same id immediately" do
    relay_session_id = "relay-readd-analysis-1"
    branch_id = "branch-readd-1"

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    for _round <- 1..20 do
      assert :ok = PipelineManager.add_analysis_branch(relay_session_id, branch_id, subscriber: self())
      assert :ok = PipelineManager.remove_analysis_branch(relay_session_id, branch_id)
    end

    assert :ok = PipelineManager.add_analysis_branch(relay_session_id, branch_id, subscriber: self())
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "forwards chunks to the session's pipeline while the manager process is busy" do
    relay_session_id = "relay-membrane-busy-#{System.unique_integer([:positive])}"
    viewer_id = "viewer-membrane-busy"
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    # Stand-in for the manager blocked in another camera's Membrane call.
    :ok = :sys.suspend(PipelineManager)

    try do
      chunk =
        Task.async(fn ->
          PipelineManager.record_chunk(relay_session_id, %{
            media_ingest_id: "core-media-busy",
            sequence: 21,
            pts: 33_000_000,
            dts: 33_000_000,
            codec: "h264",
            payload_format: "annexb",
            track_id: "video",
            keyframe: true,
            payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
          })
        end)

      assert Task.yield(chunk, 500) == {:ok, :ok}

      assert_receive {:camera_relay_viewer_chunk, %{relay_session_id: ^relay_session_id, sequence: 21}}, 1_000
    after
      :sys.resume(PipelineManager)
    end

    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "pipes media chunks through membrane and republishes them to relay pubsub" do
    relay_session_id = "relay-membrane-1"
    viewer_id = "viewer-membrane-1"
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-1",
               sequence: 11,
               pts: 33_000_000,
               dts: 33_000_000,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
             })

    assert_receive {:camera_relay_viewer_chunk,
                    %{
                      relay_session_id: ^relay_session_id,
                      viewer_id: ^viewer_id,
                      media_ingest_id: "core-media-1",
                      sequence: 11,
                      pts: 33_000_000,
                      dts: 33_000_000,
                      codec: "h264",
                      payload_format: "annexb",
                      track_id: "video",
                      keyframe: true,
                      payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
                    }},
                   1_000

    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "attaches a webrtc viewer and emits an SDP offer" do
    relay_session_id = "relay-webrtc-1"
    viewer_session_id = "viewer-webrtc-1"

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})
    {:ok, signaling_pid} = Signaling.start_link([])
    signaling = Signaling.new(signaling_pid)
    :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())

    assert :ok =
             PipelineManager.add_webrtc_viewer(
               relay_session_id,
               viewer_session_id,
               signaling,
               ice_servers: []
             )

    assert_receive {:membrane_webrtc_signaling, ^signaling_pid, %{"type" => "sdp_offer", "data" => %{"sdp" => sdp}},
                    _metadata},
                   5_000

    assert String.contains?(sdp, "m=video")

    # The signaling manager keeps an answered viewer only while this is true.
    # A missing viewer, or a relay that was never opened, must read as gone so
    # an idle session still expires.
    assert PipelineManager.webrtc_viewer_alive?(relay_session_id, viewer_session_id)
    refute PipelineManager.webrtc_viewer_alive?(relay_session_id, "viewer-never-attached")
    refute PipelineManager.webrtc_viewer_alive?("relay-never-opened", viewer_session_id)

    assert :ok = PipelineManager.remove_webrtc_viewer(relay_session_id, viewer_session_id)
    refute PipelineManager.webrtc_viewer_alive?(relay_session_id, viewer_session_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  # A browser ICE candidate that reaches the WebRTC sink before the SDP answer
  # crashes the sink ({:error, :no_remote_description}). That must cost only
  # this viewer: the relay keeps forwarding media to everyone else.
  test "a crashed webrtc viewer is dropped without taking down the relay pipeline" do
    relay_session_id = "relay-webrtc-crash-#{System.unique_integer([:positive])}"
    viewer_session_id = "viewer-webrtc-crash-1"
    pubsub_viewer_id = "viewer-pubsub-crash-1"
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, pubsub_viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, pubsub_viewer_id)
    _ = :sys.get_state(ViewerRegistry)

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})
    # Unlinked, as production starts it: the Signaling process stops with the
    # sink's crash reason, and a link would take this test down with it.
    signaling = Signaling.start()
    signaling_pid = signaling.pid
    :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())

    assert :ok =
             PipelineManager.add_webrtc_viewer(relay_session_id, viewer_session_id, signaling,
               ice_servers: [],
               notify: self()
             )

    assert_receive {:membrane_webrtc_signaling, ^signaling_pid, %{"type" => "sdp_offer"}, _metadata}, 5_000

    :ok =
      Signaling.signal(signaling, %{
        "type" => "ice_candidate",
        "data" => %{
          "candidate" => "candidate:1 1 UDP 2122252543 192.0.2.10 49152 typ host",
          "sdpMid" => "0",
          "sdpMLineIndex" => 0,
          "usernameFragment" => nil
        }
      })

    assert_receive {:camera_relay_member_crashed, :webrtc_viewer, ^relay_session_id, ^viewer_session_id, _reason},
                   5_000

    # A failed connection drops the sink, which is what lets an abandoned
    # answered session expire instead of being refreshed forever.
    refute PipelineManager.webrtc_viewer_alive?(relay_session_id, viewer_session_id)

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-crash-1",
               sequence: 12,
               pts: 33_000_000,
               dts: 33_000_000,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
             })

    assert_receive {:camera_relay_viewer_chunk, %{relay_session_id: ^relay_session_id, sequence: 12}}, 1_000

    assert {:error, :not_found} = PipelineManager.remove_webrtc_viewer(relay_session_id, viewer_session_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  for phase <- [:connecting, :connected] do
    @tag connection_phase: phase
    test "drops a #{phase} webrtc viewer on ICE failure without disrupting media or logging warnings", %{
      connection_phase: phase
    } do
      relay_session_id = "relay-webrtc-disconnect-#{System.unique_integer([:positive])}"
      viewer_session_id = "viewer-webrtc-disconnect-1"

      pubsub_viewer_id = "viewer-disconnect-observer"
      :ok = RelayPubSub.subscribe_viewer(relay_session_id, pubsub_viewer_id)
      :ok = RelayPubSub.viewer_join(relay_session_id, pubsub_viewer_id)
      _ = :sys.get_state(ViewerRegistry)

      assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})
      on_exit(fn -> PipelineManager.close_session(relay_session_id) end)
      signaling = Signaling.start()
      signaling_pid = signaling.pid
      :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())

      assert :ok =
               PipelineManager.add_webrtc_viewer(relay_session_id, viewer_session_id, signaling,
                 ice_servers: [],
                 notify: self()
               )

      assert_receive {:membrane_webrtc_signaling, ^signaling_pid, %{"type" => "sdp_offer", "data" => offer}, _metadata},
                     5_000

      if phase == :connected do
        # Negotiate a real peer and receive media first. An unanswered offer has
        # no linked input pad, so failing it cannot exercise pad removal.
        peer = connect_viewer_peer(signaling, offer)
        await_peer_media(peer, relay_session_id, 1, System.monotonic_time(:millisecond) + 5_000)
      end

      signaling_state = :sys.get_state(signaling_pid)

      %{pid: webrtc_element_pid} =
        Enum.find([signaling_state.peer_a, signaling_state.peer_b], fn peer ->
          is_map(peer) and Map.get(peer, :is_element) == true
        end)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          send(webrtc_element_pid, {:ex_webrtc, self(), {:connection_state_change, :failed}})

          assert_receive {:camera_relay_member_crashed, :webrtc_viewer, ^relay_session_id, ^viewer_session_id, reason},
                         5_000

          assert reason == {:shutdown, :connection_failed}
        end)

      assert log == ""
      refute PipelineManager.webrtc_viewer_alive?(relay_session_id, viewer_session_id)
      assert :ok = PipelineManager.record_chunk(relay_session_id, disconnect_test_chunk(1_000))
      assert_receive {:camera_relay_viewer_chunk, %{relay_session_id: ^relay_session_id, sequence: 1_000}}, 1_000
      assert :ok = PipelineManager.close_session(relay_session_id)
    end
  end

  test "signaling DOWN cleans up a connected viewer without stopping its relay" do
    relay_session_id = "relay-managed-disconnect-#{System.unique_integer([:positive])}"
    observer = "viewer-managed-disconnect-observer"
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, observer)
    :ok = RelayPubSub.viewer_join(relay_session_id, observer)
    _ = :sys.get_state(ViewerRegistry)

    assert {:ok, %{pipeline_pid: pipeline}} =
             PipelineManager.open_session(%{relay_session_id: relay_session_id})

    on_exit(fn -> PipelineManager.close_session(relay_session_id) end)

    manager =
      start_supervised!(
        {WebRTCSignalingManager,
         name: :disconnect_signaling_manager, session_tracker: RelaySessionLookup, pipeline_manager: PipelineManager}
      )

    assert {:ok, session} = WebRTCSignalingManager.create_session(relay_session_id, server: manager, ice_servers: [])
    viewer_session_id = session.viewer_session_id
    %{signaling_pid: signaling_pid} = :sys.get_state(manager).sessions[viewer_session_id]
    signaling_ref = Process.monitor(signaling_pid)
    {:ok, peer} = PeerConnection.start_link(ice_servers: [])
    on_exit(fn -> if Process.alive?(peer), do: PeerConnection.close(peer) end)
    :ok = PeerConnection.set_remote_description(peer, %SessionDescription{type: :offer, sdp: session.offer_sdp})
    {:ok, answer} = PeerConnection.create_answer(peer)
    :ok = PeerConnection.set_local_description(peer, answer)

    assert {:ok, _} =
             WebRTCSignalingManager.submit_answer(relay_session_id, viewer_session_id, answer.sdp, server: manager)

    await_managed_peer_connected(
      peer,
      manager,
      relay_session_id,
      viewer_session_id,
      [],
      System.monotonic_time(:millisecond) + 5_000
    )

    await_peer_media(peer, relay_session_id, 1, System.monotonic_time(:millisecond) + 5_000)

    signaling_state = :sys.get_state(signaling_pid)

    %{pid: element} =
      Enum.find([signaling_state.peer_a, signaling_state.peer_b], & &1.is_element)

    %{pid: viewer_bin} = :sys.get_state(pipeline).children[{:webrtc_sink, viewer_session_id}]
    :erlang.trace(manager, true, [:receive])
    :erlang.trace(pipeline, true, [:send])

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        # Queue explicit removal behind the failed child's DOWN, but ahead of
        # the remaining internal children's exits. Both events must survive.
        :ok = :sys.suspend(viewer_bin)
        :ok = :sys.suspend(pipeline)

        try do
          try do
            send(element, {:ex_webrtc, self(), {:connection_state_change, :failed}})
            assert_receive {:DOWN, ^signaling_ref, :process, ^signaling_pid, {:shutdown, :connection_failed}}, 5_000
            assert_receive {:trace, ^manager, :receive, {:DOWN, _, :process, ^signaling_pid, _}}, 5_000
          after
            :sys.resume(pipeline)
          end

          assert_receive {:trace, ^pipeline, :send, {Membrane.Core.Message, :terminate, [], []}, ^viewer_bin}, 5_000
        after
          :sys.resume(viewer_bin)
        end

        assert_receive {:trace, ^manager, :receive,
                        {:camera_relay_member_crashed, :webrtc_viewer, ^relay_session_id, ^viewer_session_id,
                         {:shutdown, :connection_failed}}},
                       5_000

        assert {:error, :viewer_session_not_found} =
                 WebRTCSignalingManager.get_session(relay_session_id, viewer_session_id, server: manager)
      end)

    :erlang.trace(manager, false, [:receive])
    :erlang.trace(pipeline, false, [:send])
    assert log == ""
    assert Process.alive?(pipeline)
    refute PipelineManager.webrtc_viewer_alive?(relay_session_id, viewer_session_id)
    assert :ok = PipelineManager.record_chunk(relay_session_id, disconnect_test_chunk(1_000))
    assert_receive {:camera_relay_viewer_chunk, %{relay_session_id: ^relay_session_id, sequence: 1_000}}, 1_000
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "attaches a bounded analysis branch without creating another relay session" do
    relay_session_id = "relay-analysis-1"
    branch_id = "analysis-branch-1"

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, branch} =
             AnalysisBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               subscriber: self(),
               policy: %{sample_interval_ms: 2_000}
             })

    assert branch.relay_session_id == relay_session_id
    assert branch.branch_id == branch_id
    assert branch.policy.sample_interval_ms == 2_000

    # RFC 6184: H264 chunk pts are 90 kHz ticks. One second is 90_000 ticks;
    # 2.5 seconds is 225_000. A 2_000 ms policy is 180_000 ticks.
    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis",
               sequence: 1,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
             })

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis",
               sequence: 2,
               pts: 90_000,
               dts: 90_000,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: false,
               payload: <<0, 0, 0, 1, 101, 1, 2, 3>>
             })

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis",
               sequence: 3,
               pts: 225_000,
               dts: 225_000,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: false,
               payload: <<0, 0, 0, 1, 101, 4, 5, 6>>
             })

    assert_receive {:camera_analysis_input,
                    %{
                      schema: "camera_analysis_input.v1",
                      relay_session_id: ^relay_session_id,
                      branch_id: ^branch_id,
                      sequence: 1,
                      pts: 0,
                      dts: 0,
                      policy: %{sample_interval_ms: 2_000, max_queue_len: 32}
                    }},
                   1_000

    refute_receive {:camera_analysis_input, %{sequence: 2}}, 250

    assert_receive {:camera_analysis_input,
                    %{
                      schema: "camera_analysis_input.v1",
                      relay_session_id: ^relay_session_id,
                      branch_id: ^branch_id,
                      sequence: 3,
                      pts: 225_000,
                      dts: 225_000,
                      policy: %{sample_interval_ms: 2_000, max_queue_len: 32}
                    }},
                   1_000

    state = :sys.get_state(PipelineManager)
    assert Map.has_key?(state.sessions, relay_session_id)

    assert [%{branch_id: ^branch_id}] = AnalysisBranchManager.list_branches(relay_session_id)
    assert :ok = AnalysisBranchManager.close_branch(relay_session_id, branch_id)
    assert [] = AnalysisBranchManager.list_branches(relay_session_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "enforces per-relay analysis branch limits and minimum sampling policy" do
    relay_session_id = "relay-analysis-limit-1"

    :sys.replace_state(AnalysisBranchManager, fn state ->
      state
      |> Map.put(:max_branches_per_session, 1)
      |> Map.put(:min_sample_interval_ms, 750)
      |> Map.put(:default_max_queue_len, 12)
    end)

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :branch_opened],
      [:serviceradar, :camera_relay, :analysis, :limit_rejected],
      [:serviceradar, :camera_relay, :analysis, :branch_count_changed]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, branch} =
             AnalysisBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: "analysis-branch-a",
               subscriber: self(),
               policy: %{sample_interval_ms: 5}
             })

    assert branch.policy == %{sample_interval_ms: 750, max_queue_len: 12}

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :branch_opened], _,
                    %{relay_session_id: ^relay_session_id, branch_id: "analysis-branch-a"}}

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :branch_count_changed],
                    %{branch_count: 1}, %{relay_session_id: ^relay_session_id}}

    assert {:error, :limit_reached} =
             AnalysisBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: "analysis-branch-b",
               subscriber: self(),
               policy: %{sample_interval_ms: 1000, max_queue_len: 6}
             })

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :limit_rejected],
                    %{branch_count: 1, max_queue_len: 6, sample_interval_ms: 1000},
                    %{
                      relay_session_id: ^relay_session_id,
                      branch_id: "analysis-branch-b",
                      limit: "max_branches_per_session"
                    }}

    assert :ok = AnalysisBranchManager.close_branch(relay_session_id, "analysis-branch-a")
    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "drops analysis samples when subscriber backlog exceeds the configured queue limit" do
    relay_session_id = "relay-analysis-backpressure-1"
    branch_id = "analysis-branch-backpressure-1"
    subscriber = spawn(fn -> Process.sleep(:infinity) end)

    attach_telemetry_handler(self(), [
      [:serviceradar, :camera_relay, :analysis, :sample_dropped],
      [:serviceradar, :camera_relay, :analysis, :sample_emitted]
    ])

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, _branch} =
             AnalysisBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               subscriber: subscriber,
               policy: %{sample_interval_ms: 0, max_queue_len: 1}
             })

    send(subscriber, :mailbox_backlog)

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-analysis-backpressure",
               sequence: 1,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
             })

    assert_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :sample_dropped],
                    %{payload_bytes: 8, queue_length: queue_length, max_queue_len: 1},
                    %{relay_session_id: ^relay_session_id, branch_id: ^branch_id, reason: "backpressure"}},
                   1_000

    assert queue_length >= 1
    refute_receive {:camera_analysis_input, _}, 250
    refute_receive {:telemetry_event, [:serviceradar, :camera_relay, :analysis, :sample_emitted], _, _}, 250

    assert :ok = AnalysisBranchManager.close_branch(relay_session_id, branch_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
    Process.exit(subscriber, :kill)
  end

  test "attaches a boombox output branch without creating another relay session" do
    relay_session_id = "relay-boombox-output-1"
    branch_id = "boombox-output-1"

    output =
      Path.join(
        System.tmp_dir!(),
        "serviceradar-boombox-output-#{System.unique_integer([:positive])}.h264"
      )

    keyframe_payload =
      <<
        0,
        0,
        0,
        1,
        103,
        100,
        0,
        31,
        172,
        217,
        64,
        80,
        5,
        187,
        1,
        16,
        0,
        0,
        0,
        1,
        104,
        238,
        6,
        242,
        0,
        0,
        0,
        1,
        101,
        136,
        132
      >>

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert {:ok, branch} =
             BoomboxBranchManager.open_branch(%{
               relay_session_id: relay_session_id,
               branch_id: branch_id,
               output: output
             })

    assert branch.output == output

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-boombox",
               sequence: 1,
               pts: 0,
               dts: 0,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: keyframe_payload
             })

    state = :sys.get_state(PipelineManager)
    assert Map.has_key?(state.sessions, relay_session_id)

    assert :ok = BoomboxBranchManager.close_branch(relay_session_id, branch_id)
    assert :ok = PipelineManager.close_session(relay_session_id)

    File.rm(output)
  end

  defp connect_viewer_peer(signaling, offer) do
    {:ok, peer} = PeerConnection.start_link(ice_servers: [])
    on_exit(fn -> if Process.alive?(peer), do: PeerConnection.close(peer) end)
    :ok = PeerConnection.set_remote_description(peer, SessionDescription.from_json(offer))
    {:ok, answer} = PeerConnection.create_answer(peer)
    :ok = PeerConnection.set_local_description(peer, answer)
    :ok = Signaling.signal(signaling, %{"type" => "sdp_answer", "data" => SessionDescription.to_json(answer)})
    await_peer_connected(peer, signaling, System.monotonic_time(:millisecond) + 5_000)
    peer
  end

  defp await_peer_connected(peer, %{pid: signaling_pid} = signaling, deadline) do
    receive do
      {:ex_webrtc, ^peer, {:connection_state_change, :connected}} ->
        :ok

      {:ex_webrtc, ^peer, {:ice_candidate, candidate}} ->
        :ok = Signaling.signal(signaling, %{"type" => "ice_candidate", "data" => ICECandidate.to_json(candidate)})
        await_peer_connected(peer, signaling, deadline)

      {:membrane_webrtc_signaling, ^signaling_pid, %{"type" => "ice_candidate", "data" => candidate}, _metadata} ->
        :ok = PeerConnection.add_ice_candidate(peer, ICECandidate.from_json(candidate))
        await_peer_connected(peer, signaling, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> flunk("WebRTC test peer did not connect")
    end
  end

  defp await_managed_peer_connected(peer, manager, relay, viewer, installed, deadline) do
    assert System.monotonic_time(:millisecond) < deadline, "Managed WebRTC peer did not connect"
    assert {:ok, session} = WebRTCSignalingManager.get_session(relay, viewer, server: manager)

    for candidate <- session.remote_ice_candidates -- installed do
      :ok = PeerConnection.add_ice_candidate(peer, ICECandidate.from_json(candidate))
    end

    receive do
      {:ex_webrtc, ^peer, {:connection_state_change, :connected}} ->
        :ok

      {:ex_webrtc, ^peer, {:ice_candidate, candidate}} ->
        candidate_json = ICECandidate.to_json(candidate)

        assert {:ok, _} =
                 WebRTCSignalingManager.add_ice_candidate(relay, viewer, candidate_json, server: manager)

        await_managed_peer_connected(peer, manager, relay, viewer, session.remote_ice_candidates, deadline)
    after
      20 -> await_managed_peer_connected(peer, manager, relay, viewer, session.remote_ice_candidates, deadline)
    end
  end

  defp await_peer_media(peer, relay_session_id, sequence, deadline) do
    assert System.monotonic_time(:millisecond) < deadline, "WebRTC test peer did not receive media"
    assert :ok = PipelineManager.record_chunk(relay_session_id, disconnect_test_chunk(sequence))

    receive do
      {:ex_webrtc, ^peer, {:rtp, _track, _rid, _packet}} -> :ok
    after
      50 -> await_peer_media(peer, relay_session_id, sequence + 1, deadline)
    end
  end

  defp disconnect_test_chunk(sequence) do
    %{
      media_ingest_id: "media-disconnect-test",
      sequence: sequence,
      pts: sequence * 90_000,
      dts: sequence * 90_000,
      codec: "h264",
      payload_format: "annexb",
      track_id: "video",
      keyframe: true,
      payload: <<0, 0, 0, 1, 0x65, 0x88, 0x84>>
    }
  end

  defp attach_telemetry_handler(test_pid, events) do
    :telemetry.detach(telemetry_handler_id(test_pid))

    :telemetry.attach_many(
      telemetry_handler_id(test_pid),
      events,
      fn event, measurements, metadata, pid ->
        send(pid, {:telemetry_event, event, measurements, metadata})
      end,
      test_pid
    )
  end

  defp telemetry_handler_id(test_pid), do: "pipeline-manager-test-#{inspect(test_pid)}"
end
