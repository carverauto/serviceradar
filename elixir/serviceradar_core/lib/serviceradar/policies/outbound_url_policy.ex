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
end
