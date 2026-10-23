defmodule ServiceRadarCoreElx.CameraRecording.Source do
  @moduledoc false
  use Membrane.Source

  alias ServiceRadarCoreElx.CameraRecording.Boundary

  def_output_pad(:output, flow_control: :push, accepted_format: Membrane.H264)

  @impl true
  def handle_init(_ctx, _opts), do: {[], %{pending: nil}}

  @impl true
  def handle_playing(_ctx, state) do
    format = %Membrane.H264{alignment: :au, stream_structure: :annexb}
    {actions, state} = emit(state)
    {[stream_format: {:output, format}] ++ actions, state}
  end

  @impl true
  def handle_parent_notification({:push, buffer, available_bytes}, ctx, %{pending: nil} = state) do
    state = %{state | pending: {buffer, available_bytes}}
    if ctx.playback == :playing, do: emit(state), else: {[], state}
  end

  def handle_parent_notification(:finish, _ctx, state), do: {[end_of_stream: :output], state}

  defp emit(%{pending: nil} = state), do: {[], state}

  defp emit(%{pending: {buffer, available_bytes}} = state) do
    actions = [
      event: {:output, %Boundary{phase: :begin, available_bytes: available_bytes}},
      buffer: {:output, buffer},
      event: {:output, %Boundary{phase: :end}}
    ]

    {actions, %{state | pending: nil}}
  end
end
