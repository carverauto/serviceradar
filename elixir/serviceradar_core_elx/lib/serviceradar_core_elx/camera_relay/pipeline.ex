defmodule ServiceRadarCoreElx.CameraRelay.Pipeline do
  @moduledoc """
  Per-relay Membrane pipeline that owns the media path inside `core-elx`.

  Every viewer sink and every boombox/analysis branch runs in its own
  temporary crash group. One viewer's WebRTC connection failing (ICE
  `connection_failed`, a signaling error) takes down only that viewer's
  sink; the source, the browser pubsub sink and the other viewers keep
  running. The crashed member is dropped from the pipeline state and its
  owner is told through the `:notify` pid it registered with.
  """

  use Membrane.Pipeline

  alias Membrane.Pad
  alias Membrane.WebRTC.Sink, as: WebRTCSink
  alias ServiceRadarCoreElx.CameraRelay.AnalysisSink
  alias ServiceRadarCoreElx.CameraRelay.AnnexBToNALU
  alias ServiceRadarCoreElx.CameraRelay.BoomboxOutputBin
  alias ServiceRadarCoreElx.CameraRelay.ChunkSource
  alias ServiceRadarCoreElx.CameraRelay.PubSubSink

  require Logger

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

    {[spec: spec],
     %{
       relay_session_id: relay_session_id,
       viewers: %{},
       analysis_branches: %{},
       boombox_branches: %{},
       pending_removals: %{}
     }}
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

      actions = [spec: crash_group(spec, {:webrtc_viewer, viewer_session_id}), reply: :ok]

      next_state =
        put_in(state, [:viewers, viewer_session_id], %{
          sink_name: sink_name,
          output_pad: output_pad,
          notify: Keyword.get(opts, :notify)
        })

      {actions, next_state}
    end
  end

  def handle_call({:remove_webrtc_viewer, viewer_session_id}, ctx, state) do
    case Map.pop(state.viewers, viewer_session_id) do
      {nil, _viewers} ->
        {[reply: {:error, :not_found}], state}

      {%{sink_name: sink_name, output_pad: output_pad}, viewers} ->
        actions = [remove_link: {@webrtc_tee, output_pad}, remove_children: sink_name]
        {actions, defer_removal_reply(%{state | viewers: viewers}, sink_name, ctx.from)}
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
        put_in(state, [:boombox_branches, branch_id], %{
          sink_name: sink_name,
          output_pad: output_pad,
          notify: Keyword.get(opts, :notify)
        })

      {[spec: crash_group(spec, {:boombox_branch, branch_id}), reply: :ok], next_state}
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
        put_in(state, [:analysis_branches, branch_id], %{
          sink_name: sink_name,
          output_pad: output_pad,
          notify: Keyword.get(opts, :notify)
        })

      {[spec: crash_group(spec, {:analysis_branch, branch_id}), reply: :ok], next_state}
    end
  end

  def handle_call({:remove_analysis_branch, branch_id}, ctx, state) do
    case Map.pop(state.analysis_branches, branch_id) do
      {nil, _analysis_branches} ->
        {[reply: {:error, :not_found}], state}

      {%{sink_name: sink_name, output_pad: output_pad}, analysis_branches} ->
        actions = [remove_link: {@browser_tee, output_pad}, remove_children: sink_name]
        {actions, defer_removal_reply(%{state | analysis_branches: analysis_branches}, sink_name, ctx.from)}
    end
  end

  def handle_call({:remove_boombox_branch, branch_id}, ctx, state) do
    case Map.pop(state.boombox_branches, branch_id) do
      {nil, _boombox_branches} ->
        {[reply: {:error, :not_found}], state}

      {%{sink_name: sink_name, output_pad: output_pad}, boombox_branches} ->
        actions = [remove_link: {@webrtc_tee, output_pad}, remove_children: sink_name]
        {actions, defer_removal_reply(%{state | boombox_branches: boombox_branches}, sink_name, ctx.from)}
    end
  end

  # A remove call is answered only once its child has terminated. Replying when
  # the removal is merely requested let a caller re-add the same viewer or
  # branch before the old child was gone, which Membrane rejects with
  # "Duplicated names in children specification". A child that crashes while
  # its removal is pending terminates here too, so the caller still gets :ok.
  @impl true
  def handle_child_terminated(child, _ctx, state) do
    case Map.pop(state.pending_removals, child) do
      {nil, _pending_removals} ->
        {[], state}

      {from, pending_removals} ->
        {[reply_to: {from, :ok}], %{state | pending_removals: pending_removals}}
    end
  end

  @impl true
  def handle_crash_group_down({:webrtc_viewer, viewer_session_id}, ctx, state) do
    drop_member(state, :viewers, viewer_session_id, :webrtc_viewer, ctx)
  end

  def handle_crash_group_down({:boombox_branch, branch_id}, ctx, state) do
    drop_member(state, :boombox_branches, branch_id, :boombox_branch, ctx)
  end

  def handle_crash_group_down({:analysis_branch, branch_id}, ctx, state) do
    drop_member(state, :analysis_branches, branch_id, :analysis_branch, ctx)
  end

  def handle_crash_group_down(_group_name, _ctx, state), do: {[], state}

  # The crashed children are already gone and Membrane unlinks their tee pads;
  # only the bookkeeping and the owner notification are left to do.
  defp drop_member(state, key, member_id, kind, ctx) do
    {member, members} = Map.pop(Map.fetch!(state, key), member_id)
    reason = Map.get(ctx, :crash_reason)

    Logger.warning(
      "Camera relay #{kind} crashed and was removed: relay_session_id=#{state.relay_session_id} " <>
        "member_id=#{member_id} reason=#{inspect(reason)}"
    )

    notify_member_crash(member, kind, state.relay_session_id, member_id, reason)

    {[], Map.put(state, key, members)}
  end

  defp notify_member_crash(%{notify: pid}, kind, relay_session_id, member_id, reason) when is_pid(pid) do
    send(pid, {:camera_relay_member_crashed, kind, relay_session_id, member_id, reason})
    :ok
  end

  defp notify_member_crash(_member, _kind, _relay_session_id, _member_id, _reason), do: :ok

  defp defer_removal_reply(state, sink_name, from) do
    %{state | pending_removals: Map.put(state.pending_removals, sink_name, from)}
  end

  defp crash_group(spec, group), do: {spec, group: group, crash_group_mode: :temporary}
end
