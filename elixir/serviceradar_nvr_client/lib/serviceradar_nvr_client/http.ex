defmodule ServiceRadarNVRClient.HTTP do
  @moduledoc false
  alias ServiceRadarNVRClient.Config
  alias ServiceRadarNVRClient.Wire

  @max_body 67_108_864
  @max_response 32_768

  def send_recording(config, header, bytes, units, deadline, owner) do
    with {:ok, pem} <- Config.read(config.ca, 65_536),
         [_ | _] = ca <- for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der),
         :ok <- current(deadline, owner),
         {:ok, connection} <- Mint.HTTP1.connect(:https, config.host, config.port, options(config, ca, deadline)) do
      try do
        transmit(connection, config.token, header, bytes, units, deadline, owner)
      after
        Mint.HTTP1.close(connection)
      end
    else
      _ -> {:error, :outcome_unknown}
    end
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp options(config, ca, deadline) do
    [
      mode: :passive,
      max_header_list_size: 8_192,
      transport_opts: [
        verify: :verify_peer,
        cacerts: ca,
        certfile: String.to_charlist(config.cert),
        keyfile: String.to_charlist(config.key),
        timeout: min(5000, remaining(deadline)),
        send_timeout: min(5000, remaining(deadline)),
        send_timeout_close: true
      ]
    ]
  end

  defp transmit(connection, token, header, bytes, units, deadline, owner) do
    headers = [{"authorization", "Bearer " <> token}, {"content-type", "application/vnd.serviceradar.nvr-ingest.v1"}]

    with {:ok, connection, ref} <- Mint.HTTP1.request(connection, "POST", "/v1/recordings/ingest", headers, :stream),
         {:ok, connection} <- Mint.HTTP1.stream_request_body(connection, ref, bytes),
         {:ok, connection, _} <- stream(units, connection, ref, byte_size(bytes), deadline, owner),
         :ok <- current(deadline, owner),
         {:ok, connection} <- Mint.HTTP1.stream_request_body(connection, ref, <<0::32>>),
         {:ok, connection} <- Mint.HTTP1.stream_request_body(connection, ref, :eof) do
      response(connection, ref, header, deadline, owner, %{status: nil, body: "", done: false})
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  defp stream(units, connection, ref, size, deadline, owner) do
    Enum.reduce_while(units, {:ok, connection, size}, fn unit, {:ok, connection, size} ->
      with :ok <- current(deadline, owner),
           {:ok, bytes} <- Wire.unit(unit),
           true <- size + byte_size(bytes) + 4 <= @max_body,
           {:ok, connection} <- Mint.HTTP1.stream_request_body(connection, ref, bytes) do
        {:cont, {:ok, connection, size + byte_size(bytes)}}
      else
        _ -> {:halt, {:error, :outcome_unknown}}
      end
    end)
  end

  defp response(connection, ref, header, deadline, owner, response) do
    with :ok <- current(deadline, owner),
         {:ok, connection, events} <- Mint.HTTP1.recv(connection, 0, remaining(deadline)),
         {:ok, response} <- accumulate(events, ref, response) do
      case response do
        %{done: true, status: 200, body: body} -> Wire.receipt(body, header)
        %{done: true, status: status} -> {:error, {:ingest_status, status}}
        response -> response(connection, ref, header, deadline, owner, response)
      end
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  defp accumulate(events, ref, response) do
    Enum.reduce_while(events, {:ok, response}, fn event, {:ok, acc} ->
      case event do
        {:status, ^ref, status} ->
          {:cont, {:ok, %{acc | status: status}}}

        {:headers, ^ref, _} ->
          {:cont, {:ok, acc}}

        {:data, ^ref, bytes} when byte_size(acc.body) + byte_size(bytes) <= @max_response ->
          {:cont, {:ok, %{acc | body: acc.body <> bytes}}}

        {:done, ^ref} ->
          {:cont, {:ok, %{acc | done: true}}}

        _ ->
          {:halt, {:error, :outcome_unknown}}
      end
    end)
  end

  defp current(deadline, owner) do
    receive do
      {:DOWN, ^owner, :process, _, _} -> {:error, :caller_lost}
    after
      0 -> if remaining(deadline) > 0, do: :ok, else: {:error, :deadline}
    end
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
