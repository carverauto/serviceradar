defmodule ServiceRadar.Inventory.AdvisoryFeeds.StreamReader do
  @moduledoc """
  Off-disk, bounded-memory readers that yield one upstream record at a time.

  ## Streaming-decoder choice (tasks.md 3.3)

  `serviceradar_core` ships `jason` only (no `jaxon`/`jiffy` streaming decoders).
  Rather than add a new dependency for this slice, we bound memory at the
  **shard** level, which the design (D3) already names as the memory unit:

    * **nist-nvd2** is ~181 `nvdcve-2.0-NNN.json.gz` shards. We process one shard
      at a time: gunzip a single shard into memory (≤ ~25 MB decompressed),
      `Jason.decode` it, then iterate its `vulnerabilities` array and discard the
      shard before moving on. The resident working set is one shard, never the
      full ~360 MB dataset — satisfying the "bounded by a single shard" scenario.
    * **KEV / CISA** feeds are small (≤ a few MB); the single JSON is decoded once.

  If a future feed produces single multi-GB JSON files, swap in a true
  incremental decoder (Jaxon) or a `jq -c` NDJSON pre-split here without touching
  callers — they consume the `Stream` this module returns.

  Readers return a stream of `{:ok, record}` or an explicit `{:error, reason}`.
  A caller can therefore reject an incomplete snapshot instead of silently
  promoting the subset that happened to be readable.
  """

  require Logger

  @doc """
  Stream NVD 2.0 `vulnerabilities[]` records from a directory of `*.json.gz`
  shards (or `*.json` shards), one shard decoded at a time.
  """
  @spec stream_nvd_shards(Path.t()) :: Enumerable.t()
  def stream_nvd_shards(dir) do
    case shard_paths(dir) do
      {:ok, paths} -> Stream.flat_map(paths, &stream_shard/1)
      {:error, reason} -> [{:error, {:read_error, dir, reason}}]
    end
  end

  @doc """
  Stream records from a single NVD-shaped JSON file (`{"vulnerabilities": [...]}`)
  or a top-level array (VulnCheck KEV) or CISA's `{"vulnerabilities": [...]}`.

  `:records_key` selects the array key for object-wrapped feeds (default
  `"vulnerabilities"`); pass `:array` for a top-level array file.
  """
  @spec stream_json_file(Path.t(), keyword()) :: Enumerable.t()
  def stream_json_file(path, opts \\ []) do
    case read_json(path) do
      {:ok, decoded} -> records_from(decoded, opts)
      {:error, reason} -> [{:error, classify_error(path, reason)}]
    end
  end

  @doc """
  Decode an in-memory binary the same way `stream_json_file/2` decodes a file.
  Used by unit tests with fixtures.
  """
  @spec records_from_binary(binary(), keyword()) :: Enumerable.t()
  def records_from_binary(binary, opts \\ []) do
    case Jason.decode(binary) do
      {:ok, decoded} -> records_from(decoded, opts)
      {:error, reason} -> [{:error, {:parse_error, "binary", reason}}]
    end
  end

  @doc """
  Decode a single gzipped NVD shard binary into its `vulnerabilities` records.
  Used by unit tests with a synthetic `.json.gz`.
  """
  @spec records_from_gzip(binary()) :: [map()]
  def records_from_gzip(gz_binary) do
    gz_binary
    |> :zlib.gunzip()
    |> Jason.decode!()
    |> Map.get("vulnerabilities", [])
    |> List.wrap()
  end

  defp shard_paths(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        paths =
          names
          |> Enum.filter(&(String.ends_with?(&1, ".json.gz") or String.ends_with?(&1, ".json")))
          |> Enum.sort()
          |> Enum.map(&Path.join(dir, &1))

        {:ok, paths}

      {:error, reason} ->
        Logger.warning("advisory_feeds: cannot list shard dir #{dir}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp stream_shard(path) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          decoded =
            if String.ends_with?(path, ".gz") do
              binary |> :zlib.gunzip() |> Jason.decode!()
            else
              Jason.decode!(binary)
            end

          records_from(decoded, records_key: "vulnerabilities")
        rescue
          error -> [{:error, {:parse_error, path, Exception.message(error)}}]
        end

      {:error, reason} ->
        Logger.warning("advisory_feeds: unreadable shard #{path}: #{inspect(reason)}")
        [{:error, {:read_error, path, reason}}]
    end
  end

  defp read_json(path) do
    with {:ok, binary} <- File.read(path) do
      Jason.decode(binary)
    end
  end

  defp records_from(decoded, opts) do
    cond do
      Keyword.get(opts, :records_key) == :array and is_list(decoded) ->
        Stream.map(decoded, &{:ok, &1})

      is_list(decoded) ->
        Stream.map(decoded, &{:ok, &1})

      is_map(decoded) ->
        key = Keyword.get(opts, :records_key, "vulnerabilities")

        case Map.fetch(decoded, key) do
          {:ok, records} when is_list(records) -> Stream.map(records, &{:ok, &1})
          _ -> [{:error, {:invalid_records, key}}]
        end

      true ->
        [{:error, {:invalid_records, Keyword.get(opts, :records_key, "vulnerabilities")}}]
    end
  end

  defp classify_error(path, %Jason.DecodeError{} = reason), do: {:parse_error, path, reason}
  defp classify_error(path, reason), do: {:read_error, path, reason}
end
