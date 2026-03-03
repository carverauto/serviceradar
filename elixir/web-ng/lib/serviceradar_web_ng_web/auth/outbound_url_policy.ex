defmodule ServiceRadarWebNGWeb.Auth.OutboundURLPolicy do
  @moduledoc """
  Shared outbound URL validation for auth-related metadata/JWKS fetches.
  """

  import Bitwise

  @private_ipv4_cidrs [
    {{10, 0, 0, 0}, 8},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16}
  ]

  @doc """
  Validates a URL string and returns a normalized URI if allowed.
  """
  def validate(url) when is_binary(url) do
    with {:ok, uri} <- parse_url(url),
         :ok <- validate_scheme(uri),
         :ok <- validate_host(uri) do
      {:ok, uri}
    end
  end

  def validate(_), do: {:error, :invalid_url}

  @doc """
  Conservative request options for outbound metadata/JWKS calls.
  """
  def req_opts do
    [connect_options: [timeout: 5_000], receive_timeout: 10_000, redirect: false]
  end

  defp parse_url(url) do
    trimmed = String.trim(url)
    uri = URI.parse(trimmed)

    cond do
      trimmed == "" -> {:error, :invalid_url}
      is_nil(uri.scheme) or is_nil(uri.host) -> {:error, :invalid_url}
      true -> {:ok, uri}
    end
  end

  defp validate_scheme(%URI{scheme: scheme}) do
    insecure_allowed? =
      Application.get_env(:serviceradar_web_ng, :allow_insecure_metadata_urls, false)

    case String.downcase(scheme || "") do
      "https" ->
        :ok

      "http" when insecure_allowed? ->
        :ok

      _ ->
        {:error, :disallowed_scheme}
    end
  end

  defp validate_host(%URI{host: host}) when is_binary(host) do
    host_down = String.downcase(host)

    cond do
      host_down in ["localhost", "localhost.localdomain"] ->
        {:error, :disallowed_host}

      String.ends_with?(host_down, ".local") ->
        {:error, :disallowed_host}

      true ->
        validate_host_address(host_down)
    end
  end

  defp validate_host(_), do: {:error, :invalid_url}

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
        if Enum.any?(all_addrs, &private_or_loopback_ip?/1), do: {:error, :disallowed_host}, else: :ok

      {{:ok, v4}, _} ->
        if Enum.any?(v4, &private_or_loopback_ip?/1), do: {:error, :disallowed_host}, else: :ok

      {_, {:ok, v6}} ->
        if Enum.any?(v6, &private_or_loopback_ip?/1), do: {:error, :disallowed_host}, else: :ok

      _ ->
        # Fail-closed: if DNS resolution fails entirely, deny the request
        {:error, :dns_resolution_failed}
    end
  end

  defp private_or_loopback_ip?({_, _, _, _} = ip) do
    Enum.any?(@private_ipv4_cidrs, fn {base, bits} -> in_cidr?(ip, base, bits) end)
  end

  defp private_or_loopback_ip?({_, _, _, _, _, _, _, _} = ip) do
    private_or_loopback_ipv6?(ip)
  end

  defp private_or_loopback_ip?(_), do: true

  defp private_or_loopback_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_or_loopback_ipv6?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_or_loopback_ipv6?({0xFE80, _, _, _, _, _, _, _}), do: true
  defp private_or_loopback_ipv6?({0xFC00, _, _, _, _, _, _, _}), do: true
  defp private_or_loopback_ipv6?({0xFD00, _, _, _, _, _, _, _}), do: true

  # fc00::/7 — match any address where the top 7 bits are 1111110
  defp private_or_loopback_ipv6?({w1, _, _, _, _, _, _, _}) when Bitwise.band(w1, 0xFE00) == 0xFC00,
    do: true

  defp private_or_loopback_ipv6?(_), do: false

  defp in_cidr?(ip, base, bits) do
    mask = Bitwise.bnot((1 <<< (32 - bits)) - 1) &&& 0xFFFFFFFF
    ip_int = ipv4_to_int(ip)
    base_int = ipv4_to_int(base)
    (ip_int &&& mask) == (base_int &&& mask)
  end

  defp ipv4_to_int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d
end
