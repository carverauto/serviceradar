defmodule Palisade.NetworkAddressPolicy do
  @moduledoc """
  Reject loopback, link-local, and private network addresses in
  outbound fetch policies.

  Ported from `ServiceRadar.Policies.NetworkAddressPolicy` and
  `Crm.Policies.NetworkAddressPolicy` (which were verbatim copies
  of each other). Palisade is the canonical home; both consumers
  pin to this module via the `:palisade` mix git dep.

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
    * DNS that resolves to ANY private/loopback address — even a
      single resolved address in the private range rejects the
      whole host. Closes the "DNS rebinding" attack where a
      public-looking host returns a 1-second-TTL private IP at
      fetch time.
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

  defp in_cidr?(ip, base, bits) do
    mask = bnot((1 <<< (32 - bits)) - 1) &&& 0xFFFFFFFF
    ip_int = ipv4_to_int(ip)
    base_int = ipv4_to_int(base)
    (ip_int &&& mask) == (base_int &&& mask)
  end

  defp ipv4_to_int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d
end
