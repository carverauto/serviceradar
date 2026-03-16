defmodule ServiceRadarAgentGateway do
  @moduledoc """
  Root Boundary for the agent gateway application.
  """

  use Boundary,
    deps: [ServiceRadar],
    exports: :all
end
