defmodule ServiceRadar.HTTP.EgressReqAdapter do
  @moduledoc """
  Req transport for small signed service requests through the egress proxy.

  Req runs authentication steps, including SigV4, before the adapter. Headers
  and body bytes pass unchanged to the CONNECT-compatible transport. Streaming
  artifact downloads continue to use EgressClient directly.
  """

  alias ServiceRadar.HTTP.EgressClient

  def run(%Req.Request{} = request) do
    headers = for {name, values} <- request.headers, value <- values, do: {name, value}

    opts =
      request
      |> Req.Request.get_private(:egress_options, [])
      |> Keyword.merge(
        headers: headers,
        body: request.body || "",
        receive_timeout: Req.Request.get_option(request, :receive_timeout, 60_000),
        max_bytes: 2_000_000
      )

    case EgressClient.request_buffered(request.method, URI.to_string(request.url), opts) do
      {:ok, response} -> {request, response}
      {:error, %{__exception__: true} = error} -> {request, error}
      {:error, reason} -> {request, Req.TransportError.exception(reason: reason)}
    end
  end
end
