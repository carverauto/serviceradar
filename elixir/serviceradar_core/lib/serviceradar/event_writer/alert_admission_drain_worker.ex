defmodule ServiceRadar.EventWriter.AlertAdmissionDrainWorker do
  @moduledoc """
  Admits the occurrences left in `platform.alert_pending_admissions` and
  reports the backlog.

  EventWriter admits a backlog as traffic arrives: a batch that touches a
  lifecycle series admits that series' pending occurrences, and a batch that
  joins a deferred event or metric lane admits one chunk from its head. A
  series or lane that receives no later message would otherwise keep its rows,
  so each run, every minute:

    * pages through the pending lifecycle series longest-waiting first,
      admitting each in `seq` order up to its first refusal and continuing
      with the next, so a series stuck behind a saturated rule does not starve
      the ones behind it; this part stops after 1,000 admissions or 30
      seconds (`AnalyticsSignals.drain_pending_admissions/1`);
    * drains each deferred event and metric lane from its head, chunk by
      chunk, until it is empty, refused or 30 seconds have elapsed
      (`AlertAdmissionBacklog.drain/1`);
    * reports the backlog's size and age and its `alert-admission-backlog`
      health check (`AlertAdmissionBacklog.report/0`).
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.EventWriter.AlertAdmissionBacklog
  alias ServiceRadar.EventWriter.Processors.AnalyticsSignals

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    lifecycle = AnalyticsSignals.drain_pending_admissions()
    deferred = AlertAdmissionBacklog.drain()

    if lifecycle + deferred > 0 do
      Logger.info("Admitted pending alert evaluations",
        lifecycle_count: lifecycle,
        deferred_count: deferred
      )
    end

    _ = AlertAdmissionBacklog.report()
    :ok
  end
end
