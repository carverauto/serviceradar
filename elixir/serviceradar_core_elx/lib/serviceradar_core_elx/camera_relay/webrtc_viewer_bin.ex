defmodule ServiceRadarCoreElx.CameraRelay.WebRTCViewerBin do
  @moduledoc """
  Wrapper around `Membrane.WebRTC.Sink` that places internal children in a
  temporary crash group so expected WebRTC peer disconnects
  (`{:shutdown, :connection_failed}`) terminate the viewer bin silently
  without `Membrane.Core.ProcessHelper` logging `Terminating with reason:
  {:membrane_child_crash, :webrtc, {:shutdown, :connection_failed}}` at error
  level.
  """

  use Membrane.Bin

  alias ExWebRTC.PeerConnection.Configuration
  alias Membrane.Core.ProcessHelper
  alias Membrane.H264
  alias Membrane.H265
  alias Membrane.RemoteStream
  alias Membrane.VP8
  alias Membrane.WebRTC.Signaling
  alias Membrane.WebRTC.SimpleWebSocketServer
  alias Membrane.WebRTC.Sink, as: WebRTCSink

  @internal_group :webrtc_viewer_internal

  def_options(
    signaling: [
      spec:
        Signaling.t()
        | {:whip, WebRTCSink.whip_options()}
        | {:websocket, SimpleWebSocketServer.options()}
    ],
    tracks: [
      spec: [:audio | :video],
      default: [:audio, :video]
    ],
    video_codec: [
      spec: :vp8 | :h264 | :h265 | :av1 | [:vp8 | :h264 | :h265 | :av1],
      default: [:vp8, :h264]
    ],
    ice_servers: [
      spec: [Configuration.ice_server()],
      default: [%{urls: "stun:stun.l.google.com:19302"}]
    ],
    payload_rtp: [
      spec: boolean(),
      default: true
    ]
  )

  def_input_pad(:input,
    accepted_format:
      any_of(
        %H264{alignment: :nalu},
        %H265{alignment: :nalu},
        %RemoteStream{content_format: VP8},
        %RemoteStream{content_format: Membrane.RTP},
        VP8,
        Membrane.Opus,
        Membrane.RTP
      ),
    availability: :on_request,
    options: [
      kind: [
        spec: :audio | :video | nil,
        default: nil
      ]
    ]
  )

  @impl true
  def handle_init(ctx, opts) do
    sink_opts = struct(WebRTCSink, Map.from_struct(opts))

    ctx
    |> WebRTCSink.handle_init(sink_opts)
    |> group_internal_specs()
  end

  @impl true
  def handle_setup(ctx, state) do
    WebRTCSink.handle_setup(ctx, state)
  end

  @impl true
  def handle_pad_added(pad_ref, ctx, state) do
    pad_ref
    |> WebRTCSink.handle_pad_added(ctx, state)
    |> group_internal_specs()
  end

  @impl true
  def handle_child_notification(notification, child, ctx, state) do
    notification
    |> WebRTCSink.handle_child_notification(child, ctx, state)
    |> group_internal_specs()
  end

  @impl true
  def handle_parent_notification(notification, ctx, state) do
    WebRTCSink.handle_parent_notification(notification, ctx, state)
  end

  @impl true
  def handle_element_end_of_stream(name, pad, ctx, state) do
    WebRTCSink.handle_element_end_of_stream(name, pad, ctx, state)
  end

  # A normal terminate action replaces our callbacks with Membrane's zombie
  # callbacks and loses an in-flight crash reason. Drain the children while
  # keeping handle_crash_group_down active; Membrane stops us when they are gone.
  @impl true
  def handle_terminate_request(%{children: children}, state) when map_size(children) == 0 do
    {[terminate: :normal], state}
  end

  def handle_terminate_request(_ctx, state) do
    {[remove_children: @internal_group], state}
  end

  @impl true
  def handle_crash_group_down(@internal_group, ctx, state) do
    case ctx.crash_reason do
      {:shutdown, _} = reason ->
        {[terminate: reason], state}

      reason ->
        ProcessHelper.notoelo({:membrane_child_crash, ctx.crash_initiator, reason})
    end
  end

  defp group_internal_specs({actions, state}) do
    grouped_actions =
      Enum.map(actions, fn
        {:spec, spec} ->
          {:spec, {spec, group: @internal_group, crash_group_mode: :temporary}}

        other ->
          other
      end)

    {grouped_actions, state}
  end
end
