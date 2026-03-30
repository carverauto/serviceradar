defmodule ServiceRadarWebNG.ClientIP do
  @moduledoc """
  Centralized client IP extraction.

  Security default: do not trust `x-forwarded-for` unless explicitly enabled via config.

      config :serviceradar_web_ng, :client_ip,
        trust_x_forwarded_for: true
  """

  import Plug.Conn

  alias ServiceRadar.Policies.NetworkAddressPolicy

  @xff_header "x-forwarded-for"

  @spec get(Plug.Conn.t()) :: String.t()
  def get(%Plug.Conn{} = conn) do
    remote = conn.remote_ip |> :inet.ntoa() |> to_string()

    if trust_x_forwarded_for?() and trusted_proxy?(conn.remote_ip) do
      case get_req_header(conn, @xff_header) do
        [forwarded | _] ->
          forwarded
          |> forwarded_chain()
          |> resolve_forwarded_ip()
          |> valid_ip_or(remote)

        _ ->
          remote
      end
    else
      remote
    end
  end

  defp trust_x_forwarded_for? do
    :serviceradar_web_ng
    |> Application.get_env(:client_ip, [])
    |> Keyword.get(:trust_x_forwarded_for, false)
  end

  defp trusted_proxy_cidrs do
    :serviceradar_web_ng
    |> Application.get_env(:client_ip, [])
    |> Keyword.get(:trusted_proxy_cidrs, [])
  end

  defp trusted_proxy?(ip_tuple) when is_tuple(ip_tuple) do
    NetworkAddressPolicy.ip_in_any_cidr?(ip_tuple, trusted_proxy_cidrs())
  end

  defp trusted_proxy?(_ip), do: false

  defp forwarded_chain(forwarded) when is_binary(forwarded) do
    forwarded
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp resolve_forwarded_ip(chain) when is_list(chain) do
    trusted_proxy_cidrs = trusted_proxy_cidrs()

    chain
    |> Enum.reverse()
    |> Enum.find_value(&untrusted_forwarded_ip(&1, trusted_proxy_cidrs))
  end

  defp untrusted_forwarded_ip(candidate, trusted_proxy_cidrs) do
    case parse_ip(candidate) do
      {:ok, ip} -> forwarded_ip_if_untrusted(candidate, ip, trusted_proxy_cidrs)
      :error -> nil
    end
  end

  defp forwarded_ip_if_untrusted(candidate, ip, trusted_proxy_cidrs) do
    if NetworkAddressPolicy.ip_in_any_cidr?(ip, trusted_proxy_cidrs), do: nil, else: candidate
  end

  defp parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> :error
    end
  end

  defp valid_ip_or(ip, fallback) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> ip
      {:error, _} -> fallback
    end
  end
end
