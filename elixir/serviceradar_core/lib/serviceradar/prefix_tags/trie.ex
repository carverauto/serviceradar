defmodule ServiceRadar.PrefixTags.Trie do
  @moduledoc """
  Pure-Elixir longest-prefix-match trie for IPv4 and IPv6.

  Nodes are nested maps keyed by bit (`0` | `1`). Prefixes may store tags at any
  bit-depth; a lookup walks the address bits and accumulates every matching
  node, then reverses the chain so the most-specific match is first.

  This module implements `ServiceRadar.PrefixTags.Engine` and is intentionally
  free of process state and database access — `:persistent_term` storage and
  loaders live in `ServiceRadar.PrefixTags.Store` / `Loader`.
  """

  @behaviour ServiceRadar.PrefixTags.Engine

  import Bitwise

  @type entry :: %{
          required(:prefix) => String.t(),
          required(:tags) => [String.t()],
          optional(:source) => String.t() | nil,
          optional(:vrf) => String.t() | nil,
          optional(:severity) => non_neg_integer() | nil,
          optional(:indicator_count) => non_neg_integer() | nil,
          optional(:expires_at) => DateTime.t() | nil,
          optional(:feed_sources) => [String.t()] | nil,
          optional(:indicators) => [map()] | nil
        }

  @type node_t :: %{
          optional(0) => node_t(),
          optional(1) => node_t(),
          # Multiple entries per mask: same CIDR, distinct VRF (or merged tags).
          optional(:entries) => [entry()]
        }

  @type t :: %{
          ipv4: node_t(),
          ipv6: node_t(),
          ipv4_count: non_neg_integer(),
          ipv6_count: non_neg_integer()
        }

  @empty_node %{}

  @impl true
  def build(rows) when is_list(rows) do
    Enum.reduce(rows, empty(), fn row, acc ->
      case normalize_row(row) do
        {:ok, family, bits, mask, entry} ->
          insert(acc, family, bits, mask, entry)

        :error ->
          acc
      end
    end)
  end

  @impl true
  def lookup(%{} = trie, ip) do
    case parse_ip(ip) do
      {:ok, family, bits} -> lookup_bits(trie, family, bits)
      :error -> []
    end
  end

  def lookup(_invalid, _ip), do: []

  @impl true
  def lookup_bits(%{ipv4: v4}, :ipv4, bits) when is_list(bits), do: walk(v4, bits, [])
  def lookup_bits(%{ipv6: v6}, :ipv6, bits) when is_list(bits), do: walk(v6, bits, [])
  def lookup_bits(_, _, _), do: []

  @impl true
  def parse_ip(ip), do: parse_ip_bits(ip)

  @impl true
  def stats(%{ipv4_count: v4, ipv6_count: v6}) do
    %{
      ipv4_prefixes: v4,
      ipv6_prefixes: v6,
      total_prefixes: v4 + v6
    }
  end

  def stats(_), do: %{ipv4_prefixes: 0, ipv6_prefixes: 0, total_prefixes: 0}

  @doc "Empty trie."
  @spec empty() :: t()
  def empty do
    %{ipv4: @empty_node, ipv6: @empty_node, ipv4_count: 0, ipv6_count: 0}
  end

  # -- internal ---------------------------------------------------------------

  defp insert(acc, :ipv4, bits, mask, entry) do
    {node, added?} = put_bits(acc.ipv4, bits, mask, entry)

    %{
      acc
      | ipv4: node,
        ipv4_count: if(added?, do: acc.ipv4_count + 1, else: acc.ipv4_count)
    }
  end

  defp insert(acc, :ipv6, bits, mask, entry) do
    {node, added?} = put_bits(acc.ipv6, bits, mask, entry)

    %{
      acc
      | ipv6: node,
        ipv6_count: if(added?, do: acc.ipv6_count + 1, else: acc.ipv6_count)
    }
  end

  # Returns {node, added?} — added? is false when an existing same-prefix+vrf
  # entry was updated in place (no new leaf).
  defp put_bits(node, _bits, 0, entry) do
    existing = Map.get(node, :entries, [])
    {entries, added?} = upsert_entry(existing, entry)
    {Map.put(node, :entries, entries), added?}
  end

  defp put_bits(node, [bit | rest], remaining, entry) do
    child = Map.get(node, bit, @empty_node)
    {new_child, added?} = put_bits(child, rest, remaining - 1, entry)
    {Map.put(node, bit, new_child), added?}
  end

  defp upsert_entry(entries, entry) when is_list(entries) do
    vrf_key = entry_vrf_key(entry)

    case Enum.find_index(entries, &(entry_vrf_key(&1) == vrf_key)) do
      nil ->
        {[entry | entries], true}

      idx ->
        prev = Enum.at(entries, idx)
        merged = merge_entry(prev, entry)
        {List.replace_at(entries, idx, merged), false}
    end
  end

  defp entry_vrf_key(%{vrf: vrf}) when is_binary(vrf) and vrf != "", do: vrf
  defp entry_vrf_key(_), do: ""

  defp merge_entry(prev, new) do
    tags =
      (List.wrap(prev[:tags]) ++ List.wrap(new[:tags]))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    severity = max_optional_int(prev[:severity], new[:severity])

    indicator_count =
      case {prev[:indicator_count], new[:indicator_count]} do
        {a, b} when is_integer(a) and is_integer(b) -> a + b
        {a, _} when is_integer(a) -> a
        {_, b} when is_integer(b) -> b
        _ -> nil
      end

    indicators =
      case {List.wrap(prev[:indicators]), List.wrap(new[:indicators])} do
        {[], []} -> nil
        {a, b} -> a ++ b
      end

    feed_sources =
      (List.wrap(prev[:feed_sources]) ++ List.wrap(new[:feed_sources]))
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    # Prefer permanent (nil) expiry; otherwise keep the later expiry so a
    # finite member does not drop a longer-lived peer early.
    expires_at =
      case {prev[:expires_at], new[:expires_at]} do
        {nil, nil} -> nil
        {nil, _} -> nil
        {_, nil} -> nil
        {a, b} -> later_datetime(a, b)
      end

    %{
      prefix: new.prefix,
      tags: tags,
      source: new[:source] || prev[:source],
      vrf: new[:vrf] || prev[:vrf]
    }
    |> maybe_put_severity(severity)
    |> maybe_put(:indicator_count, indicator_count)
    |> maybe_put(:expires_at, expires_at)
    |> maybe_put(:feed_sources, if(feed_sources == [], do: nil, else: feed_sources))
    |> maybe_put(:indicators, indicators)
  end

  defp max_optional_int(a, b) when is_integer(a) and is_integer(b), do: max(a, b)
  defp max_optional_int(a, _) when is_integer(a), do: a
  defp max_optional_int(_, b) when is_integer(b), do: b
  defp max_optional_int(_, _), do: nil

  defp later_datetime(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.after?(a, b), do: a, else: b
  end

  defp later_datetime(a, _) when not is_nil(a), do: a
  defp later_datetime(_, b), do: b

  # Prepend matches as we descend so the deepest (most-specific) entries end up
  # at the head of the list. Nodes may hold multiple VRF variants of a prefix.
  defp walk(node, [], acc) do
    prepend_entries(node, acc)
  end

  defp walk(node, [bit | rest], acc) do
    acc = prepend_entries(node, acc)

    case Map.get(node, bit) do
      nil -> acc
      child -> walk(child, rest, acc)
    end
  end

  defp prepend_entries(node, acc) do
    case Map.get(node, :entries) do
      entries when is_list(entries) and entries != [] ->
        # Keep most-recently-inserted first within the same mask; overall
        # most-specific-first ordering still comes from walk depth.
        entries ++ acc

      _ ->
        # Backward-compat: older tries stored a single :entry.
        case Map.get(node, :entry) do
          nil -> acc
          entry -> [entry | acc]
        end
    end
  end

  defp normalize_row(row) when is_map(row) do
    prefix = row[:prefix] || row["prefix"]
    tags = normalize_tags(row[:tags] || row["tags"])
    source = row[:source] || row["source"]
    vrf = row[:vrf] || row["vrf"]
    severity = normalize_severity(row[:severity] || row["severity"])
    indicator_count = row[:indicator_count] || row["indicator_count"]
    expires_at = row[:expires_at] || row["expires_at"]
    feed_sources = row[:feed_sources] || row["feed_sources"]
    indicators = row[:indicators] || row["indicators"]

    with true <- is_binary(prefix),
         {:ok, family, bits, mask} <- parse_prefix(prefix) do
      entry =
        %{prefix: format_prefix(bits, mask, family), tags: tags, source: source, vrf: vrf}
        |> maybe_put_severity(severity)
        |> maybe_put(:indicator_count, indicator_count)
        |> maybe_put(:expires_at, expires_at)
        |> maybe_put(:feed_sources, feed_sources)
        |> maybe_put(:indicators, indicators)

      {:ok, family, bits, mask, entry}
    else
      _ -> :error
    end
  end

  defp normalize_row(_), do: :error

  defp normalize_tags(nil), do: []
  defp normalize_tags(tags) when is_list(tags), do: Enum.map(tags, &to_string/1)
  defp normalize_tags(tag) when is_binary(tag), do: [tag]
  defp normalize_tags(_), do: []

  defp normalize_severity(n) when is_integer(n) and n >= 0, do: n
  defp normalize_severity(_), do: nil

  defp maybe_put_severity(entry, nil), do: entry
  defp maybe_put_severity(entry, n) when is_integer(n), do: Map.put(entry, :severity, n)

  defp maybe_put(entry, _k, nil), do: entry
  defp maybe_put(entry, k, v), do: Map.put(entry, k, v)

  defp parse_prefix(prefix) when is_binary(prefix) do
    prefix = String.trim(prefix)

    {addr_str, mask_str} =
      case String.split(prefix, "/", parts: 2) do
        [addr] -> {addr, nil}
        [addr, mask] -> {addr, mask}
      end

    with {:ok, family, bits} <- parse_ip_bits(addr_str),
         {:ok, mask} <- parse_mask(family, mask_str) do
      {:ok, family, bits, mask}
    end
  end

  defp parse_ip_bits(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, addr} -> bits_for_address(addr)
      {:error, _} -> :error
    end
  end

  defp parse_ip_bits(addr) when is_tuple(addr), do: bits_for_address(addr)
  defp parse_ip_bits(_), do: :error

  defp bits_for_address({a, b, c, d}) do
    bits =
      for byte <- [a, b, c, d],
          bit <- byte_bits(byte),
          do: bit

    {:ok, :ipv4, bits}
  end

  # IPv4-mapped IPv6 (::ffff:a.b.c.d) — unmap to the IPv4 trie so netbox/provider
  # IPv4 prefixes still match when collectors stringify mapped addresses.
  defp bits_for_address({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    a = hi >>> 8 &&& 0xFF
    b = hi &&& 0xFF
    c = lo >>> 8 &&& 0xFF
    d = lo &&& 0xFF
    bits_for_address({a, b, c, d})
  end

  defp bits_for_address({a, b, c, d, e, f, g, h}) do
    bits =
      for part <- [a, b, c, d, e, f, g, h],
          byte <- [part >>> 8 &&& 0xFF, part &&& 0xFF],
          bit <- byte_bits(byte),
          do: bit

    {:ok, :ipv6, bits}
  end

  defp bits_for_address(_), do: :error

  defp byte_bits(byte) when is_integer(byte) and byte >= 0 and byte <= 255 do
    for shift <- 7..0//-1, do: byte >>> shift &&& 1
  end

  defp parse_mask(:ipv4, nil), do: {:ok, 32}
  defp parse_mask(:ipv6, nil), do: {:ok, 128}

  defp parse_mask(family, mask_str) when is_binary(mask_str) do
    max = if family == :ipv4, do: 32, else: 128

    case Integer.parse(String.trim(mask_str)) do
      {mask, ""} when mask >= 0 and mask <= max -> {:ok, mask}
      _ -> :error
    end
  end

  defp parse_mask(_, _), do: :error

  defp format_prefix(bits, mask, family) do
    addr_bits = Enum.take(bits, mask) ++ List.duplicate(0, bit_width(family) - mask)
    addr = bits_to_address(addr_bits, family)
    ip = addr |> :inet.ntoa() |> to_string()
    "#{ip}/#{mask}"
  end

  defp bit_width(:ipv4), do: 32
  defp bit_width(:ipv6), do: 128

  defp bits_to_address(bits, :ipv4) do
    bytes =
      bits
      |> Enum.chunk_every(8)
      |> Enum.map(fn chunk ->
        Enum.reduce(chunk, 0, fn bit, acc -> acc * 2 + bit end)
      end)

    List.to_tuple(bytes)
  end

  defp bits_to_address(bits, :ipv6) do
    parts =
      bits
      |> Enum.chunk_every(16)
      |> Enum.map(fn chunk ->
        Enum.reduce(chunk, 0, fn bit, acc -> acc * 2 + bit end)
      end)

    List.to_tuple(parts)
  end
end
