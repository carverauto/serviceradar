defmodule ServiceRadar.Observability.NetflowSecurityScheduler do
  @moduledoc """
  Ensures optional NetFlow security intelligence jobs are scheduled when Oban is available.
  """

  alias ServiceRadar.Observability.{NetflowSecurityRefreshWorker, ThreatIntelFeedRefreshWorker}

  use ServiceRadar.ObanEnsureScheduled,
    workers: [ThreatIntelFeedRefreshWorker, NetflowSecurityRefreshWorker],
    label: "NetFlow security scheduler",
    tick: :schedule,
    named_start?: true
end
