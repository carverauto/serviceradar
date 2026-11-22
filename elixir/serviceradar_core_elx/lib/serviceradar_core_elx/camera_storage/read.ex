defmodule ServiceRadarCoreElx.CameraStorage.Read do
  @moduledoc false

  alias ServiceRadar.Camera.ArchiveDestination
  alias ServiceRadar.Camera.ArchiveStorageHTTP, as: HTTP
  alias ServiceRadarCoreElx.CameraStorage.ReadLongshorePool
  alias ServiceRadarObjectStorage.Session, as: ObjectStorageSession

  @fields ~w(schema_version binding_id destination_sha256 descriptor_sha256 manifest_verification_sha256 block_id object_key first last size etag version_id sha256)
  @per_request_fields ~w(schema_version destination credential plan)
  @per_request_plan_fields ~w(storage_id block_key object_key first last size etag version_id sha256)
  @read_buffer_bytes 4_194_304
  @max_longshore_concurrency 4

  def run(config, plan, deadline) do
    with true <- valid?(config, plan),
         remaining when remaining > 0 <- deadline - System.monotonic_time(:millisecond) do
      fetch(config.provider, plan, remaining)
    else
      _ -> {:error, :invalid_archive_range}
    end
  end

  def run_per_request(config, request, deadline) do
    with true <- Map.get(config, :mode) == :per_request,
         {:ok, dest_attrs, destination, credential, plan} <- validate_per_request(request) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining > 0 do
        fetch_per_request(config, dest_attrs, destination, credential, plan, remaining)
      else
        {:error, :archive_read_unavailable}
      end
    else
      _ -> {:error, :invalid_archive_range}
    end
  end

  defp fetch(provider, plan, timeout) do
    case Map.get(provider, :transport, :http) do
      :longshore -> fetch_longshore(provider, plan, timeout)
      :http -> fetch_http(provider, plan, timeout)
    end
  end

  defp fetch_per_request(config, dest_attrs, destination, credential, plan, timeout) do
    case Map.get(config.provider, :transport, :http) do
      :longshore ->
        fetch_per_request_longshore(config, dest_attrs, destination, credential, plan, timeout)

      :http ->
        ephemeral_provider =
          Map.merge(config.provider, %{destination: destination, credential: credential})

        fetch_per_request_http(ephemeral_provider, plan, timeout)
    end
  end

  defp fetch_http(provider, plan, timeout) do
    url =
      provider.destination["endpoint"] <>
        "/" <> provider.destination["bucket"] <> "/" <> plan["object_key"]

    url =
      if plan["version_id"],
        do: url <> "?versionId=" <> URI.encode_www_form(plan["version_id"]),
        else: url

    headers =
      maybe_add_session_token(
        [{"range", "bytes=#{plan["first"]}-#{plan["last"]}"}, {"if-match", plan["etag"]}],
        provider.credential
      )

    signed = HTTP.sign(provider, :get, url, headers, nil)
    size = plan["last"] - plan["first"] + 1
    interval = {plan["first"], plan["last"], plan["size"], plan["etag"], plan["version_id"]}

    with {:ok, %{status: 206, body: bytes}} <-
           HTTP.request(provider, :get, url, signed, nil, timeout, size, interval),
         true <- byte_size(bytes) == size,
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == plan["sha256"] do
      {:ok, bytes}
    else
      _ -> {:error, :archive_read_unavailable}
    end
  end

  defp fetch_per_request_http(provider, plan, timeout) do
    url =
      provider.destination["endpoint"] <>
        "/" <> provider.destination["bucket"] <> "/" <> plan["object_key"]

    url =
      if plan["version_id"],
        do: url <> "?versionId=" <> URI.encode_www_form(plan["version_id"]),
        else: url

    headers =
      maybe_add_session_token(
        [{"range", "bytes=#{plan["first"]}-#{plan["last"]}"}, {"if-match", plan["etag"]}],
        provider.credential
      )

    signed = HTTP.sign(provider, :get, url, headers, nil)
    size = plan["last"] - plan["first"] + 1
    interval = {plan["first"], plan["last"], plan["size"], plan["etag"], plan["version_id"]}

    provider
    |> HTTP.request(:get, url, signed, nil, timeout, size, interval)
    |> handle_per_request_http_response(size, plan["sha256"])
  end

  defp handle_per_request_http_response({:ok, %{status: 206, body: bytes}}, size, expected_sha) do
    if byte_size(bytes) == size and
         Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == expected_sha do
      {:ok, bytes}
    else
      {:error, :integrity_mismatch}
    end
  end

  defp handle_per_request_http_response({:ok, %{status: 404}}, _size, _sha), do: {:error, :not_found}
  defp handle_per_request_http_response({:error, {:http_status, 404}}, _size, _sha), do: {:error, :not_found}

  defp handle_per_request_http_response({:ok, %{status: 412}}, _size, _sha), do: {:error, :integrity_mismatch}

  defp handle_per_request_http_response({:error, {:http_status, 412}}, _size, _sha), do: {:error, :integrity_mismatch}

  defp handle_per_request_http_response(_other, _size, _sha), do: {:error, :archive_read_unavailable}

  defp fetch_longshore(provider, plan, timeout) do
    first = plan["first"]
    last = plan["last"]
    size = last - first + 1
    expect = %{etag: plan["etag"], version: plan["version_id"]}

    with {:ok, %{end: {:answered, %{status: 206, malformed: false} = answer}}, _stats} <-
           ObjectStorageSession.get(
             provider.longshore_session,
             plan["object_key"],
             {first, last},
             expect,
             budget: %{timeout_ms: timeout},
             owner_token: Map.get(provider, :owner_token)
           ),
         true <- answer.etag == plan["etag"],
         true <- normalize_version(answer.version) == {:ok, plan["version_id"]},
         true <- answer.content_range == %{first: first, last: last, size: plan["size"]},
         true <-
           is_binary(answer.body) and byte_size(answer.body) == size and answer.body_len == size,
         true <-
           Base.encode16(:crypto.hash(:sha256, answer.body), case: :lower) == plan["sha256"] do
      {:ok, answer.body}
    else
      _ -> {:error, :archive_read_unavailable}
    end
  end

  defp fetch_per_request_longshore(config, dest_attrs, destination, credential, plan, timeout) do
    pool = Map.get(config.provider, :longshore_pool, ReadLongshorePool)
    key = {dest_attrs.destination_sha256, credential_fingerprint(credential)}

    with {:ok, ls_config} <- build_per_request_longshore_config(config, destination, credential),
         {:ok, session_pid, lease_ref} <- ReadLongshorePool.acquire(pool, key, ls_config) do
      try do
        first = plan["first"]
        last = plan["last"]
        size = last - first + 1
        expect = %{etag: plan["etag"], version: plan["version_id"]}

        case ObjectStorageSession.get(
               session_pid,
               plan["object_key"],
               {first, last},
               expect,
               budget: %{timeout_ms: timeout},
               owner_token: Map.get(config.provider, :owner_token)
             ) do
          {:ok, %{end: {:answered, %{status: 206, malformed: false} = answer}}, _stats} ->
            verify_longshore_answer(answer, plan, first, last, size)

          {:ok, %{end: {:answered, %{status: 404}}}, _stats} ->
            {:error, :not_found}

          {:ok, %{end: {:answered, %{status: 412}}}, _stats} ->
            {:error, :integrity_mismatch}

          _ ->
            {:error, :archive_read_unavailable}
        end
      after
        ReadLongshorePool.release(pool, lease_ref)
      end
    end
  end

  defp verify_longshore_answer(answer, plan, first, last, size) do
    valid? =
      answer.etag == plan["etag"] and
        normalize_version(answer.version) == {:ok, plan["version_id"]} and
        answer.content_range == %{first: first, last: last, size: plan["size"]} and
        is_binary(answer.body) and byte_size(answer.body) == size and answer.body_len == size and
        Base.encode16(:crypto.hash(:sha256, answer.body), case: :lower) == plan["sha256"]

    if valid?, do: {:ok, answer.body}, else: {:error, :integrity_mismatch}
  end

  defp build_per_request_longshore_config(config, destination, credential) do
    with {:ok, host, port, tls} <- longshore_target(config.provider, destination) do
      concurrency = min(Map.get(config, :max_concurrency, 8), @max_longshore_concurrency)

      base = %{
        host: host,
        port: port,
        region: destination["region"],
        bucket: destination["bucket"],
        access_key: credential["access_key_id"],
        secret_key: credential["secret_access_key"],
        session_token: Map.get(credential, "session_token"),
        tls: tls,
        concurrency: max(concurrency, 1),
        buffer_size: @read_buffer_bytes
      }

      ls_config =
        if Map.get(config.provider, :portable, false) do
          Map.put(base, :portable, true)
        else
          base
        end

      {:ok, ls_config}
    end
  end

  defp longshore_target(provider, destination) do
    case Map.fetch(provider, :longshore_loopback_peer) do
      {:ok, {ip, port}} when is_binary(ip) and is_integer(port) and port in 1..65_535 ->
        {:ok, ip, port, false}

      :error ->
        longshore_https_target(destination["endpoint"])

      _ ->
        {:error, :archive_read_unavailable}
    end
  end

  defp longshore_https_target(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host, port: port, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" and is_integer(port) and port in 1..65_535 ->
        {:ok, host, port, true}

      _ ->
        {:error, :archive_read_unavailable}
    end
  end

  defp longshore_https_target(_), do: {:error, :archive_read_unavailable}

  defp credential_fingerprint(credential) do
    :crypto.hash(
      :sha256,
      [
        credential["access_key_id"],
        <<0>>,
        credential["secret_access_key"],
        <<0>>,
        Map.get(credential, "session_token") || ""
      ]
    )
  end

  defp maybe_add_session_token(headers, %{"session_token" => token}) when is_binary(token) and token != "" do
    [{"x-amz-security-token", token} | headers]
  end

  defp maybe_add_session_token(headers, _credential), do: headers

  defp validate_per_request(request) when is_map(request) do
    with true <-
           Enum.sort(Map.keys(request)) == Enum.sort(@per_request_fields) and
             request["schema_version"] === 1,
         {:ok, dest_attrs} <- ArchiveDestination.attributes(request["destination"]),
         {:ok, credential} <- validate_per_request_credential(request["credential"]),
         true <- valid_per_request_plan?(dest_attrs, request["plan"]) do
      {:ok, dest_attrs, request["destination"], credential, request["plan"]}
    else
      _ -> {:error, :invalid_archive_range}
    end
  end

  defp validate_per_request(_), do: {:error, :invalid_archive_range}

  defp validate_per_request_credential(cred) when is_map(cred) do
    keys = Map.keys(cred)
    allowed_only? = keys -- ~w(access_key_id secret_access_key session_token) == []

    with true <-
           allowed_only? and Map.has_key?(cred, "access_key_id") and
             Map.has_key?(cred, "secret_access_key"),
         access_key when is_binary(access_key) <- cred["access_key_id"],
         secret_key when is_binary(secret_key) <- cred["secret_access_key"],
         true <-
           byte_size(access_key) in 1..256 and Regex.match?(~r/\A[!-~]+\z/, access_key),
         true <- secret_string?(secret_key, 1, 512),
         {:ok, session_token} <- validate_session_token(Map.get(cred, "session_token")) do
      {:ok,
       %{
         "access_key_id" => access_key,
         "secret_access_key" => secret_key,
         "session_token" => session_token
       }}
    else
      _ -> {:error, :invalid_archive_range}
    end
  end

  defp validate_per_request_credential(_), do: {:error, :invalid_archive_range}

  defp validate_session_token(nil), do: {:ok, nil}

  defp validate_session_token(token) when is_binary(token) do
    if secret_string?(token, 1, 4096), do: {:ok, token}, else: {:error, :invalid_archive_range}
  end

  defp validate_session_token(_), do: {:error, :invalid_archive_range}

  defp secret_string?(value, min_len, max_len) do
    is_binary(value) and byte_size(value) in min_len..max_len and
      String.valid?(value) and String.trim(value) == value and
      not String.contains?(value, [<<0>>, "\r", "\n"])
  end

  defp valid_per_request_plan?(dest_attrs, plan) when is_map(plan) do
    Enum.sort(Map.keys(plan)) == Enum.sort(@per_request_plan_fields) and
      uuid?(plan["storage_id"]) and
      sha?(plan["block_key"]) and
      per_request_key?(dest_attrs.namespace, plan["storage_id"], plan["block_key"], plan["object_key"]) and
      interval?(plan) and
      etag?(plan["etag"]) and
      version?(plan["version_id"]) and
      sha?(plan["sha256"])
  end

  defp valid_per_request_plan?(_, _), do: false

  defp per_request_key?(namespace, storage_id, block_key, object_key)
       when is_binary(namespace) and is_binary(storage_id) and is_binary(block_key) and is_binary(object_key) do
    prefix = namespace <> "/" <> storage_id <> "/" <> block_key <> "/"
    object_key in [prefix <> "init.mp4", prefix <> "media.m4s"]
  end

  defp per_request_key?(_, _, _, _), do: false

  defp normalize_version(nil), do: {:ok, nil}
  defp normalize_version("null"), do: {:ok, nil}

  defp normalize_version(value) when is_binary(value), do: if(version?(value), do: {:ok, value}, else: :error)

  defp normalize_version(_), do: :error

  defp valid?(config, plan) when is_map(plan) do
    Map.get(config, :mode, :fixed) == :fixed and
      Enum.sort(Map.keys(plan)) == Enum.sort(@fields) and plan["schema_version"] === 1 and
      identity?(config, plan) and key?(plan["object_key"]) and
      interval?(plan) and etag?(plan["etag"]) and version?(plan["version_id"])
  end

  defp valid?(_, _), do: false

  defp identity?(config, plan) do
    plan["binding_id"] == config.binding_id and
      plan["destination_sha256"] == config.destination_sha256 and
      Enum.all?(
        ~w(destination_sha256 descriptor_sha256 manifest_verification_sha256 sha256),
        &sha?(plan[&1])
      ) and
      uuid?(plan["binding_id"]) and uuid?(plan["block_id"])
  end

  defp interval?(%{"first" => first, "last" => last, "size" => size, "object_key" => key}) do
    Enum.all?([first, last, size], &is_integer/1) and first >= 0 and first <= last and
      last < size and size <= 16_777_216 and payload_interval?(key, first, last, size)
  end

  defp payload_interval?(key, first, last, size) do
    if String.ends_with?(key, "/init.mp4") do
      first == 0 and last == size - 1 and size <= 1_048_576
    else
      last - first + 1 <= 4_194_304
    end
  end

  defp key?(value),
    do: is_binary(value) and Regex.match?(~r/\Arecordings\/v1\/[0-9a-f]{64}\/(?:init\.mp4|media\.m4s)\z/, value)

  defp uuid?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp etag?(value),
    do: is_binary(value) and byte_size(value) in 3..256 and Regex.match?(~r/\A"[\x21\x23-\x7e]+"\z/, value)

  defp version?(nil), do: true

  defp version?(value),
    do: is_binary(value) and byte_size(value) in 1..1024 and value != "null" and Regex.match?(~r/\A[\x21-\x7e]+\z/, value)
end
