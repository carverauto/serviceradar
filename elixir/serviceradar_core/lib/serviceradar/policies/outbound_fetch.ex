defmodule ServiceRadar.Policies.OutboundFetch do
  @moduledoc """
  Shared outbound HTTP helper for HTTPS requests to validated public hosts.

  Requests are bound to the already-validated resolved IP address while keeping
  TLS hostname verification and Host semantics tied to the original hostname.
  """

  alias Req.Request
  alias ServiceRadar.Policies.NetworkAddressPolicy
  alias ServiceRadar.Policies.OutboundURLPolicy

  @type request_target :: %{uri: URI.t(), address: tuple(), host: String.t()}

  @spec get(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t() | atom()}
  def get(url, opts \\ []) when is_binary(url) do
    request(:get, url, opts)
  end

  @spec post(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t() | atom()}
  def post(url, opts \\ []) when is_binary(url) do
    request(:post, url, opts)
  end

  @spec request(atom(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t() | atom()}
  def request(method, url, opts \\ []) when is_atom(method) and is_binary(url) do
    with {:ok, request} <- build_request(method, url, opts) do
      case Request.run_request(request) do
        {_request, %Req.Response{} = response} -> {:ok, response}
        {_request, exception} -> {:error, exception}
      end
    end
  end

  @doc false
  @spec build_request(atom(), String.t(), keyword()) ::
          {:ok, Request.t()} | {:error, atom()}
  def build_request(method, url, opts \\ []) when is_atom(method) and is_binary(url) do
    with {:ok, target} <- resolve_target(url, opts) do
      request =
        [method: method, url: request_url(target)]
        |> Req.new()
        |> Req.merge(request_opts(target, opts))
        |> Request.put_header("host", host_header(target.uri))

      {:ok, request}
    end
  end

  defp resolve_target(url, opts) do
    case Keyword.get(opts, :resolved_address) do
      nil ->
        OutboundURLPolicy.resolve_https_public_url(url)

      resolved_address ->
        with {:ok, uri} <- OutboundURLPolicy.validate_https_public_url(url),
             false <- NetworkAddressPolicy.private_or_loopback_ip?(resolved_address) do
          {:ok, %{uri: uri, address: resolved_address, host: uri.host}}
        else
          true -> {:error, :disallowed_host}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp request_url(%{uri: uri, address: address}) do
    %{uri | host: address_to_string(address)}
  end

  defp request_opts(target, opts) do
    opts =
      opts
      |> Keyword.delete(:resolved_address)
      |> Keyword.update(:connect_options, connect_options(target), fn current ->
        Keyword.merge(current, connect_options(target))
      end)

    opts =
      if tuple_size(target.address) == 8 do
        Keyword.put_new(opts, :inet6, true)
      else
        opts
      end

    Keyword.merge(default_req_opts(), opts)
  end

  defp default_req_opts do
    [connect_options: [timeout: 5_000], receive_timeout: 10_000, redirect: false]
  end

  defp connect_options(%{host: host}) do
    [hostname: host, timeout: 5_000]
  end

  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if default_port?(scheme, port), do: host, else: "#{host}:#{port}"
  end

  defp default_port?("https", nil), do: true
  defp default_port?("https", 443), do: true
  defp default_port?("http", nil), do: true
  defp default_port?("http", 80), do: true
  defp default_port?(_, _), do: false

  defp address_to_string(address) do
    address
    |> :inet.ntoa()
    |> to_string()
  end
end
