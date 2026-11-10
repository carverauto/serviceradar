defmodule ServiceRadarNVR.DeliveryHTTP do
  @moduledoc false

  alias ServiceRadarNVR.DeliveryConfig

  @attempt_timeout 5_000
  @max_ack_bytes 512

  def post(config, bytes) do
    case cacerts(config.ca) do
      {:ok, cacerts} -> connect(config, cacerts, bytes)
      error -> error
    end
  end

  defp cacerts(path) do
    with {:ok, pem} <- DeliveryConfig.bounded_read(path, 65_536),
         [_ | _] = cacerts <- for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      {:ok, cacerts}
    else
      _ -> {:error, :invalid_nvr_delivery_config}
    end
  rescue
    _ -> {:error, :invalid_nvr_delivery_config}
  end

  defp connect(config, cacerts, bytes) do
    options = [
      mode: :passive,
      max_header_list_size: 8_192,
      transport_opts: [
        verify: :verify_peer,
        cacerts: cacerts,
        certfile: String.to_charlist(config.cert),
        keyfile: String.to_charlist(config.key),
        timeout: @attempt_timeout,
        send_timeout: @attempt_timeout,
        send_timeout_close: true
      ]
    ]

    deadline = System.monotonic_time(:millisecond) + @attempt_timeout

    case Mint.HTTP1.connect(:https, config.host, config.port, options) do
      {:ok, connection} ->
        try do
          request(connection, config.token, bytes, deadline)
        after
          Mint.HTTP1.close(connection)
        end

      {:error, _} ->
        {:error, :nvr_delivery_transport}
    end
  end

  defp request(connection, token, bytes, deadline) do
    headers = [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}]

    case Mint.HTTP1.request(connection, "POST", "/v1/local-publication-intents", headers, bytes) do
      {:ok, connection, ref} -> receive_response(connection, ref, deadline, %{status: nil, body: "", done: false})
      {:error, _, _} -> {:error, :nvr_delivery_transport}
    end
  end

  defp receive_response(connection, ref, deadline, response) do
    with remaining when remaining > 0 <- deadline - System.monotonic_time(:millisecond),
         {:ok, connection, events} <- Mint.HTTP1.recv(connection, 0, remaining),
         {:ok, response} <- accumulate(events, ref, response) do
      if response.done, do: result(response), else: receive_response(connection, ref, deadline, response)
    else
      {:error, _} = error -> error
      _ -> {:error, :nvr_delivery_transport}
    end
  end

  defp accumulate(events, ref, response) do
    Enum.reduce_while(events, {:ok, response}, fn event, {:ok, acc} ->
      case event do
        {:status, ^ref, status} when status < 200 or status == 200 ->
          {:cont, {:ok, %{acc | status: status}}}

        {:status, ^ref, status} ->
          {:halt, {:error, {:nvr_delivery_status, status}}}

        {:headers, ^ref, _} ->
          {:cont, {:ok, acc}}

        {:data, ^ref, data} when byte_size(acc.body) + byte_size(data) <= @max_ack_bytes ->
          {:cont, {:ok, %{acc | body: acc.body <> data}}}

        {:done, ^ref} ->
          {:cont, {:ok, %{acc | done: true}}}

        _ ->
          {:halt, {:error, :invalid_publication_acknowledgement}}
      end
    end)
  end

  defp result(%{status: 200, body: body}), do: {:ok, body}
  defp result(%{status: status}), do: {:error, {:nvr_delivery_status, status}}
end
