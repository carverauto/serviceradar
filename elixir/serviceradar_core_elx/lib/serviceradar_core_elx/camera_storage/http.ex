defmodule ServiceRadarCoreElx.CameraStorage.HTTP do
  @moduledoc """
  One bounded HTTPS exchange for the isolated storage service and its diagnostic.

  The caller owns authorization, signing and the total operation deadline. This
  transport owns its socket, never retries or follows redirects, and buffers at
  most the caller's response ceiling. Provider verification reads use the shared
  exact-range egress contract.
  """

  alias ServiceRadar.HTTP.EgressClient

  @header_limit 16_384

  # This one-shot process owns its sockets. Killing it bounds connect, upload,
  # headers and progressing reads together, including a stalled TLS send.
  def request(config, method, url, headers, body, timeout, max_bytes, range \\ nil) do
    caller = self()
    token = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout

    operation = fn ->
      parent = Process.monitor(caller)
      {:ok, timer} = :timer.exit_after(timeout, self(), :request_timeout)

      receive do
        {:start, ^token} ->
          Process.demonitor(parent, [:flush])

          result =
            try do
              execute(config, method, url, headers, body, timeout, max_bytes, range)
            rescue
              _ -> {:error, :transport_error}
            catch
              _, _ -> {:error, :transport_error}
            after
              :timer.cancel(timer)
            end

          send(caller, {token, result})

        {:DOWN, ^parent, :process, ^caller, _} ->
          :ok
      end
    end

    {pid, monitor} =
      case Map.get(config, :socket_owner) do
        nil ->
          spawn_monitor(operation)

        _ ->
          {:ok, pid} = Task.Supervisor.start_child(ServiceRadarCoreElx.CameraStorage.Tasks, operation)
          {pid, Process.monitor(pid)}
      end

    if register_owner(config, pid, timeout) == :ok do
      send(pid, {:start, token})

      receive do
        {^token, result} ->
          # A task cannot release admission while its socket/file owner survives.
          receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> :ok)
          result

        {:DOWN, ^monitor, :process, ^pid, :request_timeout} ->
          {:error, :request_timeout}

        {:DOWN, ^monitor, :process, ^pid, _} ->
          {:error, :transport_error}
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          stop_owner(pid, monitor)
          receive do: ({^token, _} -> :ok), after: (0 -> :ok)
          {:error, :request_timeout}
      end
    else
      stop_owner(pid, monitor)
      {:error, :request_cancelled}
    end
  end

  defp register_owner(config, pid, timeout) do
    case Map.get(config, :socket_owner) do
      nil -> :ok
      owner -> GenServer.call(owner, {:http_socket_owner, self(), pid}, timeout)
    end
  catch
    :exit, _ -> {:error, :request_cancelled}
  end

  defp stop_owner(pid, monitor) do
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> :ok)
  end

  defp execute(config, :get, url, headers, _body, timeout, max_bytes, {first, last, size, etag}) do
    execute(config, :get, url, headers, nil, timeout, max_bytes, {first, last, size, etag, nil})
  end

  defp execute(config, :get, url, headers, _body, timeout, max_bytes, {first, last, size, etag, version}) do
    EgressClient.fetch_range(url, {first, last},
      expected_size: size,
      expected_etag: etag,
      expected_version: version,
      max_bytes: max_bytes,
      headers: Enum.reject(headers, fn {key, _} -> key in ~w(range if-match accept-encoding) end),
      proxy: config.proxy,
      cacerts: config.cacerts,
      receive_timeout: timeout,
      connect_timeout: timeout
    )
  end

  defp execute(config, method, url, headers, body, timeout, max_bytes, nil) do
    uri = URI.parse(url)

    options = [
      mode: :passive,
      protocols: [:http1],
      max_header_list_size: @header_limit,
      transport_opts: [cacerts: config.cacerts, timeout: timeout] ++ Map.get(config, :client_tls, [])
    ]

    options =
      case config.proxy do
        nil ->
          options

        %{host: host, port: port} ->
          Keyword.put(options, :proxy, {:http, host, port, [tunnel_timeout: timeout]})
      end

    with_result =
      with {:ok, conn} <- Mint.HTTP.connect(:https, uri.host, uri.port, options) do
        try do
          path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

          with {:ok, conn, ref} <- send_request(conn, method, path, headers, body) do
            receive_response(conn, ref, %{status: nil, headers: [], body: [], bytes: 0}, max_bytes, timeout)
          end
        after
          Mint.HTTP.close(conn)
        end
      end

    normalize(with_result)
  end

  defp send_request(conn, method, path, headers, {:file, filename, size}) do
    with {:ok, file} <- File.open(filename, [:read, :binary, :raw]) do
      try do
        with {:ok, conn, ref} <- Mint.HTTP.request(conn, String.upcase(to_string(method)), path, headers, :stream),
             {:ok, conn} <- stream_file(conn, ref, file, size) do
          {:ok, conn, ref}
        end
      after
        File.close(file)
      end
    end
  end

  defp send_request(conn, method, path, headers, body),
    do: Mint.HTTP.request(conn, String.upcase(to_string(method)), path, headers, body)

  defp stream_file(conn, ref, file, 0) do
    case IO.binread(file, 1) do
      :eof -> Mint.HTTP.stream_request_body(conn, ref, :eof)
      _ -> {:error, :request_file_changed}
    end
  end

  defp stream_file(conn, ref, file, remaining) when remaining > 0 do
    case IO.binread(file, min(65_536, remaining)) do
      bytes when is_binary(bytes) and byte_size(bytes) > 0 ->
        with {:ok, conn} <- Mint.HTTP.stream_request_body(conn, ref, bytes),
             do: stream_file(conn, ref, file, remaining - byte_size(bytes))

      _ ->
        {:error, :request_file_changed}
    end
  end

  defp receive_response(conn, ref, response, limit, timeout) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, events} ->
        case Enum.reduce_while(events, {:cont, response}, &event(&1, &2, ref, limit)) do
          {:cont, response} -> receive_response(conn, ref, response, limit, timeout)
          result -> result
        end

      _ ->
        {:error, :transport_error}
    end
  end

  defp event({:status, ref, status}, {:cont, response}, ref, _limit), do: {:cont, {:cont, %{response | status: status}}}

  defp event({:headers, ref, headers}, {:cont, response}, ref, _limit) do
    headers = response.headers ++ headers

    if Enum.reduce(headers, 0, fn {k, v}, size -> size + byte_size(k) + byte_size(v) end) > @header_limit do
      {:halt, {:error, :response_headers_too_large}}
    else
      {:cont, {:cont, %{response | headers: headers}}}
    end
  end

  defp event({:data, ref, chunk}, {:cont, response}, ref, limit) do
    bytes = response.bytes + byte_size(chunk)

    if bytes > limit do
      {:halt, {:error, :response_too_large}}
    else
      {:cont, {:cont, %{response | bytes: bytes, body: [chunk | response.body]}}}
    end
  end

  defp event({:done, ref}, {:cont, response}, ref, _limit) do
    {:halt,
     {:ok,
      Req.Response.new(
        status: response.status,
        headers: response.headers,
        body: response.body |> Enum.reverse() |> IO.iodata_to_binary()
      )}}
  end

  defp event(_, _, _, _), do: {:halt, {:error, :invalid_response}}
  defp normalize({:ok, %Req.Response{status: status}}) when status in 300..399, do: {:error, :redirect_refused}
  defp normalize({:ok, response}), do: {:ok, response}
  defp normalize({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize(_), do: {:error, :transport_error}
end
