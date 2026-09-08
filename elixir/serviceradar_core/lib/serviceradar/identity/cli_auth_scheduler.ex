defmodule ServiceRadar.Identity.CliAuthScheduler do
  @moduledoc """
  Supervisor child that ensures the daily CLI device-code cleanup
  worker is scheduled. Mirrors the pattern used elsewhere in
  serviceradar_core (e.g. `ServiceRadar.Observability.IpEnrichmentScheduler`).

  Scheduling is per-deployment: the GenServer ticks once a minute, and
  on each tick it asks `CliAuthCleanupWorker.ensure_scheduled/0` to
  register the next run if there isn't one queued already. The worker
  reschedules itself for 24h after each successful run.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ServiceRadar.Identity.CliAuthCleanupWorker],
    label: "CliAuthCleanupWorker schedule",
    interval_ms: 60_000
end
