defmodule ServiceRadar do
  @moduledoc """
  Root Boundary for the ServiceRadar core application.

  The first Boundary pass keeps the core namespace broad and exported so the
  compiler can model the application boundary without forcing a domain-by-domain
  rewrite. Future tightening can carve explicit sub-boundaries out of this root.
  """

  use Boundary,
    check: [apps: [:serviceradar_srql]],
    deps: [
      Flowpb,
      Monitoring,
      Serviceradar.Agent.Addon.V1,
      Serviceradar.Agent.Discovery.V1,
      Serviceradar.Agent.Netprobe.V1,
      Serviceradar.Edge.V1,
      Serviceradar.Metric.V1,
      ServiceRadarSRQL
    ],
    exports: :all
end
