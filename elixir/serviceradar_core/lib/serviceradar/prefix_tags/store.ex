defmodule ServiceRadar.PrefixTags.Store do
  @moduledoc """
  `:persistent_term` snapshot storage for the active prefix-tag trie.

  Reads are lock-free and invisible to process GC. Updates use atomic snapshot
  swap: build a new versioned term, flip the active-version pointer, erase the
  previous term. Never write per-entry — only full snapshot swaps.
  """

  alias ServiceRadar.PrefixTags.Engine
  alias ServiceRadar.PrefixTags.Trie

  @active_key {__MODULE__, :active_version}
  @version_key_prefix {__MODULE__, :trie}

  @type version :: non_neg_integer()

  @doc "Look up the most-specific-first tag chain for an IP against the active trie."
  @spec lookup(Engine.ip()) :: [Engine.tag_match()]
  def lookup(ip) do
    result =
      case active_trie() do
        nil -> []
        trie -> engine().lookup(trie, ip)
      end

    emit_lookup_telemetry(result)
    result
  end

  @doc "Return stats for the active trie, or zeros when none is loaded."
  @spec stats() :: Engine.stats()
  def stats do
    case active_trie() do
      nil -> %{ipv4_prefixes: 0, ipv6_prefixes: 0, total_prefixes: 0}
      trie -> engine().stats(trie)
    end
  end

  @doc """
  Build a trie from rows and install it as the active snapshot.

  Returns the new version number.
  """
  @spec put_rows([Engine.prefix_row()]) :: version()
  def put_rows(rows) when is_list(rows) do
    trie = engine().build(rows)
    put_trie(trie)
  end

  @doc "Install a pre-built trie as the active snapshot. Returns the new version."
  @spec put_trie(Engine.t()) :: version()
  def put_trie(trie) do
    version = next_version()
    :persistent_term.put(version_key(version), trie)
    previous = active_version()
    :persistent_term.put(@active_key, version)

    if is_integer(previous) and previous != version do
      :persistent_term.erase(version_key(previous))
    end

    version
  end

  @doc "Clear the active trie (empty snapshot). Used in tests."
  @spec clear() :: :ok
  def clear do
    previous = active_version()
    empty = engine().build([])
    version = next_version()
    :persistent_term.put(version_key(version), empty)
    :persistent_term.put(@active_key, version)

    if is_integer(previous) and previous != version do
      :persistent_term.erase(version_key(previous))
    end

    :ok
  end

  @doc "Current active version, or nil if none has been installed."
  @spec active_version() :: version() | nil
  def active_version do
    :persistent_term.get(@active_key, nil)
  rescue
    ArgumentError -> nil
  end

  @doc false
  @spec active_trie() :: Engine.t() | nil
  def active_trie do
    case active_version() do
      nil ->
        nil

      version ->
        :persistent_term.get(version_key(version), nil)
    end
  rescue
    ArgumentError -> nil
  end

  defp version_key(version), do: {@version_key_prefix, version}

  defp next_version do
    case active_version() do
      nil -> 1
      n when is_integer(n) -> n + 1
    end
  end

  defp engine do
    Application.get_env(:serviceradar_core, :prefix_tags_engine, Trie)
  end

  defp emit_lookup_telemetry(result) do
    outcome = if result == [], do: :miss, else: :hit

    :telemetry.execute(
      [:serviceradar, :prefix_tags, :lookup],
      %{count: 1, match_depth: length(result)},
      %{outcome: outcome}
    )
  end
end
