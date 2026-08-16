defmodule ServiceRadar.Inventory.AdvisoryFeeds.StreamReader do
  @moduledoc """
  Off-disk, bounded-memory readers that yield one upstream record at a time.

  ## Streaming-decoder choice (tasks.md 3.3)

  Shards are decoded through `AdvisoryFeeds.Json` (Torque/sonic-rs when loaded,
  otherwise Jason). Memory is bounded at the **shard** level:

    * **nist-nvd2** is ~181 `nvdcve-2.0-NNN.json.gz` shards. We process one shard
      at a time: gunzip a single shard into memory (≤ ~25 MB decompressed),
      decode it, then iterate its `vulnerabilities` array and discard the
      shard before moving on.
    * **KEV / CISA** feeds are small (≤ a few MB); the single JSON is decoded once.

  All readers return a `Stream` of `{:ok, record}` so the caller can chunk and
  bulk-load without holding the whole feed.
  """

  alias ServiceRadar.Inventory.AdvisoryFeeds.Json

  require Logger

  @doc """
  Stream NVD 2.0 `vulnerabilities[]` records from a directory of `*.json.gz`
  shards (or `*.json` shards), one shard decoded at a time.
  """
  @spec stream_nvd_shards(Path.t(), keyword()) :: Enumerable.t()
  def stream_nvd_shards(dir, opts \\ []) do
    dir
    |> nvd_shard_paths(opts)
    |> Stream.flat_map(&stream_nvd_shard/1)
  end

  @doc "Stream `vulnerabilities[]` records from a single NVD shard file."
  @spec stream_nvd_shard(Path.t()) :: Enumerable.t()
  def stream_nvd_shard(path), do: stream_shard(path)

  @doc """
  Sorted shard file paths, optionally skipping those through `after:`.

  `after: "nvdcve-2.0-040.json.gz"` yields 041 and later so a restarted
  worker can continue a generation instead of reloading finished shards.
  """
  @spec nvd_shard_paths(Path.t(), keyword()) :: [Path.t()]
  def nvd_shard_paths(dir, opts \\ []) do
    after_shard = Keyword.get(opts, :after)

    dir
    |> shard_paths()
    |> drop_through(after_shard)
  end

  defp drop_through(paths, after_shard) when after_shard in [nil, ""], do: paths

  defp drop_through(paths, after_shard) when is_binary(after_shard) do
    Enum.drop_while(paths, &(Path.basename(&1) <= after_shard))
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
      {:error, reason} -> raise "failed to decode #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Decode an in-memory binary the same way `stream_json_file/2` decodes a file.
  Used by unit tests with fixtures.
  """
  @spec records_from_binary(binary(), keyword()) :: Enumerable.t()
  def records_from_binary(binary, opts \\ []) do
    case Json.decode(binary) do
      {:ok, decoded} -> records_from(decoded, opts)
      {:error, reason} -> raise "failed to decode binary: #{inspect(reason)}"
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
    |> Json.decode!()
    |> Map.get("vulnerabilities", [])
    |> List.wrap()
  end

  defp shard_paths(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&(String.ends_with?(&1, ".json.gz") or String.ends_with?(&1, ".json")))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      {:error, reason} ->
        Logger.warning("advisory_feeds: cannot list shard dir #{dir}: #{inspect(reason)}")
        []
    end
  end

  defp stream_shard(path) do
    case File.read(path) do
      {:ok, binary} ->
        records =
          if String.ends_with?(path, ".gz") do
            records_from_gzip(binary)
          else
            binary |> Json.decode!() |> Map.get("vulnerabilities", []) |> List.wrap()
          end

        Enum.map(records, &{:ok, &1})

      {:error, reason} ->
        # Listing the dir and reading each shard is not atomic. A mid-run
        # cleanup (or a sibling core replica sharing the RWO volume) can
        # unlink a shard after File.ls/1. Skip it instead of crashing the
        # whole nist-nvd2 job.
        Logger.warning("advisory_feeds: skip shard #{path}: #{inspect(reason)}")
        []
    end
  end

  defp read_json(path) do
    with {:ok, binary} <- File.read(path) do
      Json.decode(binary)
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

        decoded
        |> Map.get(key, [])
        |> List.wrap()
        |> Stream.map(&{:ok, &1})

      true ->
        []
    end
  end
end
