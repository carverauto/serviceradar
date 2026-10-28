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
  alias ServiceRadarCoreElx.CameraRecording.Inbox
  alias ServiceRadarCoreElx.CameraRelay.AnalysisSink
  alias ServiceRadarCoreElx.CameraRelay.AnnexBToNALU
  alias ServiceRadarCoreElx.CameraRelay.BoomboxOutputBin
  alias ServiceRadarCoreElx.CameraRelay.ChunkSource
  alias ServiceRadarCoreElx.CameraRelay.PubSubSink
  alias ServiceRadarCoreElx.CameraRelay.WebRTCViewerBin

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
       media_ingest_id: Keyword.get(opts, :media_ingest_id),
       recorder: nil,
       viewers: %{},
       analysis_branches: %{},
       boombox_branches: %{},
       pending_removals: %{}
     }}
  end

  @impl true
  def handle_info({:media_chunk, chunk}, _ctx, state) when is_map(chunk) do
    {[notify_child: {@source, {:media_chunk, chunk}}], offer_recording(state, chunk)}
  end

  def handle_info(:end_of_stream, _ctx, state) do
    if state.recorder, do: Inbox.finish(state.recorder.inbox)
    {[notify_child: {@source, :end_of_stream}], state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, _ctx, %{recorder: %{monitor: ref}} = state) do
    Inbox.cancel(state.recorder.inbox)
    {[], %{state | recorder: nil}}
  end

  @impl true
  def handle_call({:attach_recorder, %Inbox{} = inbox}, %{from: {caller, _}}, state) do
    if ServiceRadarCoreElx.CameraRecording.Supervisor.enabled?() and state.recorder == nil and
         inbox.worker == caller and inbox.producer == self() and inbox.relay_session_id == state.relay_session_id and
         is_binary(state.media_ingest_id) and state.media_ingest_id != "" and
         inbox.media_ingest_id == state.media_ingest_id do
      monitor = Process.monitor(inbox.worker)
      {[reply: :ok], %{state | recorder: %{inbox: inbox, monitor: monitor}}}
    else
      {[reply: {:error, :recording_attach_refused}], state}
    end
  end

  def handle_call(
        {:drain_recorder, id},
        %{from: {worker, _}},
        %{recorder: %{inbox: %Inbox{id: id, worker: worker} = inbox, monitor: monitor}} = state
      ) do
    # Only this producer can place the end marker after every admitted unit.
    Inbox.finish(inbox)
    Process.demonitor(monitor, [:flush])
    {[reply: :ok], %{state | recorder: nil}}
  end

  def handle_call({:drain_recorder, _id}, _ctx, state), do: {[reply: {:error, :recording_drain_refused}], state}

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
        |> child(sink_name, %WebRTCViewerBin{
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
          notify: Keyword.get(opts, :notify)
        })

      {actions, next_state}
    end
  end

  # A viewer's sink stays in `viewers` until it is removed or crashes, and the
  # sink crashes when its WebRTC connection fails, so this is a liveness check.
  def handle_call({:webrtc_viewer_alive?, viewer_session_id}, _ctx, state) do
    {[reply: Map.has_key?(state.viewers, viewer_session_id)], state}
  end

  def handle_call({:remove_webrtc_viewer, viewer_session_id}, ctx, state) do
    case Map.pop(state.viewers, viewer_session_id) do
      {nil, _viewers} ->
        {[reply: {:error, :not_found}], state}

      {%{sink_name: sink_name} = member, viewers} ->
        actions = [remove_children: sink_name]

        {actions,
         defer_removal_reply(
           %{state | viewers: viewers},
           sink_name,
           ctx.from,
           {member, :webrtc_viewer, viewer_session_id}
         )}
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
          notify: Keyword.get(opts, :notify)
        })

      {[spec: crash_group(spec, {:analysis_branch, branch_id}), reply: :ok], next_state}
    end
  end

  def handle_call({:remove_analysis_branch, branch_id}, ctx, state) do
    case Map.pop(state.analysis_branches, branch_id) do
      {nil, _analysis_branches} ->
        {[reply: {:error, :not_found}], state}

      {%{sink_name: sink_name} = member, analysis_branches} ->
        actions = [remove_children: sink_name]

        {actions,
         defer_removal_reply(
           %{state | analysis_branches: analysis_branches},
           sink_name,
           ctx.from,
           {member, :analysis_branch, branch_id}
         )}
    end
  end

  def handle_call({:remove_boombox_branch, branch_id}, ctx, state) do
    case Map.pop(state.boombox_branches, branch_id) do
      {nil, _boombox_branches} ->
        {[reply: {:error, :not_found}], state}

      {%{sink_name: sink_name} = member, boombox_branches} ->
        actions = [remove_children: sink_name]

        {actions,
         defer_removal_reply(
           %{state | boombox_branches: boombox_branches},
           sink_name,
           ctx.from,
           {member, :boombox_branch, branch_id}
         )}
    end
  end

  # A connected WebRTC bin loses its linked input as its internal crash group
  # shuts down, before the viewer crash-group notification reaches us. Membrane
  # already unlinks the tee; keep the relay alive for the existing cleanup.
  @impl true
  def handle_child_pad_removed({:webrtc_sink, viewer_session_id}, Pad.ref(:input, viewer_session_id), _ctx, state) do
    {[], state}
  end

  # A remove call is answered only once its child has terminated. Replying when
  # the removal is merely requested let a caller re-add the same viewer or
  # branch before the old child was gone, which Membrane rejects with
  # "Duplicated names in children specification". A child that crashes while
  # its removal is pending terminates here too, so the caller still gets :ok.
  @impl true
  def handle_child_terminated(child, ctx, state) do
    case Map.pop(state.pending_removals, child) do
      {nil, _pending_removals} ->
        {[], state}

      {{from, {member, kind, member_id}}, pending_removals} ->
        if ctx.exit_reason != :normal do
          notify_member_crash(member, kind, state.relay_session_id, member_id, ctx.exit_reason)
        end

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

    if kind == :webrtc_viewer and expected_viewer_disconnect?(reason) do
      Logger.info(
        "Camera relay #{kind} disconnected and was removed: relay_session_id=#{state.relay_session_id} " <>
          "member_id=#{member_id} reason=#{inspect(reason)}"
      )
    else
      Logger.warning(
        "Camera relay #{kind} crashed and was removed: relay_session_id=#{state.relay_session_id} " <>
          "member_id=#{member_id} reason=#{inspect(reason)}"
      )
    end

    notify_member_crash(member, kind, state.relay_session_id, member_id, reason)

    {[], Map.put(state, key, members)}
  end

  defp expected_viewer_disconnect?({:shutdown, :connection_failed}), do: true
  defp expected_viewer_disconnect?({:membrane_child_crash, :webrtc, {:shutdown, :connection_failed}}), do: true
  defp expected_viewer_disconnect?(_reason), do: false

  defp notify_member_crash(%{notify: pid}, kind, relay_session_id, member_id, reason) when is_pid(pid) do
    send(pid, {:camera_relay_member_crashed, kind, relay_session_id, member_id, reason})
    :ok
  end

  defp notify_member_crash(_member, _kind, _relay_session_id, _member_id, _reason), do: :ok

  defp defer_removal_reply(state, sink_name, from, member) do
    %{state | pending_removals: Map.put(state.pending_removals, sink_name, {from, member})}
  end

  defp crash_group(spec, group), do: {spec, group: group, crash_group_mode: :temporary}

  defp offer_recording(%{recorder: nil} = state, _chunk), do: state

  defp offer_recording(state, chunk) do
    case Inbox.offer(state.recorder.inbox, chunk) do
      :ok ->
        state

      {:error, _reason} ->
        Process.demonitor(state.recorder.monitor, [:flush])
        %{state | recorder: nil}
    end
  end
end
