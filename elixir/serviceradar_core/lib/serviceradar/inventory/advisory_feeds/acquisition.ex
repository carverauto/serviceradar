defmodule ServiceRadar.Inventory.AdvisoryFeeds.Acquisition do
  @moduledoc """
  Disk-staged feed acquisition (design D2, tasks 3.1/3.2).

  * **VulnCheck** uses the verified two-step backup flow: `GET /v3/backup/<index>`
    with `Authorization: Bearer <token>` returns `data[].url`, a presigned S3 zip
    (15-min TTL). The presigned URL is fetched **without** the Authorization
    header and streamed straight to `download.zip` on disk. When the index entry
    carries a `sha256` it is verified.
  * **CISA** is a single public JSON streamed to disk.

  All downloads stream to a file (`Req` `into: File.stream!/1`) — the archive is
  never held whole in memory. Extraction uses Erlang `:zip`, leaving `*.json.gz`
  members in place for shard-by-shard decoding by `StreamReader`.

  `:http_get` / `:http_get_json` are injectable for tests.
  """

  alias ServiceRadar.Inventory.AdvisoryFeeds.Staging

  require Logger

  @vulncheck_base "https://api.vulncheck.com/v3/backup"
  @default_timeout_ms 120_000
  @user_agent "ServiceRadar advisory-feed-fetcher"

  @type acquired :: %{
          extracted_dir: Path.t(),
          run_dir: Path.t(),
          download_path: Path.t() | nil,
          format: :json | :json_gz_shards,
          source_url: String.t() | nil,
          sha256: String.t() | nil
        }

  @doc """
  Resolve and download a VulnCheck backup index to disk, then extract it.

  `index` is e.g. `"vulncheck-kev"` or `"nist-nvd2"`.
  """
  @spec acquire_vulncheck(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, acquired()} | {:error, term()}
  def acquire_vulncheck(index, token, run_id, opts \\ []) do
    with {:ok, paths} <- Staging.prepare_run(index, run_id),
         {:ok, entry} <- resolve_backup_index(index, token, opts),
         url when is_binary(url) <- entry["url"] || {:error, :no_presigned_url},
         :ok <- stream_to_disk(url, paths.download_path, opts),
         :ok <- maybe_verify_sha256(paths.download_path, entry["sha256"], opts),
         {:ok, format} <- extract(paths.download_path, paths.extracted_dir) do
      {:ok,
       %{
         extracted_dir: paths.extracted_dir,
         run_dir: paths.run_dir,
         download_path: paths.download_path,
         format: format,
         source_url: url,
         sha256: entry["sha256"]
       }}
    else
      {:error, _} = error -> error
      other -> {:error, {:acquire_failed, other}}
    end
  end

  @doc "Download CISA KEV JSON to disk (no archive)."
  @spec acquire_cisa(String.t(), String.t(), keyword()) :: {:ok, acquired()} | {:error, term()}
  def acquire_cisa(url, run_id, opts \\ []) do
    with {:ok, paths} <- Staging.prepare_run("cisa-kev", run_id),
         json_path = Path.join(paths.extracted_dir, "cisa-kev.json"),
         :ok <- stream_to_disk(url, json_path, opts) do
      {:ok,
       %{
         extracted_dir: paths.extracted_dir,
         run_dir: paths.run_dir,
         download_path: nil,
         format: :json,
         source_url: url,
         sha256: nil
       }}
    end
  end

  @doc """
  Resolve the backup index: `GET /v3/backup/<index>` (Bearer) → first `data[]`.
  """
  @spec resolve_backup_index(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_backup_index(index, token, opts \\ []) do
    url = "#{@vulncheck_base}/#{index}"
    http_get_json = Keyword.get(opts, :http_get_json, &default_get_json/2)

    headers = [{"authorization", "Bearer #{token}"}]

    case http_get_json.(url, headers) do
      {:ok, %{"data" => [first | _]}} when is_map(first) -> {:ok, first}
      {:ok, %{"data" => []}} -> {:error, :empty_backup_index}
      {:ok, other} -> {:error, {:unexpected_backup_response, other}}
      {:error, reason} -> {:error, {:backup_index_failed, reason}}
    end
  end

  @doc """
  Extract `download.zip` into `extracted_dir`; classify the payload.

  Returns `{:ok, :json_gz_shards}` when the archive contains `*.json.gz` members
  (nist-nvd2) or `{:ok, :json}` for a single `.json` (KEV).
  """
  @spec extract(Path.t(), Path.t()) :: {:ok, :json | :json_gz_shards} | {:error, term()}
  def extract(zip_path, extracted_dir) do
    case :zip.unzip(String.to_charlist(zip_path), [{:cwd, String.to_charlist(extracted_dir)}]) do
      {:ok, _files} ->
        {:ok, classify(extracted_dir)}

      {:error, reason} ->
        {:error, {:unzip_failed, reason}}
    end
  end

  defp classify(extracted_dir) do
    case File.ls(extracted_dir) do
      {:ok, names} ->
        if Enum.any?(names, &String.ends_with?(&1, ".json.gz")) do
          :json_gz_shards
        else
          :json
        end

      _ ->
        :json
    end
  end

  defp stream_to_disk(url, dest_path, opts) do
    http_get = Keyword.get(opts, :http_get, &default_stream_get/2)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    _ = File.mkdir_p(Path.dirname(dest_path))
    _ = File.rm(dest_path)

    # No Authorization header on the presigned S3 GET — the URL is self-signed.
    case http_get.(url, into: File.stream!(dest_path), receive_timeout: timeout) do
      :ok -> :ok
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> download_error(dest_path, {:http_status, status})
      {:error, reason} -> download_error(dest_path, reason)
      other -> download_error(dest_path, {:invalid_http_result, other})
    end
  rescue
    error -> download_error(dest_path, error)
  end

  defp download_error(dest_path, reason) do
    _ = File.rm(dest_path)
    {:error, {:download_failed, reason}}
  end

  defp maybe_verify_sha256(_path, sha256, _opts) when sha256 in [nil, ""], do: :ok

  defp maybe_verify_sha256(path, expected, _opts) do
    actual =
      path
      |> File.stream!(1_048_576, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if String.downcase(expected) == actual do
      :ok
    else
      {:error, {:sha256_mismatch, expected: String.downcase(expected), actual: actual}}
    end
  end

  @doc false
  def req_opts(timeout_ms \\ @default_timeout_ms) do
    # Req 0.6 refuses :finch and :connect_options together. The named
    # ServiceRadar.Finch pool already owns connect/TLS settings.
    [
      receive_timeout: timeout_ms,
      retry: :transient,
      finch: ServiceRadar.Finch
    ]
  end

  defp default_get_json(url, headers) do
    require_req!()

    opts =
      [
        url: url,
        headers: [{"user-agent", @user_agent} | headers],
        decode_body: :json,
        max_retries: 3
      ] ++ req_opts()

    case Req.get(opts) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_stream_get(url, opts) do
    require_req!()

    Req.get(
      [url: url, headers: [{"user-agent", @user_agent}], max_retries: 1] ++ req_opts() ++ opts
    )
  end

  defp require_req! do
    if !Code.ensure_loaded?(Req) do
      raise "Req not available for advisory feed download"
    end
  end
end
