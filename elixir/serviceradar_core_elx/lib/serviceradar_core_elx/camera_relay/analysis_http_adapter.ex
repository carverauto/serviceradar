defmodule ServiceRadarCoreElx.CameraRelay.AnalysisHTTPAdapter do
  @moduledoc """
  Reference HTTP adapter for relay-scoped analysis worker dispatch.
  """

  @default_timeout_ms 2_000

  def deliver(input, worker, opts \\ []) when is_map(input) and is_map(worker) do
    request_module = Keyword.get(opts, :request_module, Req)
    finch = Keyword.get(opts, :finch, ServiceRadar.Finch)
    endpoint_url = required_string!(worker, :endpoint_url)
    timeout_ms = positive_integer(value(worker, :timeout_ms), @default_timeout_ms)

    req_opts = [
      json: input,
      headers: normalize_headers(value(worker, :headers, %{})),
      finch: finch,
      retry: false,
      receive_timeout: timeout_ms
    ]

    case request_module.post(endpoint_url, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        normalize_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_status, status, normalize_body(body)}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp normalize_response(body) when is_map(body), do: {:ok, [body]}

  defp normalize_response(body) when is_list(body) do
    if Enum.all?(body, &is_map/1) do
      {:ok, body}
    else
      {:error, :invalid_response}
    end
  end

  defp normalize_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> normalize_response(decoded)
      {:error, _reason} -> {:error, :invalid_response}
    end
  end

  defp normalize_response(_body), do: {:error, :invalid_response}

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {key, value} -> {to_string(key), to_string(value)}
      other -> {"x-invalid-header", inspect(other)}
    end)
  end

  defp normalize_headers(_headers), do: []

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body) when is_map(body) or is_list(body), do: body
  defp normalize_body(body), do: inspect(body)

  defp normalize_error({:timeout, _}), do: :timeout
  defp normalize_error(reason), do: reason

  defp required_string!(map, key) do
    case map |> value(key, "") |> to_string() |> String.trim() do
      "" -> raise ArgumentError, "#{key} is required"
      value -> value
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
