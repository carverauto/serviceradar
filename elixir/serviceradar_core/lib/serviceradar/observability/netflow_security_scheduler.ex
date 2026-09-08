defmodule ServiceRadar.Observability.NetflowSecurityScheduler do
  @moduledoc """
  Ensures optional NetFlow security intelligence jobs are scheduled when Oban is available.
  """

  use ServiceRadar.ObanEnsureScheduled,
    workers: [
      ServiceRadar.Observability.ThreatIntelFeedRefreshWorker,
      ServiceRadar.Observability.NetflowSecurityRefreshWorker,
      ServiceRadar.PrefixTags.ThreatIntelMaterializeWorker,
      ServiceRadar.PrefixTags.DnsPolicyMaterializeWorker
    ],
    label: "NetFlow security scheduler",
    tick: :schedule,
    named_start?: true
end
