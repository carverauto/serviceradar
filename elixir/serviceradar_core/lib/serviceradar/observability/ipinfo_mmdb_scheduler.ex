defmodule ServiceRadar.Observability.IpinfoMmdbScheduler do
  @moduledoc """
  Supervisor child that ensures ipinfo lite MMDB download jobs are scheduled.
  """

  alias ServiceRadar.Observability.IpinfoMmdbDownloadWorker

  use ServiceRadar.ObanEnsureScheduled,
    workers: [IpinfoMmdbDownloadWorker],
    label: "Ipinfo MMDB scheduling"
end
