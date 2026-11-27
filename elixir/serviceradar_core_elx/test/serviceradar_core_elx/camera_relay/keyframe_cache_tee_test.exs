defmodule ServiceRadarCoreElx.CameraRelay.KeyframeCacheTeeTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.H264
  alias Membrane.KeyframeRequestEvent
  alias Membrane.Pad
  alias Membrane.Testing
  alias ServiceRadarCoreElx.CameraRelay.AnnexBToNALU
  alias ServiceRadarCoreElx.CameraRelay.ChunkSource
  alias ServiceRadarCoreElx.CameraRelay.KeyframeCacheTee

  @sps <<0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x1E>>
  @pps <<0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80>>
  @idr_1 <<0, 0, 0, 1, 0x65, 0x88, 0x84, 0x01>>
  @idr_2 <<0, 0, 0, 1, 0x65, 0x88, 0x84, 0x02>>
  @p_frame_1 <<0, 0, 0, 1, 0x41, 0x9A, 0x01, 0x01>>
  @p_frame_2 <<0, 0, 0, 1, 0x41, 0x9A, 0x02, 0x02>>
  @p_frame_3 <<0, 0, 0, 1, 0x41, 0x9A, 0x03, 0x03>>

  defmodule PliPassthrough do
    @moduledoc false
    use Membrane.Filter

    def_input_pad(:input, accepted_format: _any, flow_control: :auto)
    def_output_pad(:output, accepted_format: _any, flow_control: :auto)

    @impl true
    def handle_init(_ctx, _opts), do: {[], %{}}

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      {[buffer: {:output, buffer}], state}
    end

    @impl true
    def handle_parent_notification(:request_keyframe, _ctx, state) do
      {[event: {:input, %KeyframeRequestEvent{}}], state}
    end
  end

  defmodule UpstreamEventProbe do
    @moduledoc false
    use Membrane.Filter

    def_input_pad(:input, accepted_format: _any, flow_control: :auto)
    def_output_pad(:output, accepted_format: _any, flow_control: :auto)

    def_options(
      test_pid: [
        spec: pid() | nil,
        default: nil
      ]
    )

    @impl true
    def handle_init(_ctx, opts), do: {[], %{test_pid: opts.test_pid}}

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      {[buffer: {:output, buffer}], state}
    end

    @impl true
    def handle_event(:output, event, _ctx, state) do
      if is_pid(state.test_pid) do
        send(state.test_pid, {:upstream_event, event})
      end

      {[event: {:input, event}], state}
    end
  end

  defmodule TestPipeline do
    @moduledoc false
    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, opts) do
      opts = opts || []
      tee_opts = Keyword.get(opts, :tee_opts, [])
      use_parser? = Keyword.get(opts, :use_parser?, true)
      upstream_probe_pid = Keyword.get(opts, :upstream_probe_pid)

      base_chain =
        if use_parser? do
          :source
          |> child(ChunkSource)
          |> child(:parser, AnnexBToNALU)
        else
          child(:source, ChunkSource)
        end

      chain =
        if is_pid(upstream_probe_pid) do
          base_chain
          |> child(:upstream_probe, %UpstreamEventProbe{test_pid: upstream_probe_pid})
          |> child(:tee, struct(KeyframeCacheTee, tee_opts))
        else
          child(base_chain, :tee, struct(KeyframeCacheTee, tee_opts))
        end

      {[spec: [chain]], %{}}
    end

    @impl true
    def handle_info({:send_chunk, chunk}, _ctx, state) do
      {[notify_child: {:source, {:media_chunk, chunk}}], state}
    end

    def handle_info(:end_of_stream, _ctx, state) do
      {[notify_child: {:source, :end_of_stream}], state}
    end

    def handle_info({:send_pli, pad_id}, _ctx, state) do
      {[notify_child: {{:pli, pad_id}, :request_keyframe}], state}
    end

    def handle_info({:replay_keyframe, pad_id}, _ctx, state) do
      {[notify_child: {:tee, {:replay_keyframe, Pad.ref(:push_output, pad_id)}}], state}
    end

    @impl true
    def handle_call({:attach_sink, sink_name, pad_id}, _ctx, state) do
      spec =
        :tee
        |> get_child()
        |> via_out(Pad.ref(:push_output, pad_id))
        |> child(sink_name, Testing.Sink)

      {[spec: spec, reply: :ok], state}
    end

    def handle_call({:attach_pli_sink, sink_name, pad_id}, _ctx, state) do
      spec =
        :tee
        |> get_child()
        |> via_out(Pad.ref(:push_output, pad_id))
        |> child({:pli, pad_id}, PliPassthrough)
        |> child(sink_name, Testing.Sink)

      {[spec: spec, reply: :ok], state}
    end

    def handle_call({:detach_pli_sink, sink_name, pad_id}, _ctx, state) do
      {[remove_children: [{:pli, pad_id}, sink_name], reply: :ok], state}
    end

    def handle_call({:attach_rtp_sink, sink_name, pad_id}, _ctx, state) do
      spec =
        :tee
        |> get_child()
        |> via_out(Pad.ref(:push_output, pad_id))
        |> child({:payloader, pad_id}, Membrane.RTP.H264.Payloader)
        |> child(sink_name, Testing.Sink)

      {[spec: spec, reply: :ok], state}
    end
  end

  test "late-joining pad immediately receives cached SPS+PPS+IDR and current GOP without duplicating to existing pads" do
    pipeline = Testing.Pipeline.start_link_supervised!(module: TestPipeline)
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :early_sink, :early})

    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 90_000, keyframe: true)})
    send(pipeline, {:send_chunk, chunk(@p_frame_1, 93_000, keyframe: false)})

    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @idr_1})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_1})

    # Attach late viewer without sending any new IDR
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :late_sink, :late})

    assert_sink_stream_format(pipeline, :late_sink, %H264{alignment: :nalu, stream_structure: :annexb})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @sps, pts: pts_sps})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @pps, pts: pts_pps})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @idr_1, pts: pts_idr})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @p_frame_1, pts: pts_p1})

    assert pts_sps == Membrane.Time.second()
    assert pts_pps == Membrane.Time.second()
    assert pts_idr == Membrane.Time.second()
    assert pts_p1 > pts_idr

    # Early sink must not have received duplicate burst frames
    refute_sink_buffer(pipeline, :early_sink, _, 100)

    # Subsequent live frames flow to both pads
    send(pipeline, {:send_chunk, chunk(@p_frame_2, 96_000, keyframe: false)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_2})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @p_frame_2})
  end

  test "prepends cached SPS and PPS aligned to new IDR timestamp when new IDR omits parameter sets" do
    pipeline = Testing.Pipeline.start_link_supervised!(module: TestPipeline)
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :early_sink, :early})

    # First GOP carries SPS + PPS + IDR
    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 90_000, keyframe: true)})
    send(pipeline, {:send_chunk, chunk(@p_frame_1, 93_000, keyframe: false)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_1})

    # Second GOP carries only IDR + P2 (no inline SPS/PPS)
    send(pipeline, {:send_chunk, chunk(@idr_2, 270_000, keyframe: true)})
    send(pipeline, {:send_chunk, chunk(@p_frame_2, 273_000, keyframe: false)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_2})

    # Late viewer gets SPS + PPS (stamped to IDR_2's PTS) + IDR_2 + P2, NOT old GOP
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :late_sink, :late})

    expected_idr2_pts = Membrane.Time.seconds(3)

    assert_sink_buffer(pipeline, :late_sink, %Buffer{
      payload: @sps,
      pts: ^expected_idr2_pts,
      dts: ^expected_idr2_pts,
      metadata: %{h264: %{end_access_unit: false}}
    })

    assert_sink_buffer(pipeline, :late_sink, %Buffer{
      payload: @pps,
      pts: ^expected_idr2_pts,
      dts: ^expected_idr2_pts,
      metadata: %{h264: %{end_access_unit: false}}
    })

    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @idr_2, pts: ^expected_idr2_pts})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @p_frame_2})
    refute_sink_buffer(pipeline, :late_sink, %Buffer{payload: @idr_1}, 50)
  end

  test "cached burst payloads cleanly through Membrane.RTP.H264.Payloader" do
    pipeline = Testing.Pipeline.start_link_supervised!(module: TestPipeline)
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :early_sink, :early})

    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 90_000, keyframe: true)})
    send(pipeline, {:send_chunk, chunk(@p_frame_1, 93_000, keyframe: false)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_1})

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_rtp_sink, :late_rtp_sink, :late_rtp})

    # SPS + PPS + IDR share the same PTS and aggregate into an RFC 6184 STAP-A packet
    # (NAL type 24) with marker: true, followed by P1 with marker: true.
    expected_idr_pts = Membrane.Time.second()

    assert_sink_buffer(pipeline, :late_rtp_sink, %Buffer{
      payload: <<stap_header, _rest::binary>>,
      pts: ^expected_idr_pts,
      metadata: %{rtp: %{marker: true}}
    })

    assert Bitwise.band(stap_header, 0x1F) == 24

    # The payloader flushes the cached P1 access unit once the next live access unit arrives.
    send(pipeline, {:send_chunk, chunk(@p_frame_2, 96_000, keyframe: false)})

    assert_sink_buffer(pipeline, :late_rtp_sink, %Buffer{
      pts: p1_pts,
      metadata: %{rtp: %{marker: true}}
    })

    assert p1_pts > expected_idr_pts
  end

  test "does not duplicate SPS/PPS when IDR buffer already contains them inline" do
    pipeline = Testing.Pipeline.start_link_supervised!(module: TestPipeline, custom_args: [use_parser?: false])
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :early_sink, :early})

    inline_idr = @sps <> @pps <> @idr_1
    send(pipeline, {:send_chunk, chunk(@sps, 0, keyframe: false)})
    send(pipeline, {:send_chunk, chunk(@pps, 0, keyframe: false)})
    send(pipeline, {:send_chunk, chunk(inline_idr, 90_000, keyframe: true)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: ^inline_idr})

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :late_sink, :late})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: ^inline_idr})
    refute_sink_buffer(pipeline, :late_sink, _, 100)
  end

  test "non-keyframe buffers arriving before any IDR are forwarded live without poisoning the cache" do
    pipeline = Testing.Pipeline.start_link_supervised!(module: TestPipeline)
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :early_sink, :early})

    send(pipeline, {:send_chunk, chunk(@p_frame_1, 90_000, keyframe: false)})
    send(pipeline, {:send_chunk, chunk(@p_frame_2, 93_000, keyframe: false)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_1})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_2})

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :late_sink, :late})
    assert_sink_stream_format(pipeline, :late_sink, %H264{alignment: :nalu, stream_structure: :annexb})
    refute_sink_buffer(pipeline, :late_sink, _, 100)

    # Once an IDR arrives, live forwarding works normally
    send(pipeline, {:send_chunk, chunk(@idr_1, 96_000, keyframe: true)})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @idr_1})
  end

  test "bounds cached GOP by max_gop_buffers and resets cleanly on the next IDR" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: TestPipeline,
        custom_args: [tee_opts: [max_gop_buffers: 2]]
      )

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :early_sink, :early})

    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 90_000, keyframe: true)})
    send(pipeline, {:send_chunk, chunk(@p_frame_1, 93_000, keyframe: false)})
    send(pipeline, {:send_chunk, chunk(@p_frame_2, 96_000, keyframe: false)})
    send(pipeline, {:send_chunk, chunk(@p_frame_3, 99_000, keyframe: false)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_3})

    # Only SPS + PPS + IDR_1 + P1 fit within max_gop_buffers: 2
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :late_sink_1, :late_1})
    assert_sink_buffer(pipeline, :late_sink_1, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :late_sink_1, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :late_sink_1, %Buffer{payload: @idr_1})
    assert_sink_buffer(pipeline, :late_sink_1, %Buffer{payload: @p_frame_1})
    refute_sink_buffer(pipeline, :late_sink_1, _, 100)

    # Next IDR resets the truncated GOP cleanly
    send(pipeline, {:send_chunk, chunk(@idr_2, 180_000, keyframe: true)})
    send(pipeline, {:send_chunk, chunk(@p_frame_2, 183_000, keyframe: false)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_2})

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :late_sink_2, :late_2})
    assert_sink_buffer(pipeline, :late_sink_2, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :late_sink_2, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :late_sink_2, %Buffer{payload: @idr_2})
    assert_sink_buffer(pipeline, :late_sink_2, %Buffer{payload: @p_frame_2})
    refute_sink_buffer(pipeline, :late_sink_2, _, 100)
  end

  test "bounds cached GOP by max_gop_bytes without creating mid-GOP gaps" do
    # @idr_1 is 8 bytes, @p_frame_1 is 8 bytes, large P-frame is 20 bytes, @p_frame_2 is 8 bytes.
    # With max_gop_bytes: 20, IDR_1 (8) + P1 (8) = 16 fits, large P-frame (20) overflows and
    # truncates so P2 (8) is NOT appended after the skipped large P-frame.
    large_p_frame = <<0, 0, 0, 1, 0x41>> <> :binary.copy(<<0xAA>>, 15)

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: TestPipeline,
        custom_args: [tee_opts: [max_gop_bytes: 20]]
      )

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :early_sink, :early})

    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 90_000, keyframe: true)})
    send(pipeline, {:send_chunk, chunk(@p_frame_1, 93_000, keyframe: false)})
    send(pipeline, {:send_chunk, chunk(large_p_frame, 96_000, keyframe: false)})
    send(pipeline, {:send_chunk, chunk(@p_frame_2, 99_000, keyframe: false)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @p_frame_2})

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :late_sink, :late})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @idr_1})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @p_frame_1})
    refute_sink_buffer(pipeline, :late_sink, _, 100)
  end

  test "retains all slices of a multi-slice IDR access unit" do
    pipeline = Testing.Pipeline.start_link_supervised!(module: TestPipeline)
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :early_sink, :early})

    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1 <> @idr_2, 90_000, keyframe: true)})
    assert_sink_buffer(pipeline, :early_sink, %Buffer{payload: @idr_2})

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :late_sink, :late})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @idr_1})
    assert_sink_buffer(pipeline, :late_sink, %Buffer{payload: @idr_2})
    refute_sink_buffer(pipeline, :late_sink, _, 100)
  end

  test "KeyframeRequestEvent replays cached SPS+PPS+IDR and GOP only to the requesting pad" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: TestPipeline,
        custom_args: [upstream_probe_pid: self()]
      )

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_pli_sink, :viewer_a, :viewer_a})
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_pli_sink, :viewer_b, :viewer_b})

    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 90_000, keyframe: true)})
    send(pipeline, {:send_chunk, chunk(@p_frame_1, 93_000, keyframe: false)})

    for sink <- [:viewer_a, :viewer_b] do
      assert_sink_buffer(pipeline, sink, %Buffer{payload: @sps})
      assert_sink_buffer(pipeline, sink, %Buffer{payload: @pps})
      assert_sink_buffer(pipeline, sink, %Buffer{payload: @idr_1})
      assert_sink_buffer(pipeline, sink, %Buffer{payload: @p_frame_1})
    end

    # Request a keyframe (RTCP PLI) only on viewer_a
    send(pipeline, {:send_pli, :viewer_a})

    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @p_frame_1})

    # viewer_b must not receive the replay and upstream must not be spammed
    refute_sink_buffer(pipeline, :viewer_b, _, 100)
    refute_receive {:upstream_event, %KeyframeRequestEvent{}}, 50
  end

  test "repeated KeyframeRequestEvents within pli_cooldown_ms are throttled and resume after cooldown" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: TestPipeline,
        custom_args: [tee_opts: [pli_cooldown_ms: 80], upstream_probe_pid: self()]
      )

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_pli_sink, :viewer_a, :viewer_a})

    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 90_000, keyframe: true)})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})

    # First PLI replays immediately
    send(pipeline, {:send_pli, :viewer_a})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})

    # Immediate second PLI within cooldown is throttled (no replay, no upstream spam)
    send(pipeline, {:send_pli, :viewer_a})
    refute_sink_buffer(pipeline, :viewer_a, _, 40)
    refute_receive {:upstream_event, %KeyframeRequestEvent{}}, 20

    # After cooldown elapses, another PLI replays cleanly
    Process.sleep(60)
    send(pipeline, {:send_pli, :viewer_a})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})

    # Detaching the pad cleans up per-pad cooldown tracking cleanly
    assert :ok = Membrane.Pipeline.call(pipeline, {:detach_pli_sink, :viewer_a, :viewer_a})
  end

  test "KeyframeRequestEvent before any IDR is cached does not crash and forwards upstream safely" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: TestPipeline,
        custom_args: [upstream_probe_pid: self()]
      )

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_pli_sink, :viewer_a, :viewer_a})

    # Send a non-keyframe first so stream format is established, but no IDR is cached
    send(pipeline, {:send_chunk, chunk(@p_frame_1, 90_000, keyframe: false)})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @p_frame_1})

    send(pipeline, {:send_pli, :viewer_a})

    assert_receive {:upstream_event, %KeyframeRequestEvent{}}, 500
    refute_sink_buffer(pipeline, :viewer_a, _, 100)

    # Pipeline continues forwarding live frames normally after pre-IDR PLI
    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 93_000, keyframe: true)})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})
  end

  test "replay_keyframe parent notification replays cached SPS+PPS+IDR and GOP only to target pad" do
    pipeline = Testing.Pipeline.start_link_supervised!(module: TestPipeline)
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :viewer_a, :viewer_a})
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :viewer_b, :viewer_b})

    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 90_000, keyframe: true)})
    send(pipeline, {:send_chunk, chunk(@p_frame_1, 93_000, keyframe: false)})

    for sink <- [:viewer_a, :viewer_b] do
      assert_sink_buffer(pipeline, sink, %Buffer{payload: @sps})
      assert_sink_buffer(pipeline, sink, %Buffer{payload: @pps})
      assert_sink_buffer(pipeline, sink, %Buffer{payload: @idr_1})
      assert_sink_buffer(pipeline, sink, %Buffer{payload: @p_frame_1})
    end

    # Replay cached GOP only to viewer_a (e.g. on WebRTC DTLS :connected)
    send(pipeline, {:replay_keyframe, :viewer_a})

    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @p_frame_1})

    # viewer_b must not receive the replay
    refute_sink_buffer(pipeline, :viewer_b, _, 100)
  end

  test "replay_keyframe parent notification respects pli_cooldown_ms and resumes after cooldown" do
    pipeline =
      Testing.Pipeline.start_link_supervised!(
        module: TestPipeline,
        custom_args: [tee_opts: [pli_cooldown_ms: 80]]
      )

    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :viewer_a, :viewer_a})

    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 90_000, keyframe: true)})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})

    # First replay fires immediately
    send(pipeline, {:replay_keyframe, :viewer_a})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})

    # Immediate second replay within cooldown is throttled
    send(pipeline, {:replay_keyframe, :viewer_a})
    refute_sink_buffer(pipeline, :viewer_a, _, 40)

    # After cooldown elapses, replay fires again
    Process.sleep(60)
    send(pipeline, {:replay_keyframe, :viewer_a})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})
  end

  test "replay_keyframe parent notification safely no-ops for unknown pads and empty cache" do
    pipeline = Testing.Pipeline.start_link_supervised!(module: TestPipeline)
    assert :ok = Membrane.Pipeline.call(pipeline, {:attach_sink, :viewer_a, :viewer_a})

    # Empty cache: replay_keyframe should be a safe no-op
    send(pipeline, {:send_chunk, chunk(@p_frame_1, 90_000, keyframe: false)})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @p_frame_1})

    send(pipeline, {:replay_keyframe, :viewer_a})
    refute_sink_buffer(pipeline, :viewer_a, _, 50)

    # Warm cache, then send replay_keyframe for an unknown pad
    send(pipeline, {:send_chunk, chunk(@sps <> @pps <> @idr_1, 93_000, keyframe: true)})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @sps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @pps})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @idr_1})

    send(pipeline, {:replay_keyframe, :unknown_viewer})
    refute_sink_buffer(pipeline, :viewer_a, _, 50)

    # Live frames continue flowing normally
    send(pipeline, {:send_chunk, chunk(@p_frame_2, 96_000, keyframe: false)})
    assert_sink_buffer(pipeline, :viewer_a, %Buffer{payload: @p_frame_2})
  end

  defp chunk(payload, pts, opts) do
    %{
      media_ingest_id: "synthetic-keyframe-cache-test",
      sequence: System.unique_integer([:positive]),
      pts: pts,
      dts: pts,
      codec: "h264",
      payload_format: "annexb",
      track_id: "video",
      keyframe: Keyword.get(opts, :keyframe, false),
      payload: payload
    }
  end
end
