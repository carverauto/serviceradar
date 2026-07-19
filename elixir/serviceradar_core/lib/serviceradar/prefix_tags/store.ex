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
  # Single atomic handle: one persistent_term get returns {version, trie}.
  # Do NOT also store a full second copy under a version-only key (doubles memory).
  @active_handle_key_prefix {__MODULE__, :active_handle}
  # Previous handles kept briefly so a concurrent reader that already held the
  # old term can finish; not used for lookup indirection.
  @stale_handle_key_prefix {__MODULE__, :stale_handle}
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
    eng = engine()
    parsed = parse_ip(eng, ip)

    result =
      sources()
      |> Enum.flat_map(fn source ->
        case active_trie(source) do
          nil -> []
          trie -> lookup_trie(eng, trie, ip, parsed, source)
        end
      end)
      |> merge_by_specificity()

    # Sampled telemetry: full rate is too hot on the EventWriter path.
    if :erlang.phash2(ip, 32) == 0 do
      emit_lookup_telemetry(result)
    end

    result
  end

  @doc "Look up against a single source (empty if that source has no trie)."
  @spec lookup(Engine.ip(), source()) :: [Engine.tag_match()]
  def lookup(ip, source) when is_binary(source) do
    eng = engine()

    case active_trie(source) do
      nil -> []
      trie -> lookup_trie(eng, trie, ip, parse_ip(eng, ip), source)
    end
  end

  @doc """
  True when a source has an installed trie (even if empty after an explicit clear).

  Distinguishes "never loaded" (nil active handle) from "loaded with zero prefixes".
  """
  @spec loaded?(source()) :: boolean()
  def loaded?(source) when is_binary(source) do
    match?({_v, _trie}, active_handle(source))
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
    previous_handle = active_handle(source)
    handle = {version, trie}

    # One put: readers do a single get of the active handle (atomic swap).
    :persistent_term.put(active_handle_key(source), handle)
    register_source(source)

    case previous_handle do
      {prev_v, _prev_trie} when prev_v != version ->
        schedule_erase_stale(source, prev_v, previous_handle)

      _ ->
        :ok
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
    previous_handle = active_handle(source)
    empty = engine().build([])
    version = next_version(source)
    handle = {version, empty}
    :persistent_term.put(active_handle_key(source), handle)

    case previous_handle do
      {prev_v, _} when prev_v != version ->
        schedule_erase_stale(source, prev_v, previous_handle)

      _ ->
        :ok
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
    @sources_key |> :persistent_term.get(MapSet.new()) |> MapSet.to_list()
  rescue
    ArgumentError -> []
  end

  @doc "Current active version for a source, or nil."
  @spec active_version(source()) :: version() | nil
  def active_version(source) when is_binary(source) do
    case active_handle(source) do
      {version, _} -> version
      _ -> nil
    end
  end

  @doc false
  @spec active_trie(source()) :: Engine.t() | nil
  def active_trie(source) when is_binary(source) do
    case active_handle(source) do
      {_version, trie} -> trie
      _ -> nil
    end
  end

  defp active_handle(source) do
    :persistent_term.get(active_handle_key(source), nil)
  rescue
    ArgumentError -> nil
  end

  # -- internals --------------------------------------------------------------

  defp empty_stats, do: %{ipv4_prefixes: 0, ipv6_prefixes: 0, total_prefixes: 0}

  defp parse_ip(eng, ip) do
    if function_exported?(eng, :parse_ip, 1) do
      eng.parse_ip(ip)
    else
      :error
    end
  end

  defp lookup_trie(eng, trie, ip, parsed, source) do
    matches =
      case parsed do
        {:ok, family, bits} when is_list(bits) ->
          if function_exported?(eng, :lookup_bits, 3) do
            eng.lookup_bits(trie, family, bits)
          else
            eng.lookup(trie, ip)
          end

        _ ->
          eng.lookup(trie, ip)
      end

    Enum.map(matches, &ensure_source(&1, source))
  end

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

  defp active_handle_key(source), do: {@active_handle_key_prefix, source}
  defp stale_handle_key(source, version), do: {@stale_handle_key_prefix, source, version}

  defp next_version(source) do
    case active_version(source) do
      nil -> 1
      n when is_integer(n) -> n + 1
    end
  end

  # Park the previous handle under a short-lived key so GC of the large term is
  # delayed (readers may still hold the old term). Not used for lookups.
  defp schedule_erase_stale(source, previous_version, previous_handle)
       when is_binary(source) and is_integer(previous_version) do
    key = stale_handle_key(source, previous_version)
    :persistent_term.put(key, previous_handle)
    delay = erase_delay_ms()

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
