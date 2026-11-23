defmodule ServiceRadar.Jobs.SettingsBackup.S3Uploader do
  @moduledoc """
  Uploads deterministic settings backup snapshots to an S3-compatible object store
  (such as Linode Object Storage) using AWS SigV4 HTTPS PUT over `EgressProxy`.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveStorageHTTP
  alias ServiceRadar.HTTP.EgressProxy
  alias ServiceRadar.Jobs.SettingsBackupDestination

  @default_timeout_ms 30_000
  @max_response_bytes 65_536

  @type upload_result :: %{
          object_key: String.t(),
          latest_key: String.t(),
          etag: String.t() | nil,
          sha256: String.t()
        }

  @spec upload(map() | struct(), binary(), keyword()) :: {:ok, upload_result()} | {:error, term()}
  def upload(destination, json_bytes, opts \\ []) when is_binary(json_bytes) do
    with {:ok, access_key_id, secret_access_key} <- resolve_credentials(destination, opts),
         {:ok, sha256, sha256_prefix} <- resolve_digest(json_bytes, opts) do
      exported_at = Keyword.get(opts, :exported_at) || DateTime.utc_now()
      now = Keyword.get(opts, :now) || DateTime.utc_now()
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

      versioned_key = versioned_object_key(destination.prefix, exported_at, sha256_prefix)
      latest_key = latest_object_key(destination.prefix)
      config = build_http_config(opts)

      creds = %{
        access_key_id: access_key_id,
        secret_access_key: secret_access_key,
        region: destination.region
      }

      with {:ok, versioned_etag} <-
             put_object(
               destination,
               creds,
               versioned_key,
               json_bytes,
               sha256,
               now,
               config,
               timeout_ms
             ),
           {:ok, _latest_etag} <-
             put_object(
               destination,
               creds,
               latest_key,
               json_bytes,
               sha256,
               now,
               config,
               timeout_ms
             ) do
        {:ok,
         %{
           object_key: versioned_key,
           latest_key: latest_key,
           etag: versioned_etag,
           sha256: sha256
         }}
      end
    end
  end

  @spec versioned_object_key(String.t() | nil, DateTime.t(), String.t()) :: String.t()
  def versioned_object_key(prefix, %DateTime{} = exported_at, sha256_prefix) do
    timestamp = Calendar.strftime(DateTime.shift_zone!(exported_at, "Etc/UTC"), "%Y%m%dT%H%M%SZ")
    join_prefix(prefix, "settings-export/#{timestamp}-#{sha256_prefix}.json")
  end

  @spec latest_object_key(String.t() | nil) :: String.t()
  def latest_object_key(prefix) do
    join_prefix(prefix, "settings-export/latest.json")
  end

  defp join_prefix(prefix, suffix) do
    normalized =
      prefix
      |> to_string()
      |> String.trim()
      |> String.trim("/")

    if normalized == "", do: suffix, else: normalized <> "/" <> suffix
  end

  defp put_object(destination, creds, object_key, body, sha256, now, config, timeout_ms) do
    endpoint = String.trim_trailing(destination.endpoint, "/")
    bucket = destination.bucket |> String.trim() |> String.trim("/")
    base_uri = URI.parse(endpoint)
    base_segments = String.split(base_uri.path || "", "/", trim: true)
    key_segments = object_key |> String.trim_leading("/") |> String.split("/", trim: true)

    encoded_path =
      "/" <>
        Enum.map_join(base_segments ++ [bucket | key_segments], "/", fn segment ->
          URI.encode(segment, &URI.char_unreserved?/1)
        end)

    uri = %{base_uri | path: encoded_path, query: nil, fragment: nil}
    url = URI.to_string(uri)

    headers = [
      {"host", uri.authority},
      {"user-agent", "serviceradar-settings-backup/1"},
      {"accept-encoding", "identity"},
      {"content-type", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))}
    ]

    signed_headers =
      Req.Utils.aws_sigv4_headers(
        access_key_id: creds.access_key_id,
        secret_access_key: creds.secret_access_key,
        region: creds.region,
        service: "s3",
        datetime: now,
        method: :put,
        url: url,
        headers: headers,
        body: body,
        body_digest: sha256
      )

    case ArchiveStorageHTTP.request(
           config,
           :put,
           url,
           signed_headers,
           body,
           timeout_ms,
           @max_response_bytes
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        etag = response |> Req.Response.get_header("etag") |> List.first()
        {:ok, etag}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_credentials(%SettingsBackupDestination{} = dest, opts) do
    loaded =
      if is_binary(dest.access_key_id) and is_binary(dest.secret_access_key) do
        dest
      else
        actor = Keyword.get(opts, :actor) || SystemActor.system(:settings_backup)
        Ash.load!(dest, [:access_key_id, :secret_access_key], actor: actor)
      end

    extract_credentials(loaded)
  rescue
    _ -> {:error, :missing_credentials}
  end

  defp resolve_credentials(dest, _opts) when is_map(dest) do
    extract_credentials(dest)
  end

  defp extract_credentials(dest) do
    access_key_id = Map.get(dest, :access_key_id) || Map.get(dest, "access_key_id")
    secret_access_key = Map.get(dest, :secret_access_key) || Map.get(dest, "secret_access_key")

    if is_binary(access_key_id) and access_key_id != "" and
         is_binary(secret_access_key) and secret_access_key != "" do
      {:ok, access_key_id, secret_access_key}
    else
      {:error, :missing_credentials}
    end
  end

  defp resolve_digest(json_bytes, opts) do
    sha256 =
      Keyword.get_lazy(opts, :sha256, fn ->
        :sha256 |> :crypto.hash(json_bytes) |> Base.encode16(case: :lower)
      end)

    sha256_prefix = Keyword.get(opts, :sha256_prefix) || binary_part(sha256, 0, 12)
    {:ok, sha256, sha256_prefix}
  end

  defp build_http_config(opts) do
    env_opts = Application.get_env(:serviceradar_core, :settings_backup_http_opts, [])
    merged = Keyword.merge(env_opts, opts)

    proxy =
      case Keyword.fetch(merged, :proxy) do
        {:ok, val} -> val
        :error -> EgressProxy.from_env() || Application.get_env(:serviceradar_core, :egress_proxy)
      end

    cacerts = Keyword.get_lazy(merged, :cacerts, &default_cacerts/0)

    %{
      proxy: proxy,
      cacerts: cacerts
    }
  end

  defp default_cacerts do
    case castore_cacerts() do
      [_ | _] = certs -> certs
      _ -> :public_key.cacerts_get()
    end
  end

  defp castore_cacerts do
    if Code.ensure_loaded?(CAStore) and function_exported?(CAStore, :file_path, 0) do
      CAStore.file_path()
      |> File.read!()
      |> :public_key.pem_decode()
      |> Enum.flat_map(fn
        {:Certificate, der, :not_encrypted} -> [der]
        _ -> []
      end)
    else
      []
    end
  rescue
    _ -> []
  end
end
