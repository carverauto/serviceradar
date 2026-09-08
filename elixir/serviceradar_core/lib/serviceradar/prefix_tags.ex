defmodule ServiceRadar.PrefixTags do
  @moduledoc """
  Domain for IP/CIDR prefix-to-tag mappings used by flow enrichment.

  Snapshot-versioned storage is the source of truth; in-memory LPM tries are
  derived caches loaded per node (see `ServiceRadar.PrefixTags.Engine` and
  `ServiceRadar.PrefixTags.Loader`).
  """

  use Ash.Domain

  resources do
    resource ServiceRadar.PrefixTags.Snapshot
    resource ServiceRadar.PrefixTags.PrefixTag
  end

  authorization do
    require_actor? false
    authorize :by_default
  end
end
