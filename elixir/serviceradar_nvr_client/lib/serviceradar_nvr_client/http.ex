defmodule ServiceRadarNVRClient.HTTP do
  @moduledoc false
  alias ServiceRadarNVRClient.Config
  alias ServiceRadarNVRClient.Wire
  alias ServiceRadarRecordingMetadata.Descriptor

  @max_body 67_108_864
  @max_response 32_768
  # A ledger page of 100 blocks or a 50-block lookup, with room to spare.
  @max_member_response 262_144
  @empty_response %{status: nil, body: "", done: false, limit: @max_response}

  def send_recording(config, header, bytes, units, deadline, owner) do
    connect(config, deadline, owner, &transmit(&1, config.token, header, bytes, units, deadline, owner))
  end

  def archive_block(config, block_id, request, body, deadline, owner) do
    connect(config, deadline, owner, &request_archive(&1, config.token, block_id, request, body, deadline, owner))
  end

  def block_descriptor(config, block_id, deadline, owner) do
    path = "/v1/blocks/" <> block_id <> "/descriptor"
    finish = &descriptor_result(&1, &2, block_id)
    connect(config, deadline, owner, &get(&1, config.token, path, Descriptor.max_json_bytes(), finish, deadline, owner))
  end

  # Bounded JSON exchanges on the ingest listener: member status, block lookup
  # and ledger pages. `finish` decodes and checks a 200 body.
  def get_json(config, path, finish, deadline, owner) do
    connect(config, deadline, owner, &get(&1, config.token, path, @max_member_response, finish, deadline, owner))
  end

  def post_json(config, path, content_type, body, finish, deadline, owner) do
    connect(config, deadline, owner, &post(&1, config.token, path, content_type, body, finish, deadline, owner))
  end

  # The body may be at most `expected.length` bytes; `Wire.media` checks it exactly.
  def read_media(config, path, expected, deadline, owner) do
    finish = &media_result(&1, &2, expected)
    connect(config, deadline, owner, &get(&1, config.token, path, expected.length, finish, deadline, owner))
  end

  defp connect(config, deadline, owner, exchange) do
    with {:ok, pem} <- Config.read(config.ca, 65_536),
         [_ | _] = ca <- for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der),
         :ok <- current(deadline, owner),
         {:ok, connection} <- Mint.HTTP1.connect(:https, config.host, config.port, options(config, ca, deadline)) do
      try do
        exchange.(connection)
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
         {:ok, connection} <- send_unsealed(connection, ref, bytes, deadline, owner),
         {:ok, connection, _} <- stream(units, connection, ref, byte_size(bytes), deadline, owner),
         :ok <- current(deadline, owner),
         {:ok, connection} <- send_unsealed(connection, ref, <<0::32>>, deadline, owner),
         {:ok, connection} <- Mint.HTTP1.stream_request_body(connection, ref, :eof) do
      response(connection, ref, deadline, owner, &ingest_result(&1, &2, header), @empty_response)
    else
      {:halted, result} -> result
      _ -> {:error, :outcome_unknown}
    end
  end

  defp ingest_result(200, body, header), do: Wire.receipt(body, header)
  defp ingest_result(status, _body, _header), do: {:error, {:ingest_status, status}}

  # Sends one chunk before HTTP body completion. The NVR seals the final block
  # only after it reads the end marker and that completion, so a response here
  # refuses an unfinished stream: the NVR answers and stops reading. Poll
  # without blocking before each send so the answer is read from this
  # connection, not lost when a later send fails on the closed socket.
  defp send_unsealed(connection, ref, chunk, deadline, owner) do
    case Mint.HTTP1.recv(connection, 0, 0) do
      {:error, connection, %Mint.TransportError{reason: :timeout}, []} ->
        case Mint.HTTP1.stream_request_body(connection, ref, chunk) do
          {:ok, connection} -> {:ok, connection}
          {:error, connection, _reason} -> {:halted, buffered_refusal(connection, ref, deadline, owner)}
        end

      {:ok, connection, events} ->
        {:halted, refusal(connection, ref, events, deadline, owner)}

      _ ->
        {:halted, {:error, :outcome_unknown}}
    end
  end

  # One non-blocking read after a failed send. Mint closes the socket when a
  # send fails with :closed, so that case stays an unknown outcome.
  defp buffered_refusal(connection, ref, deadline, owner) do
    case Mint.HTTP1.recv(connection, 0, 0) do
      {:ok, connection, events} -> refusal(connection, ref, events, deadline, owner)
      _ -> {:error, :outcome_unknown}
    end
  end

  defp refusal(connection, ref, events, deadline, owner),
    do: received(connection, ref, events, deadline, owner, &refusal_result/2, @empty_response)

  # A 200 before the end marker cannot be a seal, so it proves nothing.
  defp refusal_result(status, _body) when is_integer(status) and status != 200, do: {:error, {:ingest_refused, status}}
  defp refusal_result(_status, _body), do: {:error, :outcome_unknown}

  defp request_archive(connection, token, block_id, request, body, deadline, owner) do
    headers = [
      {"authorization", "Bearer " <> token},
      {"content-type", "application/vnd.serviceradar.nvr-archive.v1+json"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    with :ok <- current(deadline, owner),
         {:ok, connection, ref} <-
           Mint.HTTP1.request(connection, "POST", "/v1/blocks/" <> block_id <> "/archive", headers, body) do
      response(connection, ref, deadline, owner, &archive_result(&1, &2, block_id, request), @empty_response)
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  defp archive_result(200, body, block_id, request), do: Wire.archive_receipt(body, block_id, request)

  defp archive_result(status, body, _block_id, _request) when is_integer(status),
    do: {:error, {:archive_status, status, Wire.error_body(body)}}

  defp archive_result(_status, _body, _block_id, _request), do: {:error, :outcome_unknown}

  defp post(connection, token, path, content_type, body, finish, deadline, owner) do
    headers = [
      {"authorization", "Bearer " <> token},
      {"content-type", content_type},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    with :ok <- current(deadline, owner),
         {:ok, connection, ref} <- Mint.HTTP1.request(connection, "POST", path, headers, body) do
      response(connection, ref, deadline, owner, finish, %{@empty_response | limit: @max_member_response})
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  defp get(connection, token, path, limit, finish, deadline, owner) do
    headers = [{"authorization", "Bearer " <> token}]

    with :ok <- current(deadline, owner),
         {:ok, connection, ref} <- Mint.HTTP1.request(connection, "GET", path, headers, nil) do
      response(connection, ref, deadline, owner, finish, %{@empty_response | limit: max(limit, @max_response)})
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  defp descriptor_result(200, body, block_id), do: Wire.descriptor(body, block_id)

  defp descriptor_result(status, body, _block_id) when is_integer(status),
    do: {:error, {:descriptor_status, status, Wire.error_body(body)}}

  defp descriptor_result(_status, _body, _block_id), do: {:error, :outcome_unknown}

  defp media_result(200, body, expected), do: Wire.media(body, expected)
  defp media_result(status, body, _expected) when is_integer(status), do: Wire.read_refusal(status, body)
  defp media_result(_status, _body, _expected), do: {:error, :outcome_unknown}

  defp stream(units, connection, ref, size, deadline, owner) do
    Enum.reduce_while(units, {:ok, connection, size}, fn unit, {:ok, connection, size} ->
      with :ok <- current(deadline, owner),
           {:ok, bytes} <- Wire.unit(unit),
           true <- size + byte_size(bytes) + 4 <= @max_body,
           {:ok, connection} <- send_unsealed(connection, ref, bytes, deadline, owner) do
        {:cont, {:ok, connection, size + byte_size(bytes)}}
      else
        {:halted, _result} = halted -> {:halt, halted}
        _ -> {:halt, {:error, :outcome_unknown}}
      end
    end)
  end

  defp response(connection, ref, deadline, owner, finish, response) do
    with :ok <- current(deadline, owner),
         {:ok, connection, events} <- Mint.HTTP1.recv(connection, 0, remaining(deadline)) do
      received(connection, ref, events, deadline, owner, finish, response)
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  defp received(connection, ref, events, deadline, owner, finish, response) do
    case accumulate(events, ref, response) do
      {:ok, %{done: true, status: status, body: body}} -> finish.(status, body)
      {:ok, response} -> response(connection, ref, deadline, owner, finish, response)
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

        {:data, ^ref, bytes} when byte_size(acc.body) + byte_size(bytes) <= acc.limit ->
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
