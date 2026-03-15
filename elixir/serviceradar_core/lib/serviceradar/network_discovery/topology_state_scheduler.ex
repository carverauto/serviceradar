defmodule ServiceRadar.NetworkDiscovery.TopologyStateScheduler do
  @moduledoc """
  Ensures topology state cleanup jobs stay scheduled when Oban is available.
  """

  alias ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorker
  use ServiceRadar.ObanEnsureScheduled,
    workers: [TopologyStateCleanupWorker],
    label: "Topology state cleanup scheduling"
end
