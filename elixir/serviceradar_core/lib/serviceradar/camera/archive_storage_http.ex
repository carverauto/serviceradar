defmodule ServiceRadar.Camera.ArchiveStorageHTTP do
  @moduledoc """
  One bounded HTTPS exchange for isolated archive storage and its private clients.

  The caller owns authorization, signing and the total operation deadline. This
  transport owns its socket, never retries or follows redirects, and buffers at
  most the caller's response ceiling. Provider verification reads use the shared
  exact-range egress contract.
  """

  alias ServiceRadar.HTTP.EgressClient

  @header_limit 16_384
  @max_presign_expires_seconds 900

  def sign(provider, method, url, headers, body, digest \\ nil) do
    uri = URI.parse(url)
    # Supply transport defaults before hashing; Mint otherwise adds User-Agent after signing.
    headers = [
      {"host", uri.authority},
      {"user-agent", "serviceradar-init-storage/1"},
      {"accept-encoding", "identity"} | headers
    ]

    length =
      case body do
        {:file, _, size} -> size
        bytes when is_binary(bytes) -> byte_size(bytes)
        nil -> nil
      end

    headers =
      if length, do: [{"content-length", Integer.to_string(length)} | headers], else: headers

    Req.Utils.aws_sigv4_headers(
      access_key_id: provider.credential["access_key_id"],
      secret_access_key: provider.credential["secret_access_key"],
      region: provider.destination["region"],
      service: "s3",
      datetime: DateTime.utc_now(),
      method: method,
      url: url,
      headers: headers,
      body: "",
      body_digest: digest || :sha256 |> :crypto.hash(body || "") |> Base.encode16(case: :lower)
    )
  end

  @doc """
  Signs a short-lived AWS SigV4 query-string pre-signed `GET` URL (`UNSIGNED-PAYLOAD`,
  `X-Amz-SignedHeaders=host`) for a single S3-compatible archive object.

  Signing only the `host` header allows bounded `Range` and `If-Match` headers on the
  resulting `GET` across AWS S3, MinIO, RustFS, Ceph RGW, Cloudflare R2, and Backblaze B2
  while the object store enforces single-object `GET`-only access, optional `versionId`,
  and `X-Amz-Expires` (`1..900` seconds).
  """
  @spec presign_get_url(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def presign_get_url(provider, key, opts \\ [])

  def presign_get_url(provider, key, opts)
      when is_map(provider) and is_binary(key) and is_list(opts) do
    credential = fetch_field(provider, :credential)
    destination = fetch_field(provider, :destination)
    expires = Keyword.get(opts, :expires, 300)
    datetime = Keyword.get(opts, :datetime, DateTime.utc_now())
    version_id = Keyword.get(opts, :version_id)

    with {:ok, access_key_id} <- require_non_empty_string(fetch_field(credential, :access_key_id)),
         {:ok, secret_access_key} <-
           require_non_empty_string(fetch_field(credential, :secret_access_key)),
         {:ok, region} <- require_non_empty_string(fetch_field(destination, :region)),
         {:ok, bucket} <- require_clean_bucket(fetch_field(destination, :bucket)),
         {:ok, object_uri} <-
           build_presign_object_uri(fetch_field(destination, :endpoint), bucket, key),
         :ok <- validate_presign_expires(expires),
         %DateTime{} <- datetime do
      session_token = normalize_optional_string(fetch_field(credential, :session_token))
      clean_version_id = normalize_optional_version_id(version_id)

      query =
        []
        |> maybe_append_query("X-Amz-Security-Token", session_token)
        |> maybe_append_query("versionId", clean_version_id)

      presigned_uri =
        Req.Utils.aws_sigv4_url(
          access_key_id: access_key_id,
          secret_access_key: secret_access_key,
          region: region,
          service: "s3",
          datetime: datetime,
          method: :get,
          url: object_uri,
          expires: expires,
          headers: [],
          query: query
        )

      {:ok, URI.to_string(presigned_uri)}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_presign_parameters}
    end
  end

  def presign_get_url(_, _, _), do: {:error, :invalid_presign_parameters}

  defp build_presign_object_uri(endpoint, bucket, key) when is_binary(endpoint) do
    uri = endpoint |> String.trim() |> URI.parse()

    key_segments =
      key
      |> String.trim_leading("/")
      |> String.split("/", trim: true)

    cond do
      uri.scheme not in ["https", "http"] ->
        {:error, :invalid_archive_endpoint}

      not is_binary(uri.host) or uri.host == "" or not is_nil(uri.userinfo) ->
        {:error, :invalid_archive_endpoint}

      uri.query not in [nil, ""] or not is_nil(uri.fragment) ->
        {:error, :invalid_archive_endpoint}

      key_segments == [] or "." in key_segments or ".." in key_segments ->
        {:error, :invalid_archive_object_key}

      true ->
        base_segments = String.split(uri.path || "", "/", trim: true)

        encoded_path =
          "/" <>
            Enum.map_join(base_segments ++ [bucket | key_segments], "/", fn segment ->
              URI.encode(segment, &URI.char_unreserved?/1)
            end)

        {:ok, %{uri | path: encoded_path, query: nil, fragment: nil}}
    end
  end

  defp build_presign_object_uri(_, _, _), do: {:error, :invalid_archive_endpoint}

  defp validate_presign_expires(expires)
       when is_integer(expires) and expires in 1..@max_presign_expires_seconds, do: :ok

  defp validate_presign_expires(_), do: {:error, :invalid_presign_expires}

  defp require_non_empty_string(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: {:error, :invalid_presign_parameters}, else: {:ok, trimmed}
  end

  defp require_non_empty_string(_), do: {:error, :invalid_presign_parameters}

  defp require_clean_bucket(val) when is_binary(val) do
    trimmed = val |> String.trim() |> String.trim("/")

    if trimmed == "" or String.contains?(trimmed, "/") do
      {:error, :invalid_archive_bucket}
    else
      {:ok, trimmed}
    end
  end

  defp require_clean_bucket(_), do: {:error, :invalid_archive_bucket}

  defp normalize_optional_string(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_optional_version_id(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "" or trimmed == "null", do: nil, else: trimmed
  end

  defp normalize_optional_version_id(_), do: nil

  defp maybe_append_query(acc, _key, nil), do: acc
  defp maybe_append_query(acc, key, val), do: acc ++ [{key, val}]

  defp fetch_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_field(_, _), do: nil

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
          {:ok, pid} =
            Task.Supervisor.start_child(Map.fetch!(config, :task_supervisor), operation)

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

  defp execute(
         config,
         :get,
         url,
         headers,
         _body,
         timeout,
         max_bytes,
         {first, last, size, etag, version}
       ) do
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
      transport_opts:
        [cacerts: config.cacerts, timeout: timeout] ++ Map.get(config, :client_tls, [])
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
            receive_response(
              conn,
              ref,
              %{status: nil, headers: [], body: [], bytes: 0},
              max_bytes,
              timeout
            )
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
        with {:ok, conn, ref} <-
               Mint.HTTP.request(conn, String.upcase(to_string(method)), path, headers, :stream),
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

  defp event({:status, ref, status}, {:cont, response}, ref, _limit),
    do: {:cont, {:cont, %{response | status: status}}}

  defp event({:headers, ref, headers}, {:cont, response}, ref, _limit) do
    headers = response.headers ++ headers

    if Enum.reduce(headers, 0, fn {k, v}, size -> size + byte_size(k) + byte_size(v) end) >
         @header_limit do
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

  defp normalize({:ok, %Req.Response{status: status}}) when status in 300..399,
    do: {:error, :redirect_refused}

  defp normalize({:ok, response}), do: {:ok, response}
  defp normalize({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize(_), do: {:error, :transport_error}
end
