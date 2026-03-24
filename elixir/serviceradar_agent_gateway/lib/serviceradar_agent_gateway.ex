defmodule ServiceRadarAgentGateway do
  @moduledoc """
  Root Boundary for the agent gateway application.
  """

  use Boundary,
    check: [apps: [:serviceradar_core]],
    deps: [Monitoring, ServiceRadar],
    exports: :all
end
