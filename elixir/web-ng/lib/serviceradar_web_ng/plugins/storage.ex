defmodule ServiceRadarWebNG.Plugins.Storage do
  @moduledoc """
  Storage backend for plugin package blobs.

  Currently supports filesystem storage with signed upload/download tokens.
  """

  alias Jetstream.API.Object
  alias Jetstream.API.Stream
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadarWebNG.Web.EndpointConfig

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_base_path "/var/lib/serviceradar/plugin-packages/data"
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
    Keyword.get(config(), :base_path, @default_base_path)
  end

  @spec max_upload_bytes() :: pos_integer()
  def max_upload_bytes do
    Keyword.get(config(), :max_upload_bytes, @default_max_upload_bytes)
  end

  @spec upload_ttl_seconds() :: pos_integer()
  def upload_ttl_seconds do
    Keyword.get(config(), :upload_ttl_seconds, @default_upload_ttl_seconds)
  end

  @spec download_ttl_seconds() :: pos_integer()
  def download_ttl_seconds do
    Keyword.get(config(), :download_ttl_seconds, @default_download_ttl_seconds)
  end

  @spec object_key_for(PluginPackage.t()) :: String.t()
  def object_key_for(%PluginPackage{} = package) do
    plugin_id = sanitize_segment(package.plugin_id || "unknown")
    version = sanitize_segment(package.version || "unknown")
    "plugins/#{plugin_id}/#{version}/#{package.id}.wasm"
  end

  @spec object_key_for(DashboardPackage.t()) :: String.t()
  def object_key_for(%DashboardPackage{} = package) do
    dashboard_id = sanitize_segment(package.dashboard_id || "unknown")
    version = sanitize_segment(package.version || "unknown")
    extension =
      package
      |> dashboard_renderer_artifact()
      |> Path.extname()
      |> case do
        "" -> ".wasm"
        ext -> ext
      end

    "dashboards/#{dashboard_id}/#{version}/#{package.id}#{extension}"
  end

  defp dashboard_renderer_artifact(%DashboardPackage{renderer: %{"artifact" => artifact}})
       when is_binary(artifact),
       do: artifact

  defp dashboard_renderer_artifact(_package), do: ""

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

  @spec upload_url(String.t()) :: String.t()
  def upload_url(package_id) do
    EndpointConfig.base_url() <> "/api/plugin-packages/#{package_id}/blob"
  end

  @spec download_url(String.t()) :: String.t()
  def download_url(package_id) do
    EndpointConfig.base_url() <> "/api/plugin-packages/#{package_id}/blob/download"
  end

  @spec put_blob(String.t(), binary()) :: :ok | {:error, term()}
  def put_blob(object_key, payload) when is_binary(payload) do
    case backend() do
      :filesystem -> put_blob_filesystem(object_key, payload)
      :jetstream -> put_blob_jetstream(object_key, payload)
    end
  end

  @spec put_blob_file(String.t(), String.t()) :: :ok | {:error, term()}
  def put_blob_file(object_key, source_path) when is_binary(source_path) do
    case backend() do
      :filesystem -> put_blob_file_filesystem(object_key, source_path)
      :jetstream -> put_blob_file_jetstream(object_key, source_path)
    end
  end

  def put_blob_file(_object_key, _source_path), do: {:error, :invalid_path}

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
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  @spec sha256_file(String.t()) :: {:ok, String.t()} | {:error, term()}
  def sha256_file(path) when is_binary(path) do
    digest =
      path
      |> File.stream!(65_536, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
        :crypto.hash_update(acc, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {:ok, digest}
  rescue
    error in File.Error -> {:error, error.reason}
  end

  def sha256_file(_path), do: {:error, :invalid_path}

  defp config do
    Application.get_env(:serviceradar_web_ng, :plugin_storage, [])
  end

  defp bucket_name do
    Keyword.get(config(), :jetstream_bucket, "serviceradar_plugins")
  end

  defp bucket_opts do
    ttl_seconds = Keyword.get(config(), :jetstream_ttl_seconds, 0)
    ttl_ns = if ttl_seconds > 0, do: ttl_seconds * 1_000_000_000, else: 0

    Enum.reject(
      [
        description: Keyword.get(config(), :jetstream_description),
        max_bucket_size: Keyword.get(config(), :jetstream_max_bucket_size),
        max_chunk_size: Keyword.get(config(), :jetstream_max_chunk_size),
        replicas: Keyword.get(config(), :jetstream_replicas, 1),
        storage: Keyword.get(config(), :jetstream_storage, :file),
        ttl: ttl_ns
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp signing_secret do
    Keyword.get(config(), :signing_secret) ||
      :serviceradar_web_ng
      |> Application.fetch_env!(Endpoint)
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
        dir = Path.dirname(path)

        case File.mkdir_p(dir) do
          :ok ->
            write_blob_file(path, payload, object_key, dir)

          {:error, reason} = error ->
            Logger.error(
              "plugin blob directory create failed backend=filesystem object_key=#{inspect(object_key)} dir=#{dir} base_path=#{base_path()} reason=#{inspect(reason)}"
            )

            error
        end

      {:error, reason} = error ->
        Logger.error(
          "plugin blob path resolution failed backend=filesystem object_key=#{inspect(object_key)} base_path=#{base_path()} reason=#{inspect(reason)}"
        )

        error
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp put_blob_file_filesystem(object_key, source_path) do
    case safe_path(object_key) do
      {:ok, path} ->
        dir = Path.dirname(path)

        with :ok <- File.mkdir_p(dir) do
          File.cp(source_path, path)
        end

      {:error, reason} = error ->
        Logger.error(
          "plugin blob path resolution failed backend=filesystem object_key=#{inspect(object_key)} base_path=#{base_path()} reason=#{inspect(reason)}"
        )

        error
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp write_blob_file(path, payload, object_key, dir) do
    case File.write(path, payload) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "plugin blob write failed backend=filesystem object_key=#{inspect(object_key)} path=#{path} dir=#{dir} base_path=#{base_path()} reason=#{inspect(reason)}"
        )

        error
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
      with {:ok, _} <- ensure_bucket(conn) do
        put_object_payload(conn, object_key, payload)
      end
    end)
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp put_blob_file_jetstream(object_key, source_path) do
    with_jetstream(fn conn ->
      with {:ok, _} <- ensure_bucket(conn),
           {:ok, payload} <- File.read(source_path) do
        put_object_payload(conn, object_key, payload)
      end
    end)
  end

  defp fetch_blob_jetstream(object_key) do
    with_jetstream(fn conn ->
      with {:ok, _} <- ensure_bucket(conn),
           {:ok, payload} <- get_object_payload(conn, object_key) do
        {:ok, {:binary, payload}}
      else
        {:error, %{"code" => 404}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp delete_blob_jetstream(object_key) do
    fn conn ->
      Object.delete(conn, bucket_name(), object_key)
    end
    |> with_jetstream()
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
    fn conn ->
      Object.info(conn, bucket_name(), object_key)
    end
    |> with_jetstream()
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

    case Stream.info(conn, stream_name) do
      {:ok, _} ->
        {:ok, :exists}

      {:error, %{"code" => 404}} ->
        create_bucket(conn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_bucket(conn) do
    stream_name = "OBJ_#{bucket_name()}"

    with {:ok, %{body: body}} <-
           Gnat.request(conn, "$JS.API.STREAM.CREATE.#{stream_name}", Jason.encode!(bucket_stream_config())),
         {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        %{"error" => reason} -> {:error, reason}
        response -> {:ok, response}
      end
    end
  end

  defp bucket_stream_config do
    opts = bucket_opts()
    ttl = Keyword.get(opts, :ttl, 0)

    [
      name: "OBJ_#{bucket_name()}",
      subjects: ["$O.#{bucket_name()}.C.>", "$O.#{bucket_name()}.M.>"],
      description: Keyword.get(opts, :description),
      discard: :new,
      allow_rollup_hdrs: true,
      max_age: ttl,
      max_bytes: Keyword.get(opts, :max_bucket_size, -1),
      max_msg_size: Keyword.get(opts, :max_chunk_size, -1),
      max_consumers: -1,
      max_msgs: -1,
      max_msgs_per_subject: -1,
      num_replicas: Keyword.get(opts, :replicas, 1),
      retention: :limits,
      storage: Keyword.get(opts, :storage, :file),
      duplicate_window: duplicate_window_for_ttl(ttl)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @two_minutes_in_nanoseconds 1_200_000_000
  defp duplicate_window_for_ttl(ttl) when ttl > 0 and ttl < @two_minutes_in_nanoseconds, do: ttl
  defp duplicate_window_for_ttl(_ttl), do: @two_minutes_in_nanoseconds

  @object_chunk_size 128 * 1024

  defp get_object_payload(conn, object_key) do
    bucket = bucket_name()

    with {:ok, collector} <- Agent.start_link(fn -> [] end) do
      try do
        case Object.get(conn, bucket, object_key, fn chunk ->
               Agent.update(collector, &[chunk | &1])
             end) do
          :ok ->
            payload =
              collector
              |> Agent.get(& &1)
              |> Enum.reverse()
              |> IO.iodata_to_binary()

            {:ok, payload}

          {:error, reason} ->
            {:error, reason}
        end
      after
        Agent.stop(collector)
      end
    end
  end

  defp put_object_payload(conn, object_key, payload) when is_binary(payload) do
    bucket = bucket_name()
    nuid = random_object_nuid()
    chunk_subject = object_chunk_subject(bucket, nuid)

    with :ok <- purge_prior_object_chunks(conn, bucket, object_key),
         {:ok, chunks, size, digest} <- publish_object_chunks(conn, chunk_subject, payload),
         {:ok, _} <- publish_object_meta(conn, bucket, object_key, nuid, chunks, size, digest) do
      :ok
    end
  end

  defp purge_prior_object_chunks(conn, bucket, object_key) do
    case Object.info(conn, bucket, object_key) do
      {:ok, %{nuid: nuid}} when is_binary(nuid) ->
        Stream.purge(conn, "OBJ_#{bucket}", nil, %{filter: object_chunk_subject(bucket, nuid)})

      {:error, %{"code" => 404}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_object_chunks(conn, chunk_subject, payload) do
    payload
    |> chunk_binary(@object_chunk_size)
    |> Enum.reduce_while({:ok, 0, 0, :crypto.hash_init(:sha256)}, fn chunk, {:ok, chunks, size, sha} ->
      case Gnat.request(conn, chunk_subject, chunk) do
        {:ok, _} ->
          {:cont, {:ok, chunks + 1, size + byte_size(chunk), :crypto.hash_update(sha, chunk)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, chunks, size, sha} -> {:ok, chunks, size, :crypto.hash_final(sha)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_object_meta(conn, bucket, object_key, nuid, chunks, size, digest) do
    meta = %{
      bucket: bucket,
      chunks: chunks,
      deleted: false,
      digest: "SHA-256=#{Base.url_encode64(digest)}",
      name: object_key,
      nuid: nuid,
      size: size
    }

    Gnat.request(conn, object_meta_subject(bucket, object_key), Jason.encode!(meta), headers: [{"Nats-Rollup", "sub"}])
  end

  defp chunk_binary(payload, chunk_size) when byte_size(payload) <= chunk_size, do: [payload]

  defp chunk_binary(payload, chunk_size) do
    do_chunk_binary(payload, chunk_size, [])
  end

  defp do_chunk_binary(<<>>, _chunk_size, acc), do: Enum.reverse(acc)

  defp do_chunk_binary(payload, chunk_size, acc) do
    case payload do
      <<chunk::binary-size(chunk_size), rest::binary>> ->
        do_chunk_binary(rest, chunk_size, [chunk | acc])

      chunk ->
        Enum.reverse([chunk | acc])
    end
  end

  defp object_chunk_subject(bucket, nuid), do: "$O.#{bucket}.C.#{nuid}"

  defp object_meta_subject(bucket, object_key) do
    "$O.#{bucket}.M.#{Base.url_encode64(object_key)}"
  end

  defp random_object_nuid do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
