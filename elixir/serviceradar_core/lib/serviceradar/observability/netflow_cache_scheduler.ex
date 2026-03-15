defmodule ServiceRadar.Observability.NetflowCacheScheduler do
  @moduledoc """
  Ensures NetFlow metadata cache refresh jobs are scheduled when Oban is available.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [
      ServiceRadar.Observability.NetflowExporterCacheRefreshWorker,
      ServiceRadar.Observability.NetflowInterfaceCacheRefreshWorker
    ],
    label: "NetFlow cache scheduler",
    tick: :schedule,
    named_start?: true
end
