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
          optional(:vrf) => String.t() | nil
        }

  @type node_t :: %{
          optional(0) => node_t(),
          optional(1) => node_t(),
          optional(:entry) => entry()
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
  def lookup(%{ipv4: v4, ipv6: v6}, ip) do
    case parse_ip(ip) do
      {:ok, :ipv4, bits} -> walk(v4, bits, [])
      {:ok, :ipv6, bits} -> walk(v6, bits, [])
      :error -> []
    end
  end

  def lookup(_invalid, _ip), do: []

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
    %{
      acc
      | ipv4: put_bits(acc.ipv4, bits, mask, entry),
        ipv4_count: acc.ipv4_count + 1
    }
  end

  defp insert(acc, :ipv6, bits, mask, entry) do
    %{
      acc
      | ipv6: put_bits(acc.ipv6, bits, mask, entry),
        ipv6_count: acc.ipv6_count + 1
    }
  end

  defp put_bits(node, _bits, 0, entry), do: Map.put(node, :entry, entry)

  defp put_bits(node, [bit | rest], remaining, entry) do
    child = Map.get(node, bit, @empty_node)
    Map.put(node, bit, put_bits(child, rest, remaining - 1, entry))
  end

  # Prepend matches as we descend so the deepest (most-specific) entry ends up
  # at the head of the list. Always check :entry on the current node, including
  # the terminal node when no bits remain (host /32 and /128 prefixes).
  defp walk(node, [], acc) do
    case Map.get(node, :entry) do
      nil -> acc
      entry -> [entry | acc]
    end
  end

  defp walk(node, [bit | rest], acc) do
    acc =
      case Map.get(node, :entry) do
        nil -> acc
        entry -> [entry | acc]
      end

    case Map.get(node, bit) do
      nil -> acc
      child -> walk(child, rest, acc)
    end
  end

  defp normalize_row(row) when is_map(row) do
    prefix = row[:prefix] || row["prefix"]
    tags = normalize_tags(row[:tags] || row["tags"])
    source = row[:source] || row["source"]
    vrf = row[:vrf] || row["vrf"]

    with true <- is_binary(prefix),
         {:ok, family, bits, mask} <- parse_prefix(prefix) do
      entry = %{
        prefix: format_prefix(bits, mask, family),
        tags: tags,
        source: source,
        vrf: vrf
      }

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

  defp parse_prefix(prefix) when is_binary(prefix) do
    prefix = String.trim(prefix)

    {addr_str, mask_str} =
      case String.split(prefix, "/", parts: 2) do
        [addr] -> {addr, nil}
        [addr, mask] -> {addr, mask}
      end

    with {:ok, family, bits} <- parse_ip(addr_str),
         {:ok, mask} <- parse_mask(family, mask_str) do
      {:ok, family, bits, mask}
    end
  end

  defp parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(String.trim(ip))) do
      {:ok, addr} -> bits_for_address(addr)
      {:error, _} -> :error
    end
  end

  defp parse_ip(addr) when is_tuple(addr), do: bits_for_address(addr)
  defp parse_ip(_), do: :error

  defp bits_for_address({a, b, c, d}) do
    bits =
      for byte <- [a, b, c, d],
          bit <- byte_bits(byte),
          do: bit

    {:ok, :ipv4, bits}
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
