defmodule ServiceRadar.Observability.IpinfoMmdbScheduler do
  @moduledoc """
  Supervisor child that ensures ipinfo lite MMDB download jobs are scheduled.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadar.Observability.IpinfoMmdbDownloadWorker],
    label: "Ipinfo MMDB scheduling"
end
