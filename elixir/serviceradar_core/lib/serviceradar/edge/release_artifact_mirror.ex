defmodule ServiceRadar.Edge.ReleaseArtifactMirror do
  @moduledoc """
  Mirrors signed release artifacts into internal datasvc-backed object storage.
  """

  alias ServiceRadar.Edge.ReleaseFetchPolicy
  alias ServiceRadar.Sync.Client, as: SyncClient

  @default_timeout 30_000
  @max_artifact_bytes 256 * 1024 * 1024
  @storage_backend "datasvc_object_store"

  @type prepare_opts :: [
          timeout: non_neg_integer(),
          validate_url: (String.t() -> :ok | {:error, term()}),
          http_get: (String.t(), keyword() -> {:ok, Req.Response.t()} | {:error, term()}),
          upload_object: (Proto.ObjectMetadata.t(), binary(), keyword() ->
                            {:ok, Proto.UploadObjectResponse.t()} | {:error, term()})
        ]

  @spec prepare_publish_attrs(map(), prepare_opts()) :: {:ok, map()} | {:error, term()}
  def prepare_publish_attrs(attrs, opts \\ []) when is_map(attrs) do
    version = map_get_any(attrs, [:version, "version"])
    manifest = normalize_manifest(map_get_any(attrs, [:manifest, "manifest"]) || %{})
    metadata = normalize_metadata(map_get_any(attrs, [:metadata, "metadata"]) || %{})

    with {:ok, version} <- require_present(version, "release version is required"),
         {:ok, artifacts} <- manifest_artifacts(manifest),
         {:ok, mirrored_artifacts} <- mirror_artifacts(version, artifacts, opts) do
      mirrored_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      storage_metadata = %{
        "status" => "mirrored",
        "backend" => @storage_backend,
        "mirrored_at" => mirrored_at,
        "artifact_count" => length(mirrored_artifacts),
        "artifacts" => mirrored_artifacts
      }

      {:ok,
       attrs
       |> put_any([:metadata, "metadata"], Map.put(metadata, "storage", storage_metadata))
       |> put_any([:manifest, "manifest"], manifest)
       |> put_any([:version, "version"], version)}
    end
  end

  @spec mirrored_artifact(map() | struct(), map()) :: {:ok, map()} | {:error, term()}
  def mirrored_artifact(%{metadata: metadata}, artifact)
      when is_map(metadata) and is_map(artifact) do
    mirrored =
      metadata
      |> map_get_any(["storage", :storage], %{})
      |> map_get_any(["artifacts", :artifacts], [])
      |> List.wrap()
      |> Enum.find(&artifact_identity_match?(&1, artifact))

    case mirrored do
      nil -> {:error, :artifact_not_mirrored}
      mirrored -> {:ok, normalize_map(mirrored)}
    end
  end

  def mirrored_artifact(_release, _artifact), do: {:error, :artifact_not_mirrored}

  defp mirror_artifacts(version, artifacts, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    validate_url = Keyword.get(opts, :validate_url, &ReleaseFetchPolicy.validate/1)
    http_get = Keyword.get(opts, :http_get, &default_http_get/2)
    upload_object = Keyword.get(opts, :upload_object, &default_upload_object/3)

    artifacts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {artifact, index}, {:ok, acc} ->
      case mirror_artifact(
             version,
             artifact,
             index,
             timeout,
             validate_url,
             http_get,
             upload_object
           ) do
        {:ok, mirrored} -> {:cont, {:ok, acc ++ [mirrored]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mirror_artifact(version, artifact, index, timeout, validate_url, http_get, upload_object) do
    artifact = normalize_map(artifact)
    source_url = map_get_any(artifact, ["url", :url])
    sha256 = map_get_any(artifact, ["sha256", :sha256])
    os = map_get_any(artifact, ["os", :os])
    arch = map_get_any(artifact, ["arch", :arch])
    format = map_get_any(artifact, ["format", :format])
    entrypoint = map_get_any(artifact, ["entrypoint", :entrypoint])

    with {:ok, source_url} <-
           require_present(source_url, "release artifact #{index + 1} is missing url"),
         {:ok, sha256} <-
           require_present(sha256, "release artifact #{index + 1} is missing sha256"),
         :ok <- validate_url.(source_url),
         {:ok, data} <- download_source_artifact(source_url, timeout, http_get),
         :ok <- verify_sha256(data, sha256),
         {:ok, object_key, file_name} <- object_key(version, artifact),
         metadata =
           build_object_metadata(
             object_key,
             file_name,
             source_url,
             sha256,
             os,
             arch,
             format,
             entrypoint,
             data
           ),
         {:ok, _response} <- upload_object.(metadata, data, timeout: timeout) do
      {:ok,
       compact_map(%{
         "url" => source_url,
         "sha256" => sha256,
         "os" => os,
         "arch" => arch,
         "format" => format,
         "entrypoint" => entrypoint,
         "object_key" => object_key,
         "file_name" => file_name,
         "content_type" => metadata.content_type,
         "size_bytes" => byte_size(data)
       })}
    else
      {:error, reason} ->
        {:error, "failed to mirror release artifact #{index + 1}: #{format_reason(reason)}"}
    end
  end

  defp manifest_artifacts(manifest) when is_map(manifest) do
    artifacts = manifest |> map_get_any(["artifacts", :artifacts], []) |> List.wrap()

    if artifacts == [] do
      {:error, "release manifest must include at least one artifact"}
    else
      {:ok, artifacts}
    end
  end

  defp manifest_artifacts(_manifest), do: {:error, "release manifest must be a map"}

  defp download_source_artifact(source_url, timeout, http_get) do
    case http_get.(source_url, decode_body: false, receive_timeout: timeout) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        data = IO.iodata_to_binary(body)

        cond do
          byte_size(data) == 0 ->
            {:error, "artifact download returned an empty payload"}

          byte_size(data) > @max_artifact_bytes ->
            {:error, "artifact exceeds #{@max_artifact_bytes} byte mirror limit"}

          true ->
            {:ok, data}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "artifact download failed with HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_sha256(data, expected) do
    actual =
      :sha256
      |> :crypto.hash(data)
      |> Base.encode16(case: :lower)

    if String.downcase(to_string(expected)) == actual do
      :ok
    else
      {:error, "artifact sha256 mismatch"}
    end
  end

  defp object_key(version, artifact) do
    basename =
      artifact
      |> map_get_any(["url", :url])
      |> safe_basename()

    sha256 = artifact |> map_get_any(["sha256", :sha256]) |> to_string() |> String.downcase()
    os = artifact |> map_get_any(["os", :os]) |> safe_segment("unknown-os")
    arch = artifact |> map_get_any(["arch", :arch]) |> safe_segment("unknown-arch")
    version_segment = safe_segment(version, "unknown-version")
    file_name = "#{os}-#{arch}-#{basename}"

    {:ok, "agent-releases/#{version_segment}/#{sha256}-#{file_name}", file_name}
  end

  defp build_object_metadata(
         object_key,
         file_name,
         source_url,
         sha256,
         os,
         arch,
         format,
         entrypoint,
         data
       ) do
    %Proto.ObjectMetadata{
      key: object_key,
      content_type: MIME.from_path(file_name || "artifact.bin"),
      sha256: sha256,
      total_size: byte_size(data),
      attributes:
        compact_map(%{
          "source_url" => source_url,
          "file_name" => file_name,
          "os" => os,
          "arch" => arch,
          "format" => format,
          "entrypoint" => entrypoint,
          "release_distribution_backend" => @storage_backend
        })
    }
  end

  defp default_http_get(url, opts) do
    req_opts =
      Keyword.merge(
        [
          url: url,
          headers: [{"user-agent", "serviceradar"}],
          finch: ServiceRadar.Finch,
          max_redirects: 10,
          receive_timeout: @default_timeout
        ],
        opts
      )

    Req.get(req_opts)
  end

  defp default_upload_object(metadata, data, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, channel} <- GenServer.call(ServiceRadar.DataService.Client, :get_channel, timeout) do
      SyncClient.upload_object(channel, metadata, data, timeout: timeout)
    end
  end

  defp normalize_manifest(manifest), do: normalize_map(manifest)
  defp normalize_metadata(metadata), do: normalize_map(metadata)

  defp format_reason(:disallowed_host), do: "artifact URL host is not allowed"
  defp format_reason(:disallowed_scheme), do: "artifact URL must use https"
  defp format_reason(:dns_resolution_failed), do: "artifact URL host could not be resolved"
  defp format_reason(:invalid_url), do: "artifact URL is invalid"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp artifact_identity_match?(stored, artifact) when is_map(stored) and is_map(artifact) do
    stored = normalize_map(stored)
    artifact = normalize_map(artifact)

    Enum.all?(
      ~w(url sha256 os arch format entrypoint),
      &(map_get_any(stored, [&1, String.to_atom(&1)]) ==
          map_get_any(artifact, [&1, String.to_atom(&1)]))
    )
  end

  defp artifact_identity_match?(_, _), do: false

  defp safe_basename(url) do
    url
    |> URI.parse()
    |> Map.get(:path)
    |> Path.basename()
    |> safe_segment("artifact")
  end

  defp safe_segment(value, fallback) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> fallback
      segment -> segment
    end
  end

  defp require_present(value, message) do
    case present_string(value) do
      nil -> {:error, message}
      present -> {:ok, present}
    end
  end

  defp present_string(nil), do: nil

  defp present_string(value) do
    value = value |> to_string() |> String.trim()
    if value == "", do: nil, else: value
  end

  defp put_any(map, [key | _rest], value) when is_map(map) do
    Map.put(map, key, value)
  end

  defp map_get_any(map, keys, default \\ nil)

  defp map_get_any(map, keys, default) when is_map(map) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      normalized_value =
        cond do
          is_map(value) -> normalize_map(value)
          is_list(value) -> Enum.map(value, &normalize_value/1)
          true -> value
        end

      {normalize_key(key), normalized_value}
    end)
  end

  defp normalize_map(_other), do: %{}

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      _ -> false
    end)
    |> Map.new()
  end

end
