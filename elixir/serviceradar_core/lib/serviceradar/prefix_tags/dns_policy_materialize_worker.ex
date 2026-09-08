defmodule ServiceRadar.PrefixTags.DnsPolicyMaterializeWorker do
  @moduledoc """
  Oban worker that refreshes the `dns-policy` prefix-tag trie from recent
  PowerDNS RPZ hits in ocsf_events.
  """

  use ServiceRadar.PrefixTags.MaterializeWorker,
    source: "dns-policy",
    reload: ServiceRadar.PrefixTags.DnsPolicySource,
    reschedule_seconds: 15 * 60,
    failure_reschedule_seconds: 30 * 60
end
