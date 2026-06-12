defmodule ServiceRadarAgentGateway do
  @moduledoc """
  Root Boundary for the agent gateway application.
  """

  use Boundary,
    check: [apps: [:serviceradar_core]],
    deps: [Monitoring, Serviceradar.Agent.Addon.V1, ServiceRadar],
    exports: :all
end
