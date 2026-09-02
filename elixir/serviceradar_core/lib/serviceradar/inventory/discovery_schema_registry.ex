defmodule ServiceRadar.Inventory.DiscoverySchemaRegistry do
  @moduledoc """
  The schemas a `DiscoveryEnvelope` may carry, and the identity policy each one
  is ingested under.

  An add-on emits observations tagged with a `schema` STRING rather than a
  protobuf enum value, so adding an observation type is one entry here and
  nothing else -- no proto edit, no agent change, no agent release. This module
  is the "and nothing else".

  ## Why this is the load-bearing piece

  `SourcePolicy` decides whether a MAC may anchor a canonical device
  (`passive_census_source?/1`) and whether a source may create one at all
  (`enrichment_only_source?/1`). Those decisions key on the update's `source`
  string, NOT on how the payload arrived. So a schema registered with the wrong
  `source` does not fail: it ingests normally with the wrong guardrail, which
  means randomized MACs minting a device per rotation, or mDNS creating devices
  it should only describe.

  Nothing about that is visible at runtime. The consistency test in
  `discovery_schema_registry_test.exs` is what makes it visible at BUILD time,
  and it is the reason this module lands before any producer exists.

  ## Both recognition channels

  `SourcePolicy` recognises a source through `source` **or**
  `metadata["identity_source"]`, and the Go translators set both deliberately so
  the guardrail survives a downstream hop rewriting one of them. An entry
  therefore declares both, and the test asserts each independently -- a schema
  that is correct through one channel and wrong through the other is half
  disarmed, which is worse than being obviously broken.
  """

  alias ServiceRadar.Inventory.Discovery.Decoders

  @type policy_class :: :passive_census | :enrichment_only | :standard

  @type entry :: %{
          source: String.t(),
          identity_source: String.t() | nil,
          policy_class: policy_class(),
          decoder: module()
        }

  # Only schemas whose source string and identity_source are already decided by
  # a shipping producer are registered. Guessing a source here is not a
  # harmless placeholder -- it is a guardrail pointed at the wrong thing.
  #
  # netprobe fingerprint/DPI/process all keep `source: "passive-netprobe"`, which
  # is the string their Go translator already wrote and the one
  # `SourcePolicy.enrichment_only_source?/1` classifies. Changing it here would
  # silently rewrite `discovery_sources` on every device they touch for no gain --
  # `identity_source` is what distinguishes the three.
  #
  # All three are `:enrichment_only`. Fingerprint and DPI describe whatever is at
  # an address and never establish that anything is there; the process listing
  # describes the agent host, which always already has a device. See
  # `SourcePolicy.enrichment_only_source?/1` for the over-merge that
  # classification fixed.
  @schemas %{
    "serviceradar.netprobe.census.v1" => %{
      source: "netprobe-census",
      identity_source: "netprobe_census",
      policy_class: :passive_census,
      decoder: Decoders.Census
    },
    "serviceradar.netprobe.mdns.v1" => %{
      source: "netprobe-mdns",
      identity_source: "netprobe_mdns",
      policy_class: :enrichment_only,
      decoder: Decoders.Mdns
    },
    "serviceradar.netprobe.fingerprint.v1" => %{
      source: "passive-netprobe",
      identity_source: "netprobe_fingerprint",
      policy_class: :enrichment_only,
      decoder: Decoders.Fingerprint
    },
    "serviceradar.netprobe.dpi.v1" => %{
      source: "passive-netprobe",
      identity_source: "netprobe_dpi",
      policy_class: :enrichment_only,
      decoder: Decoders.Dpi
    },
    "serviceradar.netprobe.process.v1" => %{
      source: "passive-netprobe",
      identity_source: "netprobe_process",
      policy_class: :enrichment_only,
      decoder: Decoders.Process
    }
  }

  @doc "Every registered schema name."
  @spec schemas() :: [String.t()]
  def schemas, do: Map.keys(@schemas)

  @doc "The whole table. Test-facing; callers should use `fetch/1`."
  @spec all() :: %{String.t() => entry()}
  def all, do: @schemas

  @doc """
  Look up a schema.

  Returns `:error` for anything unregistered. Callers MUST treat that as a loud
  drop rather than a reason to guess: an unregistered schema has no identity
  policy attached to it, so ingesting it means ingesting under no guardrail.
  """
  @spec fetch(String.t()) :: {:ok, entry()} | :error
  def fetch(schema) when is_binary(schema), do: Map.fetch(@schemas, schema)
  def fetch(_schema), do: :error
end
