defmodule ServiceRadar.Observability.GeoLiteMmdbScheduler do
  @moduledoc """
  Supervisor child that ensures GeoLite MMDB download jobs are scheduled.
  """

  alias ServiceRadar.Observability.GeoLiteMmdbDownloadWorker

  use ServiceRadar.ObanEnsureScheduled,
    workers: [GeoLiteMmdbDownloadWorker],
    label: "GeoLite MMDB scheduling"
end
