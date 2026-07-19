defmodule ServiceRadar.PrefixTags.Store do
  @moduledoc """
  Per-source `:persistent_term` snapshot storage for prefix-tag LPM tries.

  Each tag source (netbox, manual, provider, ti, dns-policy, …) has its own
  versioned trie and swaps independently. Lookups merge most-specific-first
  chains across all active sources with per-tag source provenance. Never write
  per-entry — only full snapshot swaps per source.
  """

  alias ServiceRadar.PrefixTags.Engine
  alias ServiceRadar.PrefixTags.Trie

  @sources_key {__MODULE__, :active_sources}
  @active_key_prefix {__MODULE__, :active_version}
  @version_key_prefix {__MODULE__, :trie}
  # Delay erase so concurrent lookups that already observed the previous
  # active version can still materialize the trie (spec concurrent-swap).
  @erase_delay_ms 1_000

  @type source :: String.t()
  @type version :: non_neg_integer()

  @doc """
  Look up the most-specific-first tag chain for an IP across all active sources.

  Chains from each source are merged by prefix mask length (descending). Each
  match retains its `source` field for provenance.
  """
  @spec lookup(Engine.ip()) :: [Engine.tag_match()]
  def lookup(ip) do
    result =
      sources()
      |> Enum.flat_map(fn source ->
        case active_trie(source) do
          nil ->
            []

          trie ->
            engine().lookup(trie, ip)
            |> Enum.map(&ensure_source(&1, source))
        end
      end)
      |> merge_by_specificity()

    emit_lookup_telemetry(result)
    result
  end

  @doc "Look up against a single source (empty if that source has no trie)."
  @spec lookup(Engine.ip(), source()) :: [Engine.tag_match()]
  def lookup(ip, source) when is_binary(source) do
    case active_trie(source) do
      nil -> []
      trie -> Enum.map(engine().lookup(trie, ip), &ensure_source(&1, source))
    end
  end

  @doc """
  Aggregated stats plus per-source breakdown.

  Returns `%{ipv4_prefixes:, ipv6_prefixes:, total_prefixes:, sources: %{src => stats}}`.
  """
  @spec stats() :: map()
  def stats do
    per_source =
      Map.new(sources(), fn source ->
        case active_trie(source) do
          nil -> {source, empty_stats()}
          trie -> {source, engine().stats(trie)}
        end
      end)

    totals =
      Enum.reduce(per_source, empty_stats(), fn {_src, s}, acc ->
        %{
          ipv4_prefixes: acc.ipv4_prefixes + s.ipv4_prefixes,
          ipv6_prefixes: acc.ipv6_prefixes + s.ipv6_prefixes,
          total_prefixes: acc.total_prefixes + s.total_prefixes
        }
      end)

    Map.put(totals, :sources, per_source)
  end

  @doc "Stats for one source."
  @spec stats(source()) :: Engine.stats()
  def stats(source) when is_binary(source) do
    case active_trie(source) do
      nil -> empty_stats()
      trie -> engine().stats(trie)
    end
  end

  @doc "Build and install rows for a single source. Returns the new version."
  @spec put_rows(source(), [Engine.prefix_row()]) :: version()
  def put_rows(source, rows) when is_binary(source) and is_list(rows) do
    put_trie(source, engine().build(rows))
  end

  @doc """
  Install rows partitioned by each row's `:source` field (default `"manual"`).

  Convenience for tests and callers that pass mixed rows. Each distinct source
  is swapped independently.
  """
  @spec put_rows([Engine.prefix_row()]) :: %{source() => version()}
  def put_rows(rows) when is_list(rows) do
    rows
    |> Enum.group_by(fn row ->
      to_string(row[:source] || row["source"] || "manual")
    end)
    |> Map.new(fn {source, source_rows} ->
      {source, put_rows(source, source_rows)}
    end)
  end

  @doc "Install a pre-built trie for a source. Returns the new version."
  @spec put_trie(source(), Engine.t()) :: version()
  def put_trie(source, trie) when is_binary(source) do
    started = System.monotonic_time(:microsecond)
    version = next_version(source)
    # Build-then-flip: install the new term before pointing active at it.
    :persistent_term.put(version_key(source, version), trie)
    previous = active_version(source)
    :persistent_term.put(active_key(source), version)
    register_source(source)

    if is_integer(previous) and previous != version do
      schedule_erase(source, previous)
    end

    duration_us = System.monotonic_time(:microsecond) - started
    s = engine().stats(trie)

    :telemetry.execute(
      [:serviceradar, :prefix_tags, :swap],
      %{
        duration_us: duration_us,
        ipv4_prefixes: s.ipv4_prefixes,
        ipv6_prefixes: s.ipv6_prefixes,
        total_prefixes: s.total_prefixes
      },
      %{source: source, version: version}
    )

    version
  end

  @doc "Clear every source trie (tests)."
  @spec clear() :: :ok
  def clear do
    Enum.each(sources(), &clear/1)
    :persistent_term.put(@sources_key, MapSet.new())
    :ok
  end

  @doc "Clear one source's trie."
  @spec clear(source()) :: :ok
  def clear(source) when is_binary(source) do
    previous = active_version(source)
    empty = engine().build([])
    version = next_version(source)
    :persistent_term.put(version_key(source, version), empty)
    :persistent_term.put(active_key(source), version)

    if is_integer(previous) and previous != version do
      schedule_erase(source, previous)
    end

    unregister_source(source)
    :ok
  end

  @doc """
  Active sources that currently have a registered trie.

  Unordered (hot path). Use `Enum.sort/1` at call sites that need deterministic
  ordering for display.
  """
  @spec sources() :: [source()]
  def sources do
    :persistent_term.get(@sources_key, MapSet.new()) |> MapSet.to_list()
  rescue
    ArgumentError -> []
  end

  @doc "Current active version for a source, or nil."
  @spec active_version(source()) :: version() | nil
  def active_version(source) when is_binary(source) do
    :persistent_term.get(active_key(source), nil)
  rescue
    ArgumentError -> nil
  end

  @doc false
  @spec active_trie(source()) :: Engine.t() | nil
  def active_trie(source) when is_binary(source) do
    case active_version(source) do
      nil -> nil
      version -> :persistent_term.get(version_key(source, version), nil)
    end
  rescue
    ArgumentError -> nil
  end

  # -- internals --------------------------------------------------------------

  defp empty_stats, do: %{ipv4_prefixes: 0, ipv6_prefixes: 0, total_prefixes: 0}

  defp ensure_source(%{source: s} = match, _fallback) when is_binary(s) and s != "", do: match
  defp ensure_source(match, source), do: Map.put(match, :source, source)

  # Skip sort work for the common 0/1-match cases (single-source or empty).
  defp merge_by_specificity([]), do: []
  defp merge_by_specificity([_] = one), do: one

  defp merge_by_specificity(matches) do
    matches
    |> Enum.map(fn match ->
      {{-masklen(Map.get(match, :prefix)), Map.get(match, :source) || ""}, match}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp masklen(prefix) when is_binary(prefix) do
    case String.split(prefix, "/", parts: 2) do
      [_, mask] ->
        case Integer.parse(mask) do
          {n, ""} -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp masklen(_), do: 0

  defp active_key(source), do: {@active_key_prefix, source}
  defp version_key(source, version), do: {@version_key_prefix, source, version}

  defp next_version(source) do
    case active_version(source) do
      nil -> 1
      n when is_integer(n) -> n + 1
    end
  end

  defp schedule_erase(source, previous_version)
       when is_binary(source) and is_integer(previous_version) do
    key = version_key(source, previous_version)
    delay = erase_delay_ms()

    # Detached task: never block the swap path. If the BEAM exits sooner the
    # term dies with the VM. Only erase if this version is still not active.
    _ =
      Task.start(fn ->
        Process.sleep(delay)

        case active_version(source) do
          ^previous_version ->
            :ok

          _ ->
            :persistent_term.erase(key)
        end
      end)

    :ok
  end

  defp erase_delay_ms do
    Application.get_env(:serviceradar_core, :prefix_tags_erase_delay_ms, @erase_delay_ms)
  end

  defp register_source(source) do
    set = :persistent_term.get(@sources_key, MapSet.new())
    :persistent_term.put(@sources_key, MapSet.put(set, source))
  rescue
    ArgumentError ->
      :persistent_term.put(@sources_key, MapSet.new([source]))
  end

  defp unregister_source(source) do
    set = :persistent_term.get(@sources_key, MapSet.new())
    :persistent_term.put(@sources_key, MapSet.delete(set, source))
  rescue
    ArgumentError -> :ok
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
