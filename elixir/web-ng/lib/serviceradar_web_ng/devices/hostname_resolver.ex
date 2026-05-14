defmodule ServiceRadarWebNG.Devices.HostnameResolver do
  @moduledoc """
  Resolves a device hostname to a canonical IP address for manual inventory entries.
  """

  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve(hostname) when is_binary(hostname) do
    hostname = String.trim(hostname)

    if hostname == "" do
      {:error, :blank_hostname}
    else
      resolve_non_empty(hostname)
    end
  end

  def resolve(_hostname), do: {:error, :invalid_hostname}

  defp resolve_non_empty(hostname) do
    charlist = String.to_charlist(hostname)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        {:ok, ip_to_string(ip)}

      {:error, _reason} ->
        resolve_dns_name(charlist)
    end
  end

  defp resolve_dns_name(charlist) do
    with {:error, _reason} <- resolve_family(charlist, :inet) do
      resolve_family(charlist, :inet6)
    end
  end

  defp resolve_family(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, [ip | _rest]} -> {:ok, ip_to_string(ip)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ip_to_string(ip), do: ip |> :inet.ntoa() |> to_string()
end
