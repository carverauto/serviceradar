defmodule ServiceRadarCoreElx.CameraStorage.Upload do
  @moduledoc """
  One granted operation-specific PUT followed by exact identity-bound verification.

  The sole send permission is the fresh grant response. No retained marker,
  timeout, conflicting object or replacement lease can rearm this operation.
  Provider credentials never leave this isolated workload.
  """
  alias ServiceRadarCoreElx.CameraStorage.CoreClient
  alias ServiceRadarCoreElx.CameraStorage.HTTP

  def run(config, boot, installation_deadline, lease, bytes, ingress_deadline) do
    started = now()
    limit = config.desired.limits["max_operation_ms"]
    deadline = Enum.min([installation_deadline, ingress_deadline, started + limit])
    envelope = %{"schema_version" => 1, "lease" => lease}

    with true <- is_binary(bytes) and byte_size(bytes) in 1..config.desired.limits["max_init_bytes"],
         object_sha = sha256(bytes),
         {:ok, %{"schema_version" => 1, "dispatch_id" => dispatch_id} = prepared} when map_size(prepared) == 2 <-
           CoreClient.request(config.runtime, :prepare, envelope, remaining(deadline)),
         true <- uuid?(dispatch_id) do
      request =
        Map.merge(envelope, %{
          "dispatch_id" => dispatch_id,
          "storage_boot_id" => boot,
          "desired_sha256" => config.desired.desired_sha256,
          "nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        })

      grant_started = now()

      with {:ok, grant} <- CoreClient.request(config.runtime, :grant, request, remaining(deadline)),
           :ok <- grant(:init, grant, config.desired, request, byte_size(bytes), object_sha),
           deadline = min(deadline, grant_started + grant["remaining_ms"]),
           true <- remaining(deadline) > 0 do
        execute(:init, config, request, grant, bytes, object_sha, deadline)
      else
        _ -> {:error, :storage_grant_refused}
      end
    else
      _ -> {:error, :storage_preparation_refused}
    end
  end

  def run_media(config, boot, lease, prepared, path, deadline) do
    request = %{
      "schema_version" => 1,
      "lease" => lease,
      "dispatch_id" => prepared["dispatch_id"],
      "storage_boot_id" => boot,
      "desired_sha256" => config.desired.desired_sha256,
      "nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    }

    started = now()

    with {:ok, grant} <- CoreClient.request(config.runtime, :grant, request, remaining(deadline)),
         :ok <- grant(:media, grant, config.desired, request, prepared["byte_length"], prepared["object_sha256"]),
         deadline = min(deadline, started + grant["remaining_ms"]),
         true <- remaining(deadline) > 0 do
      execute(:media, config, request, grant, {:file, path, prepared["byte_length"]}, prepared["object_sha256"], deadline)
    else
      _ -> {:error, :storage_grant_refused}
    end
  end

  defp grant(kind, grant, desired, request, byte_length, object_sha) do
    expected =
      request
      |> Map.take(~w(schema_version dispatch_id storage_boot_id desired_sha256 nonce))
      |> Map.merge(%{
        "status" => "granted",
        "binding_id" => desired.binding_id,
        "revision" => Integer.to_string(desired.revision),
        "local_storage_id" => desired.local_storage_id,
        "descriptor_sha256" => request["lease"]["descriptor_sha256"],
        "byte_length" => byte_length,
        "object_sha256" => object_sha
      })

    valid =
      Map.drop(grant, ~w(remaining_ms request_sha256 object_key)) === expected and
        is_integer(grant["remaining_ms"]) and grant["remaining_ms"] in 1..desired.limits["max_operation_ms"] and
        sha?(grant["request_sha256"]) and is_binary(grant["object_key"]) and
        object_key?(kind, grant["object_key"])

    if valid, do: :ok, else: {:error, :invalid_storage_grant}
  end

  defp execute(kind, config, request, grant, bytes, object_sha, deadline) do
    provider = config.provider
    destination = provider.destination
    url = destination["endpoint"] <> "/" <> destination["bucket"] <> "/" <> grant["object_key"]

    headers = [
      {"if-none-match", "*"},
      {"x-amz-server-side-encryption", "AES256"},
      {"x-amz-checksum-sha256", object_sha |> Base.decode16!(case: :lower) |> Base.encode64()}
    ]

    signed = sign(provider, :put, url, headers, bytes, object_sha)
    pairs = signed |> Enum.sort() |> Enum.map(fn {key, value} -> [key, value] end)
    wire_sha = sha256(Jason.encode!(["#{kind}-put-wire-v1", "PUT", url, pairs, object_sha]))

    case provider_request(provider, :put, url, signed, bytes, deadline, 16_384) do
      {:ok, response} ->
        verified = verified_object(provider, url, response, grant, wire_sha, deadline)
        observe(config, request, response)
        record(kind, config, request, verified)

      {:error, _} ->
        CoreClient.request(config.runtime, :observe, observation(request, "unknown"), 1_000)
        failure(kind, :unknown)
    end
  end

  defp verified_object(provider, url, %{status: 200} = response, grant, wire_sha, deadline) do
    with {:ok, identity} <- identity(response),
         {:ok, verification} <- verify(provider, url, identity, grant, wire_sha, deadline) do
      verification
    else
      _ -> nil
    end
  end

  defp verified_object(_provider, _url, _response, _grant, _wire_sha, _deadline), do: nil

  defp record(kind, _config, _request, nil), do: failure(kind, :verification)

  defp record(kind, config, request, verification) do
    with {:ok, receipt} <-
           CoreClient.request(config.runtime, :verify, Map.put(request, "verification", verification), 1_000),
         true <-
           receipt === %{"schema_version" => 1, "status" => "recorded", "dispatch_id" => request["dispatch_id"]} do
      {:ok,
       %{
         "schema_version" => 1,
         "status" => "#{kind}_verified",
         "dispatch_id" => request["dispatch_id"],
         "recording_readiness" => "unavailable",
         "archive_readiness" => "unavailable"
       }}
    else
      _ -> failure(kind, :verification)
    end
  end

  defp verify(provider, url, identity, grant, wire_sha, deadline) do
    url = version_url(url, identity.version)
    headers = [{"if-match", identity.etag}]

    with {:ok, %{status: 200} = head} <-
           provider_request(provider, :head, url, sign(provider, :head, url, headers, nil), nil, deadline, 0),
         {:ok, ^identity} <- identity(head),
         true <- header(head, "content-length") == Integer.to_string(grant["byte_length"]),
         "AES256" <- header(head, "x-amz-server-side-encryption"),
         {:ok, sha} <- readback(provider, url, identity, grant["byte_length"], 0, :crypto.hash_init(:sha256), deadline),
         true <- sha == grant["object_sha256"] and remaining(deadline) > 0 do
      {:ok,
       %{
         "schema_version" => 1,
         "put_request_sha256" => wire_sha,
         "etag" => identity.etag,
         "version_id" => identity.version,
         "byte_length" => grant["byte_length"],
         "object_sha256" => grant["object_sha256"],
         "encryption" => "AES256"
       }}
    else
      _ -> {:error, :init_object_not_verified}
    end
  end

  defp readback(_provider, _url, _identity, size, size, hash, _deadline),
    do: {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}

  defp readback(provider, url, identity, size, first, hash, deadline) do
    last = min(size - 1, first + 4_194_304 - 1)
    headers = [{"range", "bytes=#{first}-#{last}"}, {"if-match", identity.etag}]
    signed = sign(provider, :get, url, headers, nil)
    range = {first, last, size, identity.etag, identity.version}

    with {:ok, response} <- provider_request(provider, :get, url, signed, nil, deadline, last - first + 1, range),
         true <- byte_size(response.body) == last - first + 1 do
      readback(provider, url, identity, size, last + 1, :crypto.hash_update(hash, response.body), deadline)
    else
      _ -> {:error, :object_range_not_verified}
    end
  end

  defp provider_request(provider, method, url, headers, body, deadline, limit, range \\ nil) do
    case remaining(deadline) do
      remaining when remaining > 0 -> HTTP.request(provider, method, url, headers, body, remaining, limit, range)
      _ -> {:error, :storage_deadline_expired}
    end
  end

  defp sign(provider, method, url, headers, body, digest \\ nil) do
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

    headers = if length, do: [{"content-length", Integer.to_string(length)} | headers], else: headers

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
      body_digest: digest || sha256(body || "")
    )
  end

  defp object_key?(:init, key), do: Regex.match?(~r/\Arecordings\/v1\/[0-9a-f]{64}\/init\.mp4\z/, key)
  defp object_key?(:media, key), do: Regex.match?(~r/\Arecordings\/v1\/[0-9a-f]{64}\/media\.m4s\z/, key)
  defp failure(:init, :unknown), do: {:error, :init_upload_unknown}
  defp failure(:media, :unknown), do: {:error, :media_upload_unknown}
  defp failure(:init, :verification), do: {:error, :init_verification_unavailable}
  defp failure(:media, :verification), do: {:error, :media_verification_unavailable}

  defp identity(response) do
    etag = header(response, "etag")
    versions = Req.Response.get_header(response, "x-amz-version-id")

    with true <- is_binary(etag) and byte_size(etag) in 3..256,
         true <- Regex.match?(~r/\A"[\x21\x23-\x7e]+"\z/, etag),
         {:ok, version} <- version(versions) do
      {:ok, %{etag: etag, version: version}}
    else
      _ -> {:error, :invalid_object_identity}
    end
  end

  defp version([]), do: {:ok, nil}
  defp version(["null"]), do: {:ok, nil}

  defp version([value]) when is_binary(value) and byte_size(value) in 1..1024 do
    if Regex.match?(~r/\A[\x21-\x7e]+\z/, value), do: {:ok, value}, else: {:error, :invalid_version}
  end

  defp version(_), do: {:error, :invalid_version}
  defp version_url(url, nil), do: url
  defp version_url(url, version), do: url <> "?versionId=" <> URI.encode_www_form(version)

  defp observe(config, request, response) do
    metadata =
      Enum.reduce(
        [{"etag", "etag", 256}, {"version_id", "x-amz-version-id", 1024}, {"request_id", "x-amz-request-id", 256}],
        %{"status" => response.status},
        fn {key, name, limit}, metadata ->
          case header(response, name) do
            value when is_binary(value) and byte_size(value) in 1..limit//1 -> Map.put(metadata, key, value)
            _ -> metadata
          end
        end
      )

    document = request |> observation("response") |> Map.put("response", metadata)
    CoreClient.request(config.runtime, :observe, document, 1_000)
  end

  defp observation(request, outcome),
    do: request |> Map.take(~w(schema_version lease dispatch_id)) |> Map.put("outcome", outcome)

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value] -> value
      _ -> nil
    end
  end

  defp uuid?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp sha?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  defp remaining(deadline), do: max(0, deadline - now())
  defp now, do: System.monotonic_time(:millisecond)
end
