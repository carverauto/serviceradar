defmodule Palisade.NetworkAddressPolicy do
  @moduledoc """
  Reject loopback, link-local, and private network addresses in
  outbound fetch policies.

  ## Blocked

    * IPv4: non-public special-use ranges including private,
      loopback, link-local / metadata service, unspecified,
      CGNAT, protocol-assignment, documentation, benchmarking,
      multicast, and reserved ranges.
    * IPv6: `::1` (loopback), `::` (unspecified), `fc00::/7`
      (unique-local), `fe80::/10` (link-local), `ff00::/8`
      (multicast), and IPv4-mapped IPv6 addresses whose embedded
      IPv4 address is disallowed.
    * Hostnames: `localhost`, `localhost.localdomain`, any
      `*.local` (mDNS).
    * DNS that resolves to ANY private/loopback address - even a
      single resolved address in the private range rejects the
      whole host. Closes the "DNS rebinding" attack where a
      public-looking host returns a 1-second-TTL private IP at
      fetch time.

  `cidr_contains?/2` and `ip_in_any_cidr?/2` match an address against
  caller-supplied CIDRs, for callers that keep their own allow or deny
  lists (trusted proxies, scan scopes). An IPv4-mapped IPv6 address
  (`::ffff:10.0.0.5`) matches the IPv4 CIDRs its embedded address falls
  in, and an IPv4 CIDR written in mapped form (`::ffff:10.0.0.0/104`)
  matches plain IPv4 addresses. A plain IPv4 address does not match a
  native IPv6 CIDR such as `::/0`. Malformed addresses and CIDRs never
  match.
  """

  import Bitwise

  @private_ipv4_cidrs [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{192, 0, 0, 0}, 24},
    {{192, 0, 2, 0}, 24},
    {{192, 88, 99, 0}, 24},
    {{198, 18, 0, 0}, 15},
    {{198, 51, 100, 0}, 24},
    {{203, 0, 113, 0}, 24},
    {{224, 0, 0, 0}, 4},
    {{240, 0, 0, 0}, 4}
  ]

  @spec validate_public_host(String.t()) :: :ok | {:error, atom()}
  def validate_public_host(host) when is_binary(host) do
    case resolve_public_host(host) do
      {:ok, _addresses} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_public_host(_host), do: {:error, :invalid_url}

  @spec resolve_public_host(String.t()) :: {:ok, [tuple()]} | {:error, atom()}
  def resolve_public_host(host) when is_binary(host) do
    host_down = String.downcase(String.trim(host))

    cond do
      host_down == "" ->
        {:error, :invalid_url}

      host_down in ["localhost", "localhost.localdomain"] ->
        {:error, :disallowed_host}

      String.ends_with?(host_down, ".local") ->
        {:error, :disallowed_host}

      true ->
        resolve_host_addresses(host_down)
    end
  end

  def resolve_public_host(_host), do: {:error, :invalid_url}

  @spec private_or_loopback_ip?(tuple()) :: boolean()
  def private_or_loopback_ip?({_, _, _, _} = ip) do
    Enum.any?(@private_ipv4_cidrs, fn {base, bits} -> in_cidr?(ip, base, bits) end)
  end

  def private_or_loopback_ip?({_, _, _, _, _, _, _, _} = ip), do: private_or_loopback_ipv6?(ip)
  def private_or_loopback_ip?(_ip), do: true

  @doc """
  Returns true when `ip` lies inside any of `cidrs`.

  `ip` is an `:inet` address tuple. Each CIDR is a string such as
  `"10.0.0.0/8"` or `"fd00::/8"`; malformed entries are skipped.

      iex> Palisade.NetworkAddressPolicy.ip_in_any_cidr?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 5}, ["10.0.0.0/8"])
      true
  """
  @spec ip_in_any_cidr?(:inet.ip_address(), [String.t()]) :: boolean()
  def ip_in_any_cidr?(ip, cidrs) when is_list(cidrs) do
    Enum.any?(cidrs, &cidr_contains?(ip, &1))
  end

  def ip_in_any_cidr?(_ip, _cidrs), do: false

  @doc """
  Returns true when `ip` lies inside `cidr`.

  See the module documentation for how IPv4-mapped IPv6 addresses are
  matched. Returns false for a malformed address or CIDR, and for a
  prefix length outside the address family's range.
  """
  @spec cidr_contains?(:inet.ip_address(), String.t()) :: boolean()
  def cidr_contains?(ip, cidr) when is_tuple(ip) and is_binary(cidr) do
    with true <- valid_ip?(ip),
         {:ok, {base, bits}} <- parse_cidr(cidr) do
      ip
      |> match_forms()
      |> Enum.any?(&prefix_match?(&1, base, bits))
    else
      _ -> false
    end
  end

  def cidr_contains?(_ip, _cidr), do: false

  defp resolve_host_addresses(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if private_or_loopback_ip?(ip), do: {:error, :disallowed_host}, else: {:ok, [ip]}

      {:error, _} ->
        resolve_and_validate(host)
    end
  end

  defp resolve_and_validate(host) do
    charlist = String.to_charlist(host)
    ipv4 = :inet.getaddrs(charlist, :inet)
    ipv6 = :inet.getaddrs(charlist, :inet6)

    case {ipv4, ipv6} do
      {{:ok, v4}, {:ok, v6}} ->
        all_addrs = v4 ++ v6

        if Enum.any?(all_addrs, &private_or_loopback_ip?/1),
          do: {:error, :disallowed_host},
          else: {:ok, all_addrs}

      {{:ok, v4}, _} ->
        if Enum.any?(v4, &private_or_loopback_ip?/1),
          do: {:error, :disallowed_host},
          else: {:ok, v4}

      {_, {:ok, v6}} ->
        if Enum.any?(v6, &private_or_loopback_ip?/1),
          do: {:error, :disallowed_host},
          else: {:ok, v6}

      _ ->
        {:error, :dns_resolution_failed}
    end
  end

  defp private_or_loopback_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_or_loopback_ipv6?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  defp private_or_loopback_ipv6?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    high_a = high >>> 8
    high_b = high &&& 0xFF
    low_a = low >>> 8
    low_b = low &&& 0xFF

    private_or_loopback_ip?({high_a, high_b, low_a, low_b})
  end

  defp private_or_loopback_ipv6?({0xFE80, _, _, _, _, _, _, _}), do: true
  defp private_or_loopback_ipv6?({0xFC00, _, _, _, _, _, _, _}), do: true
  defp private_or_loopback_ipv6?({0xFD00, _, _, _, _, _, _, _}), do: true

  defp private_or_loopback_ipv6?({w1, _, _, _, _, _, _, _}) when band(w1, 0xFF00) == 0xFF00,
    do: true

  defp private_or_loopback_ipv6?({w1, _, _, _, _, _, _, _}) when band(w1, 0xFE00) == 0xFC00,
    do: true

  defp private_or_loopback_ipv6?(_ip), do: false

  defp parse_cidr(cidr) do
    with [ip_text, bits_text] <- String.split(String.trim(cidr), "/", parts: 2),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(ip_text)),
         {bits, ""} <- Integer.parse(bits_text),
         true <- bits >= 0 and bits <= ip_size_bits(ip) do
      {:ok, normalize_mapped_cidr(ip, bits)}
    else
      _ -> {:error, :invalid_cidr}
    end
  end

  # `::ffff:a.b.c.d/n` with n >= 96 describes an IPv4 range; compare it as one.
  defp normalize_mapped_cidr({0, 0, 0, 0, 0, 0xFFFF, _, _} = ip, bits) when bits >= 96,
    do: {embedded_ipv4(ip), bits - 96}

  defp normalize_mapped_cidr(ip, bits), do: {ip, bits}

  # An IPv4-mapped IPv6 address is compared both as itself and as the IPv4
  # address it carries, so it matches IPv6 and IPv4 CIDRs alike.
  defp match_forms({0, 0, 0, 0, 0, 0xFFFF, _, _} = ip), do: [ip, embedded_ipv4(ip)]
  defp match_forms(ip), do: [ip]

  defp embedded_ipv4({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp prefix_match?(ip, base, bits) when tuple_size(ip) == tuple_size(base) do
    mask = cidr_mask(ip_size_bits(ip), bits)
    (ip_to_int(ip) &&& mask) == (ip_to_int(base) &&& mask)
  end

  defp prefix_match?(_ip, _base, _bits), do: false

  defp valid_ip?({_, _, _, _} = ip), do: valid_parts?(ip, 255)
  defp valid_ip?({_, _, _, _, _, _, _, _} = ip), do: valid_parts?(ip, 0xFFFF)
  defp valid_ip?(_ip), do: false

  defp valid_parts?(ip, max) do
    ip
    |> Tuple.to_list()
    |> Enum.all?(&(is_integer(&1) and &1 >= 0 and &1 <= max))
  end

  defp ip_size_bits({_a, _b, _c, _d}), do: 32
  defp ip_size_bits({_a, _b, _c, _d, _e, _f, _g, _h}), do: 128

  defp cidr_mask(_size_bits, 0), do: 0
  defp cidr_mask(size_bits, bits), do: bnot((1 <<< (size_bits - bits)) - 1)

  defp in_cidr?(ip, base, bits) do
    mask = bnot((1 <<< (32 - bits)) - 1) &&& 0xFFFFFFFF
    ip_int = ipv4_to_int(ip)
    base_int = ipv4_to_int(base)
    (ip_int &&& mask) == (base_int &&& mask)
  end

  defp ipv4_to_int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp ip_to_int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp ip_to_int(ip) when is_tuple(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)
  end
end
