defmodule ServiceRadarCoreElx.CameraRelay.PipelineManagerTest do
  use ExUnit.Case, async: false

  alias Membrane.WebRTC.Signaling
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraRelay.AnalysisBranchManager
  alias ServiceRadarCoreElx.CameraRelay.BoomboxBranchManager
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

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

  test "pipes media chunks through membrane and republishes them to relay pubsub" do
    relay_session_id = "relay-membrane-1"
    viewer_id = "viewer-membrane-1"
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ServiceRadarCoreElx.CameraRelay.ViewerRegistry)

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

    assert is_binary(sdp)
    assert String.contains?(sdp, "m=video")

    assert :ok = PipelineManager.remove_webrtc_viewer(relay_session_id, viewer_session_id)
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
               pts: 1_000_000_000,
               dts: 1_000_000_000,
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
               pts: 2_500_000_000,
               dts: 2_500_000_000,
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
    output = Path.join(System.tmp_dir!(), "serviceradar-boombox-output-#{System.unique_integer([:positive])}.h264")

    keyframe_payload =
      <<0, 0, 0, 1, 103, 100, 0, 31, 172, 217, 64, 80, 5, 187, 1, 16, 0, 0, 0, 1, 104, 238, 6, 242, 0, 0, 0, 1, 101, 136,
        132>>

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
