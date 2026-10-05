defmodule ServiceRadar.Inventory.AdvisoryFeeds.StreamReader do
  @moduledoc """
  Off-disk readers that yield one upstream record at a time.

  ## nist-nvd2

  `serviceradar_core` ships `jason` only. A shard is not gunzipped or
  `Jason.decode`d as one document: gzip members are inflated in the zlib
  output chunks (`:zlib.safeInflate/2`, 16 KiB) and each `vulnerabilities[]`
  object is copied out and decoded on its own. The retained working set is
  one record plus the current inflate chunk, not the shard.

  The zip itself is streamed to disk by `Acquisition` through
  `ServiceRadar.HTTP.EgressClient` before this module sees a path.

  KEV and CISA documents stay small and still decode once in
  `stream_json_file/2`.

  Readers return `{:ok, record}` or an explicit `{:error, reason}` so a caller
  can reject an incomplete snapshot instead of promoting a partial read.
  """

  alias ServiceRadar.Inventory.AdvisoryFeeds.NvdShardDecoder

  require Logger

  @read_bytes 16_384
  @gzip_window 16 + 15

  @doc """
  Stream NVD 2.0 `vulnerabilities[]` records from a directory of `*.json.gz`
  shards (or `*.json` shards). Each shard yields one object at a time.
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

  These documents are the small KEV/CISA feeds. nist-nvd2 shards go through
  `stream_nvd_shards/1`.
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

  Inflates and decodes one object at a time. The returned list is the caller's:
  production loading uses `stream_nvd_shards/1`, which does not accumulate it.
  """
  @spec records_from_gzip(binary()) :: [map()]
  def records_from_gzip(gz_binary) do
    gz_binary
    |> gzip_pieces()
    |> decode_vulnerability_chunks()
    |> Enum.map(fn
      {:ok, record} -> record
      {:error, reason} -> raise ArgumentError, "nvd gzip shard: #{inspect(reason)}"
    end)
  end

  @doc false
  @spec decode_vulnerability_chunks(Enumerable.t()) :: Enumerable.t()
  def decode_vulnerability_chunks(chunks) do
    Stream.resource(
      fn -> {NvdShardDecoder.init(), chunk_iter(chunks)} end,
      &pull_chunk/1,
      fn
        :done -> :ok
        {_dec, iter} -> halt_chunks(iter)
      end
    )
  end

  defp chunk_iter(enum) do
    {:suspended, nil, cont} =
      Enumerable.reduce(enum, {:suspend, nil}, fn el, _ -> {:suspend, el} end)

    cont
  end

  defp next_chunk(nil), do: :done

  defp next_chunk(cont) do
    case cont.({:cont, nil}) do
      {:suspended, el, cont2} -> {:chunk, el, cont2}
      {:done, _} -> :done
      {:halted, _} -> :done
    end
  end

  defp halt_chunks(cont) when is_function(cont) do
    try do
      cont.({:halt, nil})
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp halt_chunks(_), do: :ok

  defp pull_chunk(:done), do: {:halt, :done}

  defp pull_chunk({dec, iter}) do
    case NvdShardDecoder.pull(dec, <<>>) do
      {:event, event, dec} ->
        {[event], {dec, iter}}

      {:error, reason, _dec} ->
        halt_chunks(iter)
        {[{:error, reason}], :done}

      {:done, _dec} ->
        halt_chunks(iter)
        {:halt, :done}

      {:need_more, dec} ->
        case next_chunk(iter) do
          :done ->
            finish_chunks(dec)

          {:chunk, chunk, iter2} ->
            pull_fed(dec, chunk, iter2)
        end
    end
  end

  defp pull_fed(dec, chunk, iter) do
    case NvdShardDecoder.pull(dec, chunk) do
      {:event, event, dec} -> {[event], {dec, iter}}
      {:error, reason, _dec} ->
        halt_chunks(iter)
        {[{:error, reason}], :done}
      {:done, _dec} ->
        halt_chunks(iter)
        {:halt, :done}
      {:need_more, dec} -> pull_chunk({dec, iter})
    end
  end

  defp finish_chunks(dec) do
    case NvdShardDecoder.finish(dec) do
      {:event, event, dec} -> {[event], {dec, nil}}
      {:error, reason, _dec} -> {[{:error, reason}], :done}
      :done -> {:halt, :done}
    end
  end

  defp gzip_pieces(gz_binary) do
    Stream.resource(
      fn ->
        z = :zlib.open()
        :ok = :zlib.inflateInit(z, @gzip_window)
        {z, gz_binary, :input}
      end,
      fn
        :done ->
          {:halt, :done}

        {z, bin, :continue} ->
          gzip_step(z, [], bin, :continue)

        {z, <<>>, :input} ->
          {[], close_then_done(z)}

        {z, bin, :input} ->
          size = min(byte_size(bin), @read_bytes)
          <<head::binary-size(^size), rest::binary>> = bin
          gzip_step(z, head, rest, :input)
      end,
      fn
        :done ->
          :ok

        {z, _bin, _mode} ->
          close_zlib(z)
      end
    )
  end

  defp gzip_step(zlib, data, rest, _mode) do
    case :zlib.safeInflate(zlib, data) do
      {:continue, []} ->
        {[], {zlib, rest, :input}}

      {:continue, output} ->
        {[copy_iodata(output)], {zlib, rest, :continue}}

      {:finished, []} ->
        {[], close_then_done(zlib)}

      {:finished, output} ->
        {[copy_iodata(output)], close_then_done(zlib)}
    end
  catch
    :error, reason ->
      raise ArgumentError, "nvd gzip shard: #{inspect(reason)}"
  end

  defp close_then_done(z) do
    close_zlib(z)
    :done
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
    Stream.resource(
      fn -> open_shard(path) end,
      &next_shard/1,
      &close_shard/1
    )
  end

  defp open_shard(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        zlib =
          if String.ends_with?(path, ".gz") do
            z = :zlib.open()
            :ok = :zlib.inflateInit(z, @gzip_window)
            z
          end

        %{
          mode: :read,
          io: io,
          zlib: zlib,
          path: path,
          dec: NvdShardDecoder.init(),
          inflate: :input
        }

      {:error, reason} ->
        Logger.warning("advisory_feeds: unreadable shard #{path}: #{inspect(reason)}")
        %{mode: :once, event: {:error, {:read_error, path, reason}}}
    end
  end

  defp next_shard(%{mode: :halt} = state), do: {:halt, state}

  defp next_shard(%{mode: :once, event: event}) do
    {[event], %{mode: :halt}}
  end

  defp next_shard(state) do
    case NvdShardDecoder.pull(state.dec, <<>>) do
      {:event, event, dec} ->
        {[tag_event(event, state.path)], %{state | dec: dec}}

      {:error, reason, _dec} ->
        {[tag_event({:error, reason}, state.path)], %{state | mode: :halt}}

      {:done, _dec} ->
        {:halt, %{state | mode: :halt}}

      {:need_more, dec} ->
        feed_shard(%{state | dec: dec})
    end
  end

  defp feed_shard(%{inflate: :eof} = state) do
    case NvdShardDecoder.finish(state.dec) do
      {:event, event, dec} ->
        {[tag_event(event, state.path)], %{state | dec: dec}}

      {:error, reason, _dec} ->
        {[tag_event({:error, reason}, state.path)], %{state | mode: :halt}}

      :done ->
        {:halt, %{state | mode: :halt}}
    end
  end

  defp feed_shard(state) do
    case take_text(state) do
      {:text, text, state} ->
        case NvdShardDecoder.pull(state.dec, text) do
          {:event, event, dec} ->
            {[tag_event(event, state.path)], %{state | dec: dec}}

          {:need_more, dec} ->
            feed_shard(%{state | dec: dec})

          {:error, reason, _dec} ->
            {[tag_event({:error, reason}, state.path)], %{state | mode: :halt}}

          {:done, _dec} ->
            {:halt, %{state | mode: :halt}}
        end

      {:eof, state} ->
        feed_shard(%{state | inflate: :eof})

      {:error, reason, state} ->
        {[{:error, reason}], %{state | mode: :halt}}
    end
  end

  defp take_text(%{zlib: nil} = state) do
    case IO.binread(state.io, @read_bytes) do
      :eof -> {:eof, state}
      {:error, reason} -> {:error, {:read_error, state.path, reason}, state}
      data -> {:text, data, state}
    end
  end

  defp take_text(%{inflate: :eof} = state), do: {:eof, state}

  defp take_text(%{inflate: :continue, zlib: zlib} = state) do
    emit_inflate(state, zlib, [])
  end

  defp take_text(%{zlib: zlib} = state) do
    case IO.binread(state.io, @read_bytes) do
      :eof -> {:eof, state}
      {:error, reason} -> {:error, {:read_error, state.path, reason}, state}
      data -> emit_inflate(state, zlib, data)
    end
  end

  defp emit_inflate(state, zlib, data) do
    case :zlib.safeInflate(zlib, data) do
      {:continue, []} ->
        take_text(%{state | inflate: :input})

      {:continue, output} ->
        {:text, copy_iodata(output), %{state | inflate: :continue}}

      {:finished, []} ->
        {:eof, %{state | inflate: :eof}}

      {:finished, output} ->
        {:text, copy_iodata(output), %{state | inflate: :eof}}
    end
  catch
    :error, {:data_error, _zlib} ->
      {:error, {:parse_error, state.path, :data_error}, state}

    :error, reason ->
      {:error, {:parse_error, state.path, reason}, state}
  end

  defp copy_iodata(output) do
    output
    |> :erlang.iolist_to_binary()
    |> :binary.copy()
  end

  defp tag_event({:ok, record}, _path), do: {:ok, record}

  defp tag_event({:error, {:invalid_records, key}}, _path), do: {:error, {:invalid_records, key}}

  defp tag_event({:error, reason}, path), do: {:error, {:parse_error, path, reason}}

  defp close_shard(%{io: io, zlib: zlib}) do
    close_zlib(zlib)
    File.close(io)
  end

  defp close_shard(_state), do: :ok

  defp close_zlib(nil), do: :ok

  defp close_zlib(zlib) do
    try do
      :zlib.inflateEnd(zlib)
    catch
      _, _ -> :ok
    end

    :zlib.close(zlib)
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
