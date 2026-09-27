defmodule ServiceRadar.NetworkDiscovery.TopologyStateScheduler do
  @moduledoc """
  Ensures topology state cleanup jobs stay scheduled when Oban is available.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [
      ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorker,
      ServiceRadar.NetworkDiscovery.WorldWorker,
      ServiceRadar.NetworkDiscovery.WorldRetentionWorker
    ],
    label: "Topology state cleanup scheduling"
end
