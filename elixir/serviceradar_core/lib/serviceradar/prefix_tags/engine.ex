defmodule ServiceRadar.PrefixTags.Engine do
  @moduledoc """
  Behaviour for longest-prefix-match (LPM) tag lookups.

  Implementations must return the full matching tag chain ordered most-specific
  first, without performing per-lookup database queries.
  """

  @type ip :: String.t() | :inet.ip_address()
  @type prefix_row :: %{
          required(:prefix) => String.t(),
          optional(:tags) => [String.t()] | nil,
          optional(:source) => String.t() | nil,
          optional(:vrf) => String.t() | nil,
          optional(:site) => String.t() | nil,
          optional(:role) => String.t() | nil,
          optional(:tenant) => String.t() | nil,
          optional(:status) => String.t() | nil
        }

  @type tag_match :: %{
          required(:prefix) => String.t(),
          required(:tags) => [String.t()],
          optional(:source) => String.t() | nil,
          optional(:vrf) => String.t() | nil,
          optional(:severity) => non_neg_integer() | nil
        }

  @type stats :: %{
          required(:ipv4_prefixes) => non_neg_integer(),
          required(:ipv6_prefixes) => non_neg_integer(),
          required(:total_prefixes) => non_neg_integer()
        }

  @type t :: term()

  @doc "Build a lookup structure from prefix rows."
  @callback build([prefix_row()]) :: t()

  @doc """
  Look up the most-specific-first tag chain for an IP.

  Returns an empty list when no prefix matches.
  """
  @callback lookup(t(), ip()) :: [tag_match()]

  @doc """
  Look up using a pre-parsed address (family + bit list).

  Callers that hit multiple source tries for one IP SHOULD parse once and reuse
  bits via this callback when implemented.
  """
  @callback lookup_bits(t(), :ipv4 | :ipv6, [0 | 1]) :: [tag_match()]

  @doc "Parse an IP into family + bit list for multi-trie reuse."
  @callback parse_ip(ip()) :: {:ok, :ipv4 | :ipv6, [0 | 1]} | :error

  @doc "Return size stats for the built trie."
  @callback stats(t()) :: stats()

  @optional_callbacks lookup_bits: 3, parse_ip: 1
end
