defmodule ServiceRadar.Observability.NetflowCacheScheduler do
  @moduledoc """
  Ensures NetFlow metadata cache refresh jobs are scheduled when Oban is available.
  """

  alias ServiceRadar.Observability.{
    NetflowExporterCacheRefreshWorker,
    NetflowInterfaceCacheRefreshWorker
  }

  use ServiceRadar.ObanEnsureScheduled,
    workers: [NetflowExporterCacheRefreshWorker, NetflowInterfaceCacheRefreshWorker],
    label: "NetFlow cache scheduler",
    tick: :schedule,
    named_start?: true
end
