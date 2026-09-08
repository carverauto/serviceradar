defmodule ServiceRadarAgentGateway do
  @moduledoc """
  Root Boundary for the agent gateway application.
  """

  use Boundary,
    check: [apps: [:serviceradar_core]],
    deps: [
      Monitoring,
      Remotecapture,
      Serviceradar.Agent.Addon.V1,
      Serviceradar.Agent.Netprobe.V1,
      Serviceradar.Metric.V1,
      ServiceRadar
    ],
    exports: :all
end
