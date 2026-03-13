defmodule ServiceRadarWebNG.Plugins.Storage do
  @moduledoc """
  Storage backend for plugin package blobs.

  Currently supports filesystem storage with signed upload/download URLs.
  """

  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNGWeb.Endpoint

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_base_path "/var/lib/serviceradar/plugin-packages"
  @default_upload_ttl_seconds 900
  @default_download_ttl_seconds 900
  @default_max_upload_bytes 52_428_800

  @spec backend() :: :filesystem | :jetstream
  def backend do
    case Keyword.get(config(), :backend, :filesystem) do
      :jetstream -> :jetstream
      "jetstream" -> :jetstream
      :filesystem -> :filesystem
      "filesystem" -> :filesystem
      _ -> :filesystem
    end
  end

  @spec base_path() :: String.t()
  def base_path do
    config()
    |> Keyword.get(:base_path, @default_base_path)
  end

  @spec max_upload_bytes() :: pos_integer()
  def max_upload_bytes do
    config()
    |> Keyword.get(:max_upload_bytes, @default_max_upload_bytes)
  end

  @spec upload_ttl_seconds() :: pos_integer()
  def upload_ttl_seconds do
    config()
    |> Keyword.get(:upload_ttl_seconds, @default_upload_ttl_seconds)
  end

  @spec download_ttl_seconds() :: pos_integer()
  def download_ttl_seconds do
    config()
    |> Keyword.get(:download_ttl_seconds, @default_download_ttl_seconds)
  end

  @spec object_key_for(PluginPackage.t()) :: String.t()
  def object_key_for(%PluginPackage{} = package) do
    plugin_id = sanitize_segment(package.plugin_id || "unknown")
    version = sanitize_segment(package.version || "unknown")
    "plugins/#{plugin_id}/#{version}/#{package.id}.wasm"
  end

  @spec sign_token(atom(), String.t(), String.t(), pos_integer()) :: {String.t(), DateTime.t()}
  def sign_token(action, package_id, object_key, ttl_seconds) do
    expires_at = DateTime.add(DateTime.utc_now(), ttl_seconds, :second)

    payload = %{
      "id" => package_id,
      "key" => object_key,
      "exp" => DateTime.to_unix(expires_at),
      "act" => Atom.to_string(action)
    }

    payload_json = Jason.encode!(payload)
    signature = sign(payload_json)

    token =
      Base.url_encode64(payload_json, padding: false) <>
        "." <>
        Base.url_encode64(signature, padding: false)

    {token, expires_at}
  end

  @spec verify_token(atom(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify_token(expected_action, token) when is_binary(token) do
    with [payload_b64, sig_b64] <- String.split(token, ".", parts: 2),
         {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
         {:ok, payload} <- Jason.decode(payload_json),
         {:ok, signature} <- Base.url_decode64(sig_b64, padding: false),
         true <- secure_compare(signature, sign(payload_json)),
         %{"id" => id, "key" => key, "exp" => exp, "act" => action} <- payload,
         true <- action == Atom.to_string(expected_action),
         true <- exp > DateTime.to_unix(DateTime.utc_now()) do
      {:ok, %{id: id, key: key}}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify_token(_action, _token), do: {:error, :invalid_token}

  @spec upload_url(String.t(), String.t()) :: String.t()
  def upload_url(package_id, token) do
    Endpoint.url() <> "/api/plugin-packages/#{package_id}/blob?token=#{token}"
  end

  @spec download_url(String.t(), String.t()) :: String.t()
  def download_url(package_id, token) do
    Endpoint.url() <> "/api/plugin-packages/#{package_id}/blob?token=#{token}"
  end

  @spec put_blob(String.t(), binary()) :: :ok | {:error, term()}
  def put_blob(object_key, payload) when is_binary(payload) do
    case backend() do
      :filesystem -> put_blob_filesystem(object_key, payload)
      :jetstream -> put_blob_jetstream(object_key, payload)
    end
  end

  @spec fetch_blob(String.t()) ::
          {:ok, {:file, String.t()} | {:binary, binary()}} | {:error, term()}
  def fetch_blob(object_key) do
    case backend() do
      :filesystem -> fetch_blob_filesystem(object_key)
      :jetstream -> fetch_blob_jetstream(object_key)
    end
  end

  @spec delete_blob(String.t()) :: :ok | {:error, term()}
  def delete_blob(object_key) do
    case backend() do
      :filesystem -> delete_blob_filesystem(object_key)
      :jetstream -> delete_blob_jetstream(object_key)
    end
  end

  @spec blob_path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def blob_path(object_key) do
    case backend() do
      :filesystem -> safe_path(object_key)
      :jetstream -> {:error, :unsupported_backend}
    end
  end

  @spec blob_exists?(String.t()) :: boolean()
  def blob_exists?(object_key) do
    case backend() do
      :filesystem -> blob_exists_filesystem(object_key)
      :jetstream -> blob_exists_jetstream(object_key)
    end
  end

  @spec sha256(binary()) :: String.t()
  def sha256(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end

  defp config do
    Application.get_env(:serviceradar_web_ng, :plugin_storage, [])
  end

  defp bucket_name do
    config()
    |> Keyword.get(:jetstream_bucket, "serviceradar_plugins")
  end

  defp bucket_opts do
    ttl_seconds = Keyword.get(config(), :jetstream_ttl_seconds, 0)
    ttl_ns = if ttl_seconds > 0, do: ttl_seconds * 1_000_000_000, else: 0

    [
      description: Keyword.get(config(), :jetstream_description),
      max_bucket_size: Keyword.get(config(), :jetstream_max_bucket_size),
      max_chunk_size: Keyword.get(config(), :jetstream_max_chunk_size),
      replicas: Keyword.get(config(), :jetstream_replicas, 1),
      storage: Keyword.get(config(), :jetstream_storage, :file),
      ttl: ttl_ns
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp signing_secret do
    config()
    |> Keyword.get(:signing_secret) ||
      Application.fetch_env!(:serviceradar_web_ng, Endpoint)
      |> Keyword.fetch!(:secret_key_base)
  end

  defp sign(payload_json) do
    :crypto.mac(:hmac, :sha256, signing_secret(), payload_json)
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp secure_compare(_, _), do: false

  defp safe_path(object_key) when is_binary(object_key) do
    base = Path.expand(base_path())
    path = Path.expand(Path.join(base, object_key))
    base_prefix = base <> "/"

    if path == base or String.starts_with?(path, base_prefix) do
      {:ok, path}
    else
      {:error, :invalid_path}
    end
  end

  defp safe_path(_), do: {:error, :invalid_path}

  defp sanitize_segment(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
    |> String.slice(0, 120)
  end

  defp sanitize_segment(_), do: "unknown"

  @sobelow_skip ["Traversal.FileModule"]
  defp put_blob_filesystem(object_key, payload) do
    case safe_path(object_key) do
      {:ok, path} ->
        case File.mkdir_p(Path.dirname(path)) do
          :ok -> File.write(path, payload)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp delete_blob_filesystem(object_key) do
    case safe_path(object_key) do
      {:ok, path} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp fetch_blob_filesystem(object_key) do
    with {:ok, path} <- safe_path(object_key) do
      if File.exists?(path) do
        {:ok, {:file, path}}
      else
        {:error, :not_found}
      end
    end
  end

  defp put_blob_jetstream(object_key, payload) do
    with_jetstream(fn conn ->
      with {:ok, _} <- ensure_bucket(conn),
           {:ok, io} <- StringIO.open(payload),
           {:ok, _meta} <- Jetstream.API.Object.put(conn, bucket_name(), object_key, io) do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp fetch_blob_jetstream(object_key) do
    with_jetstream(fn conn ->
      with {:ok, _} <- ensure_bucket(conn),
           {:ok, io} <- StringIO.open(""),
           :ok <-
             Jetstream.API.Object.get(conn, bucket_name(), object_key, fn chunk ->
               IO.binwrite(io, chunk)
             end) do
        {_input, output} = StringIO.contents(io)
        {:ok, {:binary, output}}
      else
        {:error, %{"code" => 404}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp delete_blob_jetstream(object_key) do
    with_jetstream(fn conn ->
      Jetstream.API.Object.delete(conn, bucket_name(), object_key)
    end)
    |> case do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, %{"code" => 404}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp blob_exists_filesystem(object_key) do
    case safe_path(object_key) do
      {:ok, path} -> File.exists?(path)
      {:error, _} -> false
    end
  end

  defp blob_exists_jetstream(object_key) do
    with_jetstream(fn conn ->
      Jetstream.API.Object.info(conn, bucket_name(), object_key)
    end)
    |> case do
      {:ok, _meta} -> true
      {:error, %{"code" => 404}} -> false
      {:error, _} -> false
    end
  end

  defp with_jetstream(fun) when is_function(fun, 1) do
    case ServiceRadar.NATS.Connection.get() do
      {:ok, conn} -> fun.(conn)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_bucket(conn) do
    stream_name = "OBJ_#{bucket_name()}"

    case Jetstream.API.Stream.info(conn, stream_name) do
      {:ok, _} ->
        {:ok, :exists}

      {:error, %{"code" => 404}} ->
        Jetstream.API.Object.create_bucket(conn, bucket_name(), bucket_opts())

      {:error, reason} ->
        {:error, reason}
    end
  end
end
