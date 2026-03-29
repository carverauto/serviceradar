defmodule ServiceRadar.Policies.NetworkAddressPolicy do
  @moduledoc """
  Shared helpers for rejecting loopback, link-local, and private network addresses
  in outbound fetch policies.
  """

  import Bitwise

  @private_ipv4_cidrs [
    {{10, 0, 0, 0}, 8},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16}
  ]

  @spec validate_public_host(String.t()) :: :ok | {:error, atom()}
  def validate_public_host(host) when is_binary(host) do
    host_down = String.downcase(String.trim(host))

    cond do
      host_down == "" ->
        {:error, :invalid_url}

      host_down in ["localhost", "localhost.localdomain"] ->
        {:error, :disallowed_host}

      String.ends_with?(host_down, ".local") ->
        {:error, :disallowed_host}

      true ->
        validate_host_address(host_down)
    end
  end

  def validate_public_host(_host), do: {:error, :invalid_url}

  @spec private_or_loopback_ip?(tuple()) :: boolean()
  def private_or_loopback_ip?({_, _, _, _} = ip) do
    Enum.any?(@private_ipv4_cidrs, fn {base, bits} -> in_cidr?(ip, base, bits) end)
  end

  def private_or_loopback_ip?({_, _, _, _, _, _, _, _} = ip), do: private_or_loopback_ipv6?(ip)
  def private_or_loopback_ip?(_ip), do: true

  defp validate_host_address(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if private_or_loopback_ip?(ip), do: {:error, :disallowed_host}, else: :ok

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
          else: :ok

      {{:ok, v4}, _} ->
        if Enum.any?(v4, &private_or_loopback_ip?/1), do: {:error, :disallowed_host}, else: :ok

      {_, {:ok, v6}} ->
        if Enum.any?(v6, &private_or_loopback_ip?/1), do: {:error, :disallowed_host}, else: :ok

      _ ->
        {:error, :dns_resolution_failed}
    end
  end

  defp private_or_loopback_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_or_loopback_ipv6?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_or_loopback_ipv6?({0xFE80, _, _, _, _, _, _, _}), do: true
  defp private_or_loopback_ipv6?({0xFC00, _, _, _, _, _, _, _}), do: true
  defp private_or_loopback_ipv6?({0xFD00, _, _, _, _, _, _, _}), do: true

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
