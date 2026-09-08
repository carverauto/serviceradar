defmodule ServiceRadar.Observability.GeoLiteMmdbScheduler do
  @moduledoc """
  Supervisor child that ensures GeoLite MMDB download jobs are scheduled.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadar.Observability.GeoLiteMmdbDownloadWorker],
    label: "GeoLite MMDB scheduling"
end
