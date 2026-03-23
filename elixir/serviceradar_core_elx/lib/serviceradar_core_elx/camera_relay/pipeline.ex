defmodule ServiceRadarCoreElx.CameraRelay.Pipeline do
  @moduledoc """
  Per-relay Membrane pipeline that owns the media path inside `core-elx`.
  """

  use Membrane.Pipeline

  alias ServiceRadarCoreElx.CameraRelay.ChunkSource
  alias ServiceRadarCoreElx.CameraRelay.PubSubSink

  @source :camera_chunk_source

  @impl true
  def handle_init(_ctx, opts) do
    relay_session_id = Keyword.fetch!(opts, :relay_session_id)

    spec =
      @source
      |> child(ChunkSource)
      |> child(:browser_pubsub_sink, %PubSubSink{relay_session_id: relay_session_id})

    {[spec: spec], %{relay_session_id: relay_session_id}}
  end

  @impl true
  def handle_info({:media_chunk, chunk}, _ctx, state) when is_map(chunk) do
    {[notify_child: {@source, {:media_chunk, chunk}}], state}
  end

  def handle_info(:end_of_stream, _ctx, state) do
    {[notify_child: {@source, :end_of_stream}], state}
  end
end
