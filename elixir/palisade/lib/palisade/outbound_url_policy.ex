defmodule Palisade.OutboundURLPolicy do
  @moduledoc """
  HTTPS-only, public-host outbound URL validator. Used wherever
  app code follows an admin-supplied URL (SAML IdP metadata,
  OIDC discovery, webhook callbacks).

  Ported from `ServiceRadar.Policies.OutboundURLPolicy` /
  `Crm.Policies.OutboundURLPolicy`. Palisade is the canonical
  home.

  ## Rules

    * Scheme MUST be `https://` (case-insensitive). No `http://`,
      `file://`, `javascript:`, `data:`, etc.
    * Port MUST be allowlisted. The default allowlist is `[443]`;
      callers that intentionally use a non-standard HTTPS port must
      opt in with `allowed_ports: [...]`.
    * Host MUST resolve to a public IP. Loopback, link-local,
      and private CIDRs are rejected via
      `Palisade.NetworkAddressPolicy`.

  ## Usage

      iex> Palisade.OutboundURLPolicy.validate_https_public_url("https://accounts.example.com/.well-known/openid-configuration")
      {:ok, %URI{}}

      iex> Palisade.OutboundURLPolicy.validate_https_public_url("http://idp.example.com/metadata")
      {:error, :disallowed_scheme}

      iex> Palisade.OutboundURLPolicy.validate_https_public_url("https://localhost/metadata")
      {:error, :disallowed_host}
  """

  alias Palisade.NetworkAddressPolicy

  @default_allowed_ports [443]

  @spec validate_https_public_url(String.t(), keyword()) :: {:ok, URI.t()} | {:error, atom()}
  def validate_https_public_url(url, opts \\ [])

  def validate_https_public_url(url, opts) when is_binary(url) do
    with {:ok, uri} <- parse_url(url),
         :ok <- validate_scheme(uri),
         :ok <- validate_port(uri, opts),
         :ok <- validate_host(uri) do
      {:ok, uri}
    end
  end

  def validate_https_public_url(_url, _opts), do: {:error, :invalid_url}

  @doc """
  Like `validate_https_public_url/1` but also resolves the host
  and returns the resolved IP. Use when binding an HTTP request
  to the resolved address (defeats DNS-rebinding by pinning the
  request to the address the policy approved).
  """
  @spec resolve_https_public_url(String.t(), keyword()) ::
          {:ok, %{uri: URI.t(), address: tuple(), host: String.t()}}
          | {:error, atom()}
  def resolve_https_public_url(url, opts \\ [])

  def resolve_https_public_url(url, opts) when is_binary(url) do
    with {:ok, uri} <- parse_url(url),
         :ok <- validate_scheme(uri),
         :ok <- validate_port(uri, opts),
         {:ok, address} <- resolve_host(uri) do
      {:ok, %{uri: uri, address: address, host: uri.host}}
    end
  end

  def resolve_https_public_url(_url, _opts), do: {:error, :invalid_url}

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

  defp validate_port(%URI{scheme: scheme, port: port}, opts) do
    with {:ok, allowed_ports} <- allowed_ports(opts),
         effective_port when is_integer(effective_port) <- port || default_port(scheme),
         true <- effective_port in allowed_ports do
      :ok
    else
      false -> {:error, :disallowed_port}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :disallowed_port}
    end
  end

  defp allowed_ports(opts) when is_list(opts) do
    ports = Keyword.get(opts, :allowed_ports, @default_allowed_ports)

    if is_list(ports) and Enum.all?(ports, &valid_port?/1) do
      {:ok, ports}
    else
      {:error, :disallowed_port}
    end
  end

  defp allowed_ports(_opts), do: {:error, :disallowed_port}

  defp valid_port?(port), do: is_integer(port) and port > 0 and port <= 65_535

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: nil

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
