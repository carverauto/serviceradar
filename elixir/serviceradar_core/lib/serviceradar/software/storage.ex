defmodule ServiceRadar.Software.Storage do
  @moduledoc """
  Dual-backend storage for the software library.

  Supports local filesystem and S3 storage. Credential resolution for S3:
    1. ENV vars (S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY)
    2. Database-stored credentials (AshCloak-encrypted)
    3. Disabled (S3 operations return {:error, :s3_not_configured})

  ## Configuration

  S3 settings can be provided via ENV vars or the SoftwareStorageConfig resource:
    - S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY
    - S3_BUCKET, S3_REGION, S3_ENDPOINT
  """

  require Logger

  @default_local_path "/var/lib/serviceradar/software"

  # -- Public API --

  @doc "Store a file from a local path into the configured backend(s)."
  @spec put(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def put(object_key, source_path) do
    case storage_mode() do
      :local -> put_local(object_key, source_path)
      :s3 -> put_s3(object_key, source_path)
      :both -> put_both(object_key, source_path)
    end
  end

  @doc "Retrieve a file from storage to a local destination path."
  @spec get(String.t(), String.t()) :: :ok | {:error, term()}
  def get(object_key, dest_path) do
    case storage_mode() do
      :local -> get_local(object_key, dest_path)
      :s3 -> get_s3(object_key, dest_path)
      :both -> get_local(object_key, dest_path)
    end
  end

  @doc "Delete a file from storage."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(object_key) do
    case storage_mode() do
      :local -> delete_local(object_key)
      :s3 -> delete_s3(object_key)
      :both -> delete_both(object_key)
    end
  end

  @doc "List files in storage with an optional prefix."
  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list(prefix \\ "") do
    case storage_mode() do
      :local -> list_local(prefix)
      :s3 -> list_s3(prefix)
      :both -> list_local(prefix)
    end
  end

  @doc "List files with metadata (path, size, modified)."
  @spec list_with_metadata(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_with_metadata(prefix \\ "") do
    case storage_mode() do
      :local -> list_local_with_metadata(prefix)
      :s3 -> list_s3(prefix) |> wrap_paths()
      :both -> list_local_with_metadata(prefix)
    end
  end

  @doc "Test S3 connectivity with explicit S3 configuration."
  @spec test_s3_connection(map()) :: :ok | {:error, term()}
  def test_s3_connection(%{bucket: bucket} = config) when is_binary(bucket) and bucket != "" do
    request =
      ExAws.S3.list_objects(bucket,
        prefix: Map.get(config, :prefix, ""),
        max_keys: 1
      )

    case ExAws.request(request, s3_request_opts(config)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:s3_list_failed, reason}}
    end
  end

  def test_s3_connection(_), do: {:error, :invalid_s3_config}

  defp list_local_with_metadata(prefix) do
    base = local_path()
    search_path = Path.join(base, prefix)

    if File.dir?(base) do
      files =
        Path.wildcard(Path.join(search_path, "**"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(fn path ->
          stat = File.stat!(path)
          rel = Path.relative_to(path, base)

          %{
            path: rel,
            size: stat.size,
            modified: stat.mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
          }
        end)
        |> Enum.sort_by(& &1.modified, {:desc, DateTime})

      {:ok, files}
    else
      {:ok, []}
    end
  end

  defp wrap_paths({:ok, paths}) when is_list(paths) do
    {:ok, Enum.map(paths, fn path -> %{path: path, size: nil, modified: nil} end)}
  end

  defp wrap_paths(error), do: error

  @doc "Compute SHA-256 hash of a local file."
  @spec sha256(String.t()) :: {:ok, String.t()} | {:error, term()}
  def sha256(file_path) do
    case File.read(file_path) do
      {:ok, data} ->
        hash =
          :crypto.hash(:sha256, data)
          |> Base.encode16(case: :lower)

        {:ok, hash}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Verify a file's SHA-256 hash matches the expected value."
  @spec verify_hash(String.t(), String.t()) :: :ok | {:error, :hash_mismatch}
  def verify_hash(file_path, expected_hash) do
    case sha256(file_path) do
      {:ok, ^expected_hash} -> :ok
      {:ok, _actual} -> {:error, :hash_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- Local Filesystem Backend --

  defp put_local(object_key, source_path) do
    dest = local_file_path(object_key)
    dest_dir = Path.dirname(dest)

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, _} <- File.copy(source_path, dest) do
      {:ok, object_key}
    end
  end

  defp get_local(object_key, dest_path) do
    source = local_file_path(object_key)
    dest_dir = Path.dirname(dest_path)

    with :ok <- File.mkdir_p(dest_dir),
         {:ok, _} <- File.copy(source, dest_path) do
      :ok
    end
  end

  defp delete_local(object_key) do
    path = local_file_path(object_key)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp list_local(prefix) do
    base = local_path()
    search_path = Path.join(base, prefix)

    if File.dir?(base) do
      files =
        Path.wildcard(Path.join(search_path, "**"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, base))

      {:ok, files}
    else
      {:ok, []}
    end
  end

  defp local_file_path(object_key) do
    Path.join(local_path(), object_key)
  end

  # -- S3 Backend --

  defp put_s3(object_key, source_path) do
    with {:ok, config} <- s3_config(),
         {:ok, data} <- File.read(source_path) do
      full_key = s3_key(config, object_key)

      request =
        ExAws.S3.put_object(config.bucket, full_key, data,
          content_type: "application/octet-stream"
        )

      case ExAws.request(request, s3_request_opts(config)) do
        {:ok, _} -> {:ok, object_key}
        {:error, reason} -> {:error, {:s3_put_failed, reason}}
      end
    end
  end

  defp get_s3(object_key, dest_path) do
    with {:ok, config} <- s3_config() do
      full_key = s3_key(config, object_key)

      request = ExAws.S3.get_object(config.bucket, full_key)

      case ExAws.request(request, s3_request_opts(config)) do
        {:ok, %{body: body}} ->
          dest_dir = Path.dirname(dest_path)
          File.mkdir_p!(dest_dir)
          File.write(dest_path, body)

        {:error, reason} ->
          {:error, {:s3_get_failed, reason}}
      end
    end
  end

  defp delete_s3(object_key) do
    with {:ok, config} <- s3_config() do
      full_key = s3_key(config, object_key)

      request = ExAws.S3.delete_object(config.bucket, full_key)

      case ExAws.request(request, s3_request_opts(config)) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:s3_delete_failed, reason}}
      end
    end
  end

  defp list_s3(prefix) do
    with {:ok, config} <- s3_config() do
      full_prefix = s3_key(config, prefix)

      request = ExAws.S3.list_objects(config.bucket, prefix: full_prefix)

      case ExAws.request(request, s3_request_opts(config)) do
        {:ok, %{body: %{contents: contents}}} ->
          keys =
            contents
            |> Enum.map(& &1.key)
            |> Enum.map(&String.replace_prefix(&1, config.prefix || "", ""))

          {:ok, keys}

        {:error, reason} ->
          {:error, {:s3_list_failed, reason}}
      end
    end
  end

  # -- Dual Backend --

  defp put_both(object_key, source_path) do
    with {:ok, _} <- put_local(object_key, source_path) do
      case put_s3(object_key, source_path) do
        {:ok, _} ->
          {:ok, object_key}

        {:error, reason} ->
          Logger.warning("S3 upload failed (local copy saved): #{inspect(reason)}")
          {:ok, object_key}
      end
    end
  end

  defp delete_both(object_key) do
    local_result = delete_local(object_key)
    s3_result = delete_s3(object_key)

    case {local_result, s3_result} do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> Logger.warning("S3 delete failed: #{inspect(reason)}"); :ok
      {error, _} -> error
    end
  end

  # -- S3 Configuration Resolution --

  defp s3_config do
    # 1. Try ENV vars
    case env_s3_config() do
      {:ok, config} ->
        {:ok, config}

      :not_configured ->
        # 2. Try database-stored config
        case db_s3_config() do
          {:ok, config} -> {:ok, config}
          :not_configured -> {:error, :s3_not_configured}
        end
    end
  end

  defp env_s3_config do
    access_key = System.get_env("S3_ACCESS_KEY_ID")
    secret_key = System.get_env("S3_SECRET_ACCESS_KEY")
    bucket = System.get_env("S3_BUCKET")

    if access_key && secret_key && bucket do
      {:ok,
       %{
         access_key_id: access_key,
         secret_access_key: secret_key,
         bucket: bucket,
         region: System.get_env("S3_REGION", "us-east-1"),
         endpoint: System.get_env("S3_ENDPOINT"),
         prefix: System.get_env("S3_PREFIX", "software/")
       }}
    else
      :not_configured
    end
  end

  defp db_s3_config do
    # Query the StorageConfig resource for database-stored credentials
    case Ash.read_one(ServiceRadar.Software.StorageConfig, action: :get_config) do
      {:ok, nil} ->
        :not_configured

      {:ok, config} ->
        # Decrypt the credentials
        case decrypt_s3_credentials(config) do
          {:ok, access_key, secret_key} when is_binary(access_key) and is_binary(secret_key) ->
            {:ok,
             %{
               access_key_id: access_key,
               secret_access_key: secret_key,
               bucket: config.s3_bucket,
               region: config.s3_region || "us-east-1",
               endpoint: config.s3_endpoint,
               prefix: config.s3_prefix || "software/"
             }}

          _ ->
            :not_configured
        end

      {:error, _} ->
        :not_configured
    end
  end

  defp decrypt_s3_credentials(config) do
    # AshCloak adds calculations for encrypted attributes.
    # Loading them triggers decryption via the Vault.
    case Ash.load(config, [:s3_access_key_id, :s3_secret_access_key]) do
      {:ok, loaded} ->
        access_key = Map.get(loaded.calculations, :s3_access_key_id)
        secret_key = Map.get(loaded.calculations, :s3_secret_access_key)

        if access_key && secret_key do
          {:ok, access_key, secret_key}
        else
          :not_configured
        end

      {:error, _} ->
        :not_configured
    end
  end

  defp s3_key(%{prefix: prefix}, object_key) when is_binary(prefix) do
    prefix <> object_key
  end

  defp s3_key(_, object_key), do: object_key

  defp s3_request_opts(%{access_key_id: ak, secret_access_key: sk} = config) do
    opts = [
      access_key_id: ak,
      secret_access_key: sk,
      region: config.region || "us-east-1"
    ]

    case config[:endpoint] do
      nil -> opts
      "" -> opts
      endpoint -> Keyword.put(opts, :host, endpoint)
    end
  end

  # -- Helpers --

  defp storage_mode do
    Application.get_env(:serviceradar_core, :software_storage, [])
    |> Keyword.get(:mode, :local)
  end

  defp local_path do
    Application.get_env(:serviceradar_core, :software_storage, [])
    |> Keyword.get(:local_path, @default_local_path)
  end
end
