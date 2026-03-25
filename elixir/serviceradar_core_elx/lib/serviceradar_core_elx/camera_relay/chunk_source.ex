defmodule ServiceRadarCoreElx.CameraRelay.ChunkSource do
  @moduledoc """
  Membrane source that accepts camera relay chunks via Erlang messages.
  """

  use Membrane.Source

  def_output_pad(:output,
    flow_control: :push,
    accepted_format: _any
  )

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{buffered: [], stream_format_sent?: false}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    flush_buffers(state)
  end

  @impl true
  def handle_parent_notification({:media_chunk, chunk}, ctx, state) when is_map(chunk) do
    state = %{state | buffered: state.buffered ++ [chunk]}

    if ctx.playback == :playing do
      flush_buffers(state)
    else
      {[], state}
    end
  end

  def handle_parent_notification(:end_of_stream, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  defp ensure_stream_format(%{stream_format_sent?: true} = state), do: {[], state}

  defp ensure_stream_format(state) do
    stream_format = %Membrane.RemoteStream{type: :packetized}
    {[stream_format: {:output, stream_format}], %{state | stream_format_sent?: true}}
  end

  defp flush_buffers(state) do
    base_actions =
      Enum.map(state.buffered, fn chunk ->
        {:buffer,
         {:output,
          %Membrane.Buffer{
            payload: Map.get(chunk, :payload, <<>>),
            pts: Map.get(chunk, :pts),
            dts: Map.get(chunk, :dts),
            metadata: Map.delete(chunk, :payload)
          }}}
      end)

    {stream_format_actions, state} = ensure_stream_format(state)
    {stream_format_actions ++ base_actions, %{state | buffered: []}}
  end
end
