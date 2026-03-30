defmodule ServiceRadar.Policies.OutboundURLPolicy do
  @moduledoc """
  Shared outbound URL validation helpers for HTTPS-only requests to public hosts.
  """

  alias ServiceRadar.Policies.NetworkAddressPolicy

  @spec validate_https_public_url(String.t()) :: {:ok, URI.t()} | {:error, atom()}
  def validate_https_public_url(url) when is_binary(url) do
    with {:ok, uri} <- parse_url(url),
         :ok <- validate_scheme(uri),
         :ok <- validate_host(uri) do
      {:ok, uri}
    end
  end

  def validate_https_public_url(_url), do: {:error, :invalid_url}

  @spec resolve_https_public_url(String.t()) ::
          {:ok, %{uri: URI.t(), address: tuple(), host: String.t()}} | {:error, atom()}
  def resolve_https_public_url(url) when is_binary(url) do
    with {:ok, uri} <- parse_url(url),
         :ok <- validate_scheme(uri),
         {:ok, address} <- resolve_host(uri) do
      {:ok, %{uri: uri, address: address, host: uri.host}}
    end
  end

  def resolve_https_public_url(_url), do: {:error, :invalid_url}

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
    case String.downcase(scheme || "") do
      "https" -> :ok
      _ -> {:error, :disallowed_scheme}
    end
  end

  defp validate_host(%URI{host: host}) when is_binary(host) do
    NetworkAddressPolicy.validate_public_host(host)
  end

  defp validate_host(_uri), do: {:error, :invalid_url}

  defp resolve_host(%URI{host: host}) when is_binary(host) do
    case NetworkAddressPolicy.resolve_public_host(host) do
      {:ok, [address | _]} -> {:ok, address}
      {:ok, []} -> {:error, :dns_resolution_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_host(_uri), do: {:error, :invalid_url}
end
