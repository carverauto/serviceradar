defmodule ServiceRadar.PrefixTags.ExternalSources do
  @moduledoc """
  Registry of prefix-tag sources that materialize from tables other than
  `platform.prefix_tags` (provider CIDRs, threat-intel indicators, DNS-policy).

  Each module MUST export `source_name/0` and `reload/1` (opts). A successful
  reload returns both the installed row count and the durable timestamp of the
  backing data. The Loader uses that timestamp for snapshot-age telemetry; a
  local trie rebuild must never make stale backing data appear fresh.

  The Loader discovers modules from this list instead of hardcoding
  string→module maps.
  """

  @type reload_result :: %{
          required(:row_count) => non_neg_integer(),
          required(:snapshot_at) => DateTime.t() | nil
        }

  @callback source_name() :: String.t()
  @callback reload(keyword()) :: {:ok, reload_result()} | {:error, term()}

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

  @doc false
  @spec reload_result(non_neg_integer(), term()) :: reload_result()
  def reload_result(row_count, snapshot_at) when is_integer(row_count) and row_count >= 0 do
    %{row_count: row_count, snapshot_at: normalize_datetime(snapshot_at)}
  end

  @doc false
  @spec normalize_datetime(term()) :: DateTime.t() | nil
  def normalize_datetime(%DateTime{} = dt), do: dt

  def normalize_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  def normalize_datetime(_), do: nil
end
