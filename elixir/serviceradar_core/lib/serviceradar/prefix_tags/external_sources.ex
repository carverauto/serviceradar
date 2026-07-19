defmodule ServiceRadar.PrefixTags.ExternalSources do
  @moduledoc """
  Registry of prefix-tag sources that materialize from tables other than
  `platform.prefix_tags` (provider CIDRs, threat-intel indicators, DNS-policy).

  Each module MUST export `source_name/0` and `reload/1` (opts). The Loader
  discovers modules from this list instead of hardcoding string→module maps.
  """

  @modules [
    ServiceRadar.PrefixTags.ProviderSource,
    ServiceRadar.PrefixTags.ThreatIntelSource,
    ServiceRadar.PrefixTags.DnsPolicySource
  ]

  @doc "Materializer modules (compile-time list)."
  @spec modules() :: [module()]
  def modules, do: @modules

  @doc "Map of source name → module."
  @spec by_name() :: %{String.t() => module()}
  def by_name do
    Map.new(@modules, fn mod -> {mod.source_name(), mod} end)
  end

  @doc "Whether `source` is an external materializer."
  @spec external?(String.t()) :: boolean()
  def external?(source) when is_binary(source), do: Map.has_key?(by_name(), source)
  def external?(_), do: false

  @doc "Module for a source name, or nil."
  @spec module_for(String.t()) :: module() | nil
  def module_for(source) when is_binary(source), do: Map.get(by_name(), source)
  def module_for(_), do: nil
end
