defmodule ServiceRadar.PrefixTags.ThreatIntelMaterializeWorker do
  @moduledoc """
  High-cadence Oban worker that refreshes the `ti` prefix-tag trie from active
  threat-intel indicators.

  Schedule is intentionally short (default 5 minutes) so indicator expiry is
  reflected quickly. Failures are fail-open: the previous trie remains until a
  successful reload.
  """

  use ServiceRadar.PrefixTags.MaterializeWorker,
    source: "ti",
    reload: ServiceRadar.PrefixTags.ThreatIntelSource,
    reschedule_seconds: 5 * 60,
    failure_reschedule_seconds: 10 * 60
end
