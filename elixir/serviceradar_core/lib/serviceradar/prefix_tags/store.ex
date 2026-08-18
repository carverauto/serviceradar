defmodule ServiceRadar.PrefixTags.Store do
  @moduledoc """
  Per-source `:persistent_term` snapshot storage for prefix-tag LPM tries.

  Each tag source (netbox, manual, provider, ti, dns-policy, …) has its own
  versioned trie and swaps independently. Lookups merge most-specific-first
  chains across all active sources with per-tag source provenance. Never write
  per-entry — only full snapshot swaps per source.
  """

  alias ServiceRadar.PrefixTags.Engine
  alias ServiceRadar.PrefixTags.Registry
  alias ServiceRadar.PrefixTags.Trie

  # Single atomic handle: one persistent_term get returns
  # {version, trie, :registered | :cleared}. Keeping registration in the same
  # handle lets Registry reconstruct its enumerable ETS index after a restart.
  @active_handle_key_prefix {__MODULE__, :active_handle}
  # Fingerprints are stored separately so the active trie handle keeps its
  # compatibility shape for Registry recovery. They let a source retain an
  # identical trie without another expensive persistent_term write.
  @active_rows_fingerprint_key_prefix {__MODULE__, :active_rows_fingerprint}
  @active_snapshot_token_key_prefix {__MODULE__, :active_snapshot_token}
  # Don't park a previous persistent_term handle when the outgoing trie is
  # already this large — that briefly doubles literal_alloc and is what OOM'd
  # demo core on the 410k-prefix provider dataset.
  @park_previous_prefix_limit 10_000
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
  True when a source has an installed, registered trie.

  An explicitly cleared source is not loaded. A registered empty trie is loaded,
  which distinguishes a successfully loaded empty snapshot from a missing one.
  """
  @spec loaded?(source()) :: boolean()
  def loaded?(source) when is_binary(source) do
    case active_handle(source) do
      {_version, _trie} -> true
      {_version, _trie, :registered} -> true
      _other -> false
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

  @doc "Build and install rows for a single source. Returns the active version."
  @spec put_rows(source(), [Engine.prefix_row()]) :: version()
  def put_rows(source, rows) when is_binary(source) and is_list(rows) do
    fingerprint = rows_fingerprint(rows)
    started = System.monotonic_time(:microsecond)

    result =
      Registry.with_source_lock(source, fn ->
        if registered_handle?(active_handle(source)) and
             active_rows_fingerprint(source) == fingerprint do
          {:unchanged, active_version(source)}
        else
          trie = engine().build(rows)
          {version, previous_handle} = install_trie(source, trie)
          :persistent_term.put(active_rows_fingerprint_key(source), fingerprint)
          {:installed, version, previous_handle, trie}
        end
      end)

    case result do
      {:unchanged, version} ->
        version

      {:installed, version, previous_handle, trie} ->
        schedule_previous_handle_erase(source, version, previous_handle)
        emit_swap_telemetry(source, version, trie, started)
        version
    end
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

  @doc "Durable snapshot token currently installed for a source, if any."
  @spec snapshot_token(source()) :: binary() | nil
  def snapshot_token(source) when is_binary(source) do
    :persistent_term.get(active_snapshot_token_key(source), nil)
  rescue
    ArgumentError -> nil
  end

  @doc "Record the durable snapshot token that produced the current trie."
  @spec put_snapshot_token(source(), binary() | nil) :: :ok
  def put_snapshot_token(source, nil) when is_binary(source) do
    :persistent_term.erase(active_snapshot_token_key(source))
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put_snapshot_token(source, token) when is_binary(source) and is_binary(token) do
    :persistent_term.put(active_snapshot_token_key(source), token)
    :ok
  end

  @doc "Install a pre-built trie for a source. Returns the new version."
  @spec put_trie(source(), Engine.t()) :: version()
  def put_trie(source, trie) when is_binary(source) do
    started = System.monotonic_time(:microsecond)

    {version, previous_handle} =
      Registry.with_source_lock(source, fn ->
        {version, previous_handle} = install_trie(source, trie)
        :persistent_term.erase(active_rows_fingerprint_key(source))
        :persistent_term.erase(active_snapshot_token_key(source))
        {version, previous_handle}
      end)

    schedule_previous_handle_erase(source, version, previous_handle)
    emit_swap_telemetry(source, version, trie, started)

    version
  end

  @doc "Clear every source trie (tests)."
  @spec clear() :: :ok
  def clear do
    Enum.each(sources(), &clear/1)
    :ok
  end

  @doc "Clear one source's trie."
  @spec clear(source()) :: :ok
  def clear(source) when is_binary(source) do
    empty = engine().build([])

    {version, previous_handle} =
      Registry.with_source_lock(source, fn ->
        version = next_version(source)
        previous_handle = active_handle(source)

        :persistent_term.put(active_handle_key(source), {version, empty, :cleared})
        :persistent_term.erase(active_rows_fingerprint_key(source))
        :persistent_term.erase(active_snapshot_token_key(source))
        Registry.sync_source(source, false)

        {version, previous_handle}
      end)

    schedule_previous_handle_erase(source, version, previous_handle)
    :ok
  end

  @doc """
  Active sources that currently have a registered trie.

  Unordered (hot path). Use `Enum.sort/1` at call sites that need deterministic
  ordering for display.

  Backed by an ETS set so dynamically loaded snapshot/plugin sources are
  discoverable by aggregate `lookup/1` (not only the built-in catalog).
  """
  @spec sources() :: [source()]
  def sources, do: Registry.sources()

  @doc "Current active version for a source, or nil."
  @spec active_version(source()) :: version() | nil
  def active_version(source) when is_binary(source) do
    case active_handle(source) do
      {version, _} -> version
      {version, _, _registration} -> version
      _ -> nil
    end
  end

  @doc false
  @spec active_trie(source()) :: Engine.t() | nil
  def active_trie(source) when is_binary(source) do
    case active_handle(source) do
      {_version, trie} -> trie
      {_version, trie, _registration} -> trie
      _ -> nil
    end
  end

  defp active_handle(source) do
    :persistent_term.get(active_handle_key(source), nil)
  rescue
    ArgumentError -> nil
  end

  defp active_rows_fingerprint(source) do
    :persistent_term.get(active_rows_fingerprint_key(source), nil)
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
  defp active_rows_fingerprint_key(source), do: {@active_rows_fingerprint_key_prefix, source}
  defp active_snapshot_token_key(source), do: {@active_snapshot_token_key_prefix, source}
  defp stale_handle_key(source, version), do: {@stale_handle_key_prefix, source, version}

  defp install_trie(source, trie) do
    version = next_version(source)
    previous_handle = active_handle(source)

    # Registration and the trie swap share one persistent handle, so a
    # Registry restart can recover the exact source state.
    :persistent_term.put(active_handle_key(source), {version, trie, :registered})
    Registry.sync_source(source, true)

    {version, previous_handle}
  end

  defp registered_handle?({_version, _trie}), do: true
  defp registered_handle?({_version, _trie, :registered}), do: true
  defp registered_handle?(_other), do: false

  # Hash each row separately so an unchanged large source can be recognized
  # without building another trie or one giant serialized binary. Source SQL
  # queries use deterministic ordering, so identical durable data has a stable
  # fingerprint.
  defp rows_fingerprint(rows) do
    rows
    |> Enum.reduce(:crypto.hash_init(:sha256), fn row, context ->
      encoded = :erlang.term_to_binary(row, [:deterministic])
      :crypto.hash_update(context, [<<byte_size(encoded)::unsigned-32>>, encoded])
    end)
    |> :crypto.hash_final()
  end

  defp emit_swap_telemetry(source, version, trie, started) do
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
  end

  defp next_version(source) do
    case active_version(source) do
      nil -> 1
      n when is_integer(n) -> n + 1
    end
  end

  defp schedule_previous_handle_erase(source, version, previous_handle) do
    if large_handle?(previous_handle) do
      :ok
    else
      case handle_version(previous_handle) do
        previous_version when is_integer(previous_version) and previous_version != version ->
          schedule_erase_stale(source, previous_version, previous_handle)

        _other ->
          :ok
      end
    end
  end

  defp large_handle?({_version, trie}), do: large_trie?(trie)
  defp large_handle?({_version, trie, _registration}), do: large_trie?(trie)
  defp large_handle?(_), do: false

  defp large_trie?(trie) do
    stats = engine().stats(trie)
    is_integer(stats.total_prefixes) and stats.total_prefixes >= @park_previous_prefix_limit
  rescue
    _ -> false
  end

  defp handle_version({version, _trie}) when is_integer(version), do: version

  defp handle_version({version, _trie, _registration}) when is_integer(version), do: version

  defp handle_version(_other), do: nil

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
