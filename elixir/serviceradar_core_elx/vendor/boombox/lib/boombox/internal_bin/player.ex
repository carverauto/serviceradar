defmodule Boombox.InternalBin.Player do
  @moduledoc false

  alias Boombox.InternalBin.Ready
  alias Boombox.InternalBin.State

  @spec link_output(
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          boolean(),
          State.t()
        ) :: {Ready.t(), State.t()}
  def link_output(_track_builders, _spec_builder, _is_input_realtime, _state) do
    raise """
    Boombox :player output is not supported in ServiceRadar's vendored build.
    This vendored copy removes SDL and PortAudio dependencies so core-elx releases
    can build in headless environments.
    """
  end

  @spec handle_element_end_of_stream(:player_audio_sink | :player_video_sink, State.t()) ::
          {[Membrane.Bin.Action.t()], State.t()}
  def handle_element_end_of_stream(_sink, state), do: {[], state}
end
