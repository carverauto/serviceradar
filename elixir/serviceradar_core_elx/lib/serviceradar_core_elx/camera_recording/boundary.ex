defmodule ServiceRadarCoreElx.CameraRecording.Boundary do
  @moduledoc false
  @derive Membrane.EventProtocol
  defstruct [:phase, :available_bytes, accepted_bytes: 0, keyframe?: false]
end
