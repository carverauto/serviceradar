defmodule ServiceRadarCoreElx.CameraRelay.Pipeline do
  @moduledoc """
  Per-relay Membrane pipeline that owns the media path inside `core-elx`.
  """

  use Membrane.Pipeline

  alias Membrane.Pad
  alias Membrane.WebRTC.Sink, as: WebRTCSink
  alias ServiceRadarCoreElx.CameraRelay.AnalysisSink
  alias ServiceRadarCoreElx.CameraRelay.AnnexBToNALU
  alias ServiceRadarCoreElx.CameraRelay.BoomboxOutputBin
  alias ServiceRadarCoreElx.CameraRelay.ChunkSource
  alias ServiceRadarCoreElx.CameraRelay.PubSubSink

  @source :camera_chunk_source
  @browser_tee :camera_browser_tee
  @webrtc_parser :camera_webrtc_annexb_to_nalu
  @webrtc_tee :camera_webrtc_tee

  @impl true
  def handle_init(_ctx, opts) do
    relay_session_id = Keyword.fetch!(opts, :relay_session_id)

    spec = [
      @source
      |> child(ChunkSource)
      |> child(@browser_tee, Membrane.Tee),
      @browser_tee
      |> get_child()
      |> via_out(Pad.ref(:push_output, :browser_pubsub))
      |> child(:browser_pubsub_sink, %PubSubSink{relay_session_id: relay_session_id}),
      @browser_tee
      |> get_child()
      |> via_out(Pad.ref(:push_output, :webrtc_annexb))
      |> child(@webrtc_parser, AnnexBToNALU)
      |> child(@webrtc_tee, Membrane.Tee)
    ]

    {[spec: spec], %{relay_session_id: relay_session_id, viewers: %{}, analysis_branches: %{}, boombox_branches: %{}}}
  end

  @impl true
  def handle_info({:media_chunk, chunk}, _ctx, state) when is_map(chunk) do
    {[notify_child: {@source, {:media_chunk, chunk}}], state}
  end

  def handle_info(:end_of_stream, _ctx, state) do
    {[notify_child: {@source, :end_of_stream}], state}
  end

  @impl true
  def handle_call({:add_webrtc_viewer, viewer_session_id, signaling, opts}, _ctx, state) do
    if Map.has_key?(state.viewers, viewer_session_id) do
      {[reply: {:error, :already_exists}], state}
    else
      sink_name = {:webrtc_sink, viewer_session_id}
      output_pad = Pad.ref(:push_output, viewer_session_id)
      input_pad = Pad.ref(:input, viewer_session_id)

      spec =
        @webrtc_tee
        |> get_child()
        |> via_out(output_pad)
        |> via_in(input_pad, options: [kind: :video])
        |> child(sink_name, %WebRTCSink{
          signaling: signaling,
          tracks: [:video],
          video_codec: :h264,
          ice_servers: Keyword.get(opts, :ice_servers, []),
          payload_rtp: true
        })

      actions = [spec: spec, reply: :ok]

      next_state =
        put_in(state, [:viewers, viewer_session_id], %{sink_name: sink_name, output_pad: output_pad})

      {actions, next_state}
    end
  end

  def handle_call({:remove_webrtc_viewer, viewer_session_id}, _ctx, state) do
    case Map.pop(state.viewers, viewer_session_id) do
      {nil, _viewers} ->
        {[reply: {:error, :not_found}], state}

      {%{sink_name: sink_name, output_pad: output_pad}, viewers} ->
        actions = [remove_link: {@webrtc_tee, output_pad}, remove_children: sink_name, reply: :ok]
        {actions, %{state | viewers: viewers}}
    end
  end

  def handle_call({:add_boombox_branch, branch_id, opts}, _ctx, state) do
    if Map.has_key?(state.boombox_branches, branch_id) do
      {[reply: {:error, :already_exists}], state}
    else
      sink_name = {:boombox_sink, branch_id}
      output_pad = Pad.ref(:push_output, {:boombox, branch_id})

      spec =
        @webrtc_tee
        |> get_child()
        |> via_out(output_pad)
        |> child(sink_name, %BoomboxOutputBin{
          output: Keyword.fetch!(opts, :output)
        })

      next_state =
        put_in(state, [:boombox_branches, branch_id], %{sink_name: sink_name, output_pad: output_pad})

      {[spec: spec, reply: :ok], next_state}
    end
  end

  def handle_call({:add_analysis_branch, branch_id, opts}, _ctx, state) do
    if Map.has_key?(state.analysis_branches, branch_id) do
      {[reply: {:error, :already_exists}], state}
    else
      sink_name = {:analysis_sink, branch_id}
      output_pad = Pad.ref(:push_output, {:analysis, branch_id})

      spec =
        @browser_tee
        |> get_child()
        |> via_out(output_pad)
        |> child(sink_name, %AnalysisSink{
          relay_session_id: state.relay_session_id,
          branch_id: branch_id,
          subscriber: Keyword.fetch!(opts, :subscriber),
          policy: Keyword.get(opts, :policy, %{})
        })

      next_state =
        put_in(state, [:analysis_branches, branch_id], %{sink_name: sink_name, output_pad: output_pad})

      {[spec: spec, reply: :ok], next_state}
    end
  end

  def handle_call({:remove_analysis_branch, branch_id}, _ctx, state) do
    case Map.pop(state.analysis_branches, branch_id) do
      {nil, _analysis_branches} ->
        {[reply: {:error, :not_found}], state}

      {%{sink_name: sink_name, output_pad: output_pad}, analysis_branches} ->
        actions = [remove_link: {@browser_tee, output_pad}, remove_children: sink_name, reply: :ok]
        {actions, %{state | analysis_branches: analysis_branches}}
    end
  end

  def handle_call({:remove_boombox_branch, branch_id}, _ctx, state) do
    case Map.pop(state.boombox_branches, branch_id) do
      {nil, _boombox_branches} ->
        {[reply: {:error, :not_found}], state}

      {%{sink_name: sink_name, output_pad: output_pad}, boombox_branches} ->
        actions = [remove_link: {@webrtc_tee, output_pad}, remove_children: sink_name, reply: :ok]
        {actions, %{state | boombox_branches: boombox_branches}}
    end
  end
end
