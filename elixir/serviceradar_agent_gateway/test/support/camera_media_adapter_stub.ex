defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaAdapterStub do
  @moduledoc false

  def get_cert(:test), do: <<1, 2, 3>>
end
