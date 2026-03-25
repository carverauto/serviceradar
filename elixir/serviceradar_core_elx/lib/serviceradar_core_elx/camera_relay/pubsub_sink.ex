defmodule ServiceRadarCoreElx.CameraRelay.PubSubSink do
  @moduledoc """
  Membrane sink that republishes processed relay chunks onto the shared camera PubSub topic.
  """

  use Membrane.Sink

  alias ServiceRadarCoreElx.CameraRelay.ViewerRegistry

  def_options(
    relay_session_id: [
      spec: String.t(),
      description: "Relay session id for downstream browser fan-out"
    ]
  )

  def_input_pad(:input,
    flow_control: :push,
    accepted_format: _any
  )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{relay_session_id: opts.relay_session_id}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    metadata = Map.get(buffer, :metadata, %{})

    ViewerRegistry.broadcast_chunk(state.relay_session_id, %{
      relay_session_id: state.relay_session_id,
      media_ingest_id: Map.get(metadata, :media_ingest_id),
      sequence: Map.get(metadata, :sequence),
      pts: normalize_timestamp(buffer.pts),
      dts: normalize_timestamp(buffer.dts),
      codec: Map.get(metadata, :codec),
      payload_format: Map.get(metadata, :payload_format),
      track_id: Map.get(metadata, :track_id),
      keyframe: Map.get(metadata, :keyframe, false) == true,
      payload: buffer.payload
    })

    {[], state}
  end

  defp normalize_timestamp(value) when is_integer(value), do: value
  defp normalize_timestamp(_value), do: nil
end
