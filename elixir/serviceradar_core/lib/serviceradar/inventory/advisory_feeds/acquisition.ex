defmodule ServiceRadar.Inventory.AdvisoryFeeds.Acquisition do
  @moduledoc """
  Disk-staged feed acquisition (design D2, tasks 3.1/3.2).

  * **VulnCheck** uses the verified two-step backup flow: `GET /v3/backup/<index>`
    with `Authorization: Bearer <token>` returns `data[].url`, a presigned S3 zip
    (15-min TTL). The presigned URL is fetched **without** the Authorization
    header and streamed straight to `download.zip` on disk. When the index entry
    carries a `sha256` it is verified.
  * **CISA** is a single public JSON streamed to disk.

  CISA and presigned VulnCheck downloads use `ServiceRadar.HTTP.EgressClient`;
  see its module documentation for the streaming and CONNECT-proxy contract.
  All downloads stream to a file - the archive is never held whole in memory.
  Extraction uses Erlang `:zip`, leaving `*.json.gz`
  members in place for shard-by-shard decoding by `StreamReader`.

  `:http_get` / `:http_get_json` are injectable for tests.
  """

  alias ServiceRadar.HTTP.EgressClient
  alias ServiceRadar.Inventory.AdvisoryFeeds.Staging
  alias ServiceRadar.Policies.OutboundFetch

  defmodule SecretDownloadLimitError do
    @moduledoc false
    defexception message: "archive download exceeded compressed byte limit"
  end

  defmodule CappedFile do
    @moduledoc false
    defstruct [:path, :max_bytes]
  end

  defimpl Collectable, for: CappedFile do
    def into(%{path: path, max_bytes: max_bytes} = original) do
      {:ok, io} = File.open(path, [:write, :binary])

      {{io, 0},
       fn
         {file, size}, {:cont, chunk} ->
           next_size = size + IO.iodata_length(chunk)

           if next_size > max_bytes do
             File.close(file)
             raise ServiceRadar.Inventory.AdvisoryFeeds.Acquisition.SecretDownloadLimitError
           end

           :ok = IO.binwrite(file, chunk)
           {file, next_size}

         {file, _size}, :done ->
           File.close(file)
           original

         {file, _size}, :halt ->
           File.close(file)
           :ok
       end}
    end
  end

  @vulncheck_base "https://api.vulncheck.com/v3/backup"
  @default_timeout_ms 120_000
  @user_agent "ServiceRadar advisory-feed-fetcher"
  @archive_limits %{
    members: 250_000,
    path_bytes: 1_024,
    file_bytes: 64 * 1_024 * 1_024,
    total_bytes: 4 * 1_024 * 1_024 * 1_024,
    compressed_bytes: 2 * 1_024 * 1_024 * 1_024
  }
  @ubuntu_archive_limits %{compressed_bytes: 256 * 1_024 * 1_024}
  @ubuntu_combined_compressed_bytes 512 * 1_024 * 1_024

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
    with {:ok, paths} <- Staging.prepare_run(index, run_id) do
      result =
        with {:ok, entry} <- resolve_backup_index(index, token, opts),
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

      cleanup_failed_run(paths.run_dir, result)
    end
  end

  @doc "Download CISA KEV JSON to disk (no archive)."
  @spec acquire_cisa(String.t(), String.t(), keyword()) :: {:ok, acquired()} | {:error, term()}
  def acquire_cisa(url, run_id, opts \\ []) do
    with {:ok, paths} <- Staging.prepare_run("cisa-kev", run_id) do
      json_path = Path.join(paths.extracted_dir, "cisa-kev.json")

      result =
        case stream_to_disk(url, json_path, opts) do
          :ok ->
            {:ok,
             %{
               extracted_dir: paths.extracted_dir,
               run_dir: paths.run_dir,
               download_path: nil,
               format: :json,
               source_url: url,
               sha256: nil
             }}

          {:error, _} = error ->
            error
        end

      cleanup_failed_run(paths.run_dir, result)
    end
  end

  @doc "Download and validator-pin Canonical's compact OSV/VEX publication pair."
  def acquire_ubuntu_pair(feed, osv_url, vex_url, run_id, opts \\ []) do
    with {:ok, paths} <- Staging.prepare_run(feed, run_id) do
      osv_path = Path.join(paths.run_dir, "osv-all.tar.xz")
      vex_path = Path.join(paths.run_dir, "vex-all.tar.xz")

      download_opts =
        Keyword.update(opts, :limits, @ubuntu_archive_limits, fn limits ->
          Map.merge(@ubuntu_archive_limits, Map.new(limits))
        end)

      combined_limit =
        Keyword.get(opts, :combined_compressed_bytes, @ubuntu_combined_compressed_bytes)

      result =
        with {:ok, %{osv: osv_response, vex: vex_response}} <-
               download_ubuntu_pair(
                 [{:osv, osv_url, osv_path}, {:vex, vex_url, vex_path}],
                 download_opts
               ),
             :ok <- combined_archive_cap(osv_path, vex_path, combined_limit),
             {:ok, osv_current} <- revalidate_archive(osv_url, osv_response, opts),
             {:ok, vex_current} <- revalidate_archive(vex_url, vex_response, opts),
             {:ok, publication} <-
               validate_ubuntu_publication(
                 %{osv: osv_response, vex: vex_response},
                 %{osv: osv_current, vex: vex_current},
                 Keyword.get(opts, :now, DateTime.utc_now())
               ) do
          artifacts = %{
            osv: artifact_provenance(osv_url, osv_path, osv_response, publication.osv),
            vex: artifact_provenance(vex_url, vex_path, vex_response, publication.vex)
          }

          generation_provenance = combined_generation_provenance(artifacts)

          {:ok,
           %{
             run_dir: paths.run_dir,
             osv_path: osv_path,
             vex_path: vex_path,
             prepared_dir: Path.join(paths.run_dir, "prepared"),
             artifacts: artifacts,
             acquired_at: DateTime.utc_now(),
             generation_provenance: generation_provenance,
             format: :ubuntu_tar_xz_pair
           }}
        end

      cleanup_failed_run(paths.run_dir, result)
    end
  end

  defp download_ubuntu_pair(artifacts, opts) do
    artifacts
    |> Task.async_stream(
      fn {kind, url, path} -> {kind, stream_archive(url, path, opts)} end,
      ordered: false,
      max_concurrency: 2,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {kind, {:ok, response}}}, {:ok, responses} ->
        {:cont, {:ok, Map.put(responses, kind, response)}}

      {:ok, {_kind, {:error, _} = error}}, _ ->
        {:halt, error}

      {:exit, reason}, _ ->
        {:halt, {:error, {:download_task_exit, reason}}}
    end)
    |> case do
      {:ok, %{osv: _, vex: _} = responses} -> {:ok, responses}
      {:ok, _} -> {:error, :incomplete_pair_download}
      {:error, _} = error -> error
    end
  end

  @doc false
  def validate_ubuntu_publication(download, current, now) do
    with {:ok, osv} <- publication_validator(download.osv),
         {:ok, vex} <- publication_validator(download.vex),
         {:ok, current_osv} <- publication_validator(current.osv),
         {:ok, current_vex} <- publication_validator(current.vex),
         true <- osv == current_osv || {:error, {:validator_changed, :osv}},
         true <- vex == current_vex || {:error, {:validator_changed, :vex}},
         true <-
           abs(DateTime.diff(osv.timestamp, vex.timestamp, :second)) <= 5 ||
             {:error, :publication_skew},
         true <-
           DateTime.diff(osv.timestamp, now, :second) <= 300 ||
             {:error, :future_publication},
         true <-
           DateTime.diff(vex.timestamp, now, :second) <= 300 ||
             {:error, :future_publication} do
      {:ok, %{osv: osv, vex: vex}}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_publication}
    end
  end

  defp artifact_provenance(url, path, response, validator) do
    %{
      url: url,
      requested_url: url,
      final_url: Map.get(response, :resolved_url, url),
      etag: validator.etag,
      last_modified: validator.last_modified,
      sha256: sha256(path),
      bytes: File.stat!(path).size
    }
  end

  @doc false
  def combined_generation_provenance(%{osv: osv, vex: vex}) do
    [
      osv.requested_url,
      osv.final_url,
      osv.etag,
      osv.last_modified,
      osv.sha256,
      Integer.to_string(osv.bytes),
      vex.requested_url,
      vex.final_url,
      vex.etag,
      vex.last_modified,
      vex.sha256,
      Integer.to_string(vex.bytes)
    ]
    |> Enum.map(fn value -> [<<byte_size(value)::64-big>>, value] end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp combined_archive_cap(osv_path, vex_path, limit) when is_integer(limit) and limit > 0 do
    with {:ok, osv} <- File.stat(osv_path),
         {:ok, vex} <- File.stat(vex_path) do
      cap(osv.size + vex.size, limit, :combined_compressed_bytes)
    end
  end

  defp combined_archive_cap(_, _, _), do: {:error, :invalid_combined_compressed_limit}

  defp revalidate_archive(url, download_response, opts) do
    http_head = Keyword.get(opts, :http_head, &default_archive_head/2)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with {:ok, validator} <- publication_validator(download_response) do
      headers = [
        {"if-match", validator.etag},
        {"if-unmodified-since", validator.last_modified}
      ]

      case http_head.(url, receive_timeout: timeout, headers: headers) do
        {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
        {:ok, %{status: status}} -> {:error, {:revalidation_status, status}}
        {:error, reason} -> {:error, {:revalidation_failed, reason}}
        other -> {:error, {:invalid_revalidation_result, other}}
      end
    end
  end

  defp default_archive_head(url, opts) do
    {headers, opts} = Keyword.pop(opts, :headers, [])

    OutboundFetch.request(
      :head,
      url,
      [headers: [{"user-agent", @user_agent} | headers], retry: false] ++ opts
    )
  end

  defp publication_validator(response) do
    etag = response_header(response, "etag")
    modified = response_header(response, "last-modified")

    with true <-
           (is_binary(etag) and String.trim(etag) != "" and
              not String.contains?(etag, <<0>>)) || {:error, :missing_etag},
         true <-
           (is_binary(modified) and String.trim(modified) != "" and
              not String.contains?(modified, <<0>>)) ||
             {:error, :missing_last_modified},
         {:ok, timestamp} <- parse_http_date(modified) do
      {:ok, %{etag: etag, last_modified: modified, timestamp: timestamp}}
    else
      {:error, _} = error -> error
      false -> {:error, :missing_validator}
    end
  end

  defp parse_http_date(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, minute, second}} ->
        DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second), "Etc/UTC")

      _ ->
        {:error, :invalid_last_modified}
    end
  rescue
    _ -> {:error, :invalid_last_modified}
  end

  defp response_header(%{headers: headers}, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp response_header(%{etag: value}, "etag") when is_binary(value), do: value

  defp response_header(%{last_modified: value}, "last-modified") when is_binary(value), do: value

  defp response_header(_, _), do: nil

  defp stream_archive(url, path, opts) do
    http_get = Keyword.get(opts, :http_get, &default_archive_get/2)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    limits = Map.merge(@archive_limits, Map.new(Keyword.get(opts, :limits, %{})))
    _ = File.rm(path)

    case http_get.(url,
           into: %CappedFile{path: path, max_bytes: limits.compressed_bytes},
           receive_timeout: timeout
         ) do
      :ok -> {:ok, %{status: 200}}
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: status}} -> download_error(path, {:http_status, status})
      {:error, reason} -> download_error(path, reason)
      other -> download_error(path, {:invalid_http_result, other})
    end
  rescue
    _error in SecretDownloadLimitError ->
      download_error(path, {:archive_limit_exceeded, :compressed_bytes})

    error ->
      download_error(path, error)
  end

  defp default_archive_get(url, opts) do
    OutboundFetch.get(
      url,
      [headers: [{"user-agent", @user_agent}], retry: false] ++ opts
    )
  end

  defp cap(value, limit, _kind) when is_integer(value) and value <= limit, do: :ok
  defp cap(_value, _limit, kind), do: {:error, {:archive_limit_exceeded, kind}}

  defp sha256(path) do
    path
    |> File.stream!(1_048_576, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp cleanup_failed_run(_run_dir, {:ok, _} = ok), do: ok

  defp cleanup_failed_run(run_dir, {:error, _} = error) do
    Staging.cleanup_run(run_dir)
    error
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
    download_opts =
      opts
      |> Keyword.take([:proxy, :profile, :cacerts, :cacertfile])
      |> Keyword.merge(into: File.stream!(dest_path), receive_timeout: timeout)

    case http_get.(url, download_opts) do
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
      finch: [name: ServiceRadar.Finch]
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
    %{path: path} = Keyword.fetch!(opts, :into)

    case File.open(path, [:write, :binary], fn file ->
           into = fn {:data, chunk}, acc ->
             case IO.binwrite(file, chunk) do
               :ok -> {:cont, acc}
               {:error, reason} -> {:error, reason}
             end
           end

           EgressClient.get(
             url,
             Keyword.merge(opts, into: into, headers: [{"user-agent", @user_agent}])
           )
         end) do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  defp require_req! do
    if !Code.ensure_loaded?(Req) do
      raise "Req not available for advisory feed download"
    end
  end
end
