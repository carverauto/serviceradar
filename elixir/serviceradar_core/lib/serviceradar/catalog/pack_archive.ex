defmodule ServiceRadar.Catalog.PackArchive do
  @moduledoc """
  Deterministic `.srpack` archive builder (`tar.zst` primary) and bounded
  streaming extractor (`tar.zst`, `tar.gz`, `.zip`, and raw POSIX USTAR `.tar`)
  for Solution Packs (`2.2`, Decision 1).

  ## Security & Reproducibility Invariants
  - Primary wire archive format is `tar.zst` (zstd level 3) over deterministic
    POSIX USTAR regular-file headers (`mode=0000644\\0`, `uid=0000000\\0`,
    `gid=0000000\\0`, `mtime=00000000000\\0`, `uname=""`, `gname=""`,
    `devmajor=0000000\\0`, `devminor=0000000\\0`, lexicographically sorted UTF-8
    paths, 512-byte zero padding, two 512-byte zero EOF blocks).
  - Enforces a 25 MB compressed ceiling, 64 MB uncompressed ceiling (during
    streaming decompression before full buffering), and 256-entry ceiling.
  - Rejects `..` path traversal, leading `/`, symlinks, hardlinks, device nodes,
    duplicate entries, unlisted files omitted from `manifest.files`, and SHA-256
    digest mismatches before any database write.
  """

  import Bitwise

  alias ServiceRadar.Catalog.PackManifest

  @max_compressed_bytes 25 * 1024 * 1024
  @max_uncompressed_bytes 64 * 1024 * 1024
  @max_compressed_bytes_with_dashboards 32 * 1024 * 1024
  @max_uncompressed_bytes_with_dashboards 96 * 1024 * 1024
  @max_renderer_bytes 8 * 1024 * 1024
  @max_entries 256
  @tar_block_size 512
  @zstd_level 3
  @s_ifmt 0o170000
  @s_iflnk 0o120000
  @s_ifreg 0o100000
  @s_ifdir 0o040000

  @doc "Maximum compressed archive size in bytes without bundled dashboards (25 MB)."
  @spec max_compressed_bytes() :: pos_integer()
  def max_compressed_bytes, do: @max_compressed_bytes

  @doc "Maximum total uncompressed archive size in bytes without bundled dashboards (64 MB)."
  @spec max_uncompressed_bytes() :: pos_integer()
  def max_uncompressed_bytes, do: @max_uncompressed_bytes

  @doc "Maximum compressed archive size in bytes when bundled dashboards are present (32 MB)."
  @spec max_compressed_bytes_with_dashboards() :: pos_integer()
  def max_compressed_bytes_with_dashboards, do: @max_compressed_bytes_with_dashboards

  @doc "Maximum total uncompressed archive size in bytes when bundled dashboards are present (96 MB)."
  @spec max_uncompressed_bytes_with_dashboards() :: pos_integer()
  def max_uncompressed_bytes_with_dashboards, do: @max_uncompressed_bytes_with_dashboards

  @doc "Maximum single bundled dashboard `renderer.js` byte size (8 MB)."
  @spec max_renderer_bytes() :: pos_integer()
  def max_renderer_bytes, do: @max_renderer_bytes

  @doc "Maximum number of file entries in a Solution Pack archive (256)."
  @spec max_entries() :: pos_integer()
  def max_entries, do: @max_entries

  @doc """
  Builds a byte-for-byte deterministic `.srpack` (`tar.zst`) archive from a
  validated pack file map (`%{relative_path => binary}`).

  Pass `refresh_digests: true` to recompute `manifest.files` and canonicalize
  `manifest.json` prior to validation and packing.
  """
  @spec build(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def build(raw_file_map, opts \\ []) when is_map(raw_file_map) and is_list(opts) do
    max_entries = Keyword.get(opts, :max_entries, @max_entries)

    with {:ok, file_map} <- maybe_refresh_digests(raw_file_map, opts),
         {default_compressed, default_uncompressed} = effective_limits(file_map),
         max_uncompressed = Keyword.get(opts, :max_uncompressed_bytes, default_uncompressed),
         max_compressed = Keyword.get(opts, :max_compressed_bytes, default_compressed),
         :ok <- check_build_bounds(file_map, max_entries, max_uncompressed),
         :ok <- check_renderer_sizes(file_map),
         {:ok, _validated} <- PackManifest.validate_pack_tree(file_map, opts),
         {:ok, tar_bytes} <- encode_ustar(file_map) do
      compressed =
        tar_bytes
        |> :zstd.compress(%{compressionLevel: @zstd_level})
        |> IO.iodata_to_binary()

      if byte_size(compressed) > max_compressed do
        {:error, :compressed_archive_too_large}
      else
        {:ok, compressed}
      end
    end
  end

  @doc """
  Extracts and validates a `.srpack` (`tar.zst`, `tar.gz`, raw `.tar`) or `.zip`
  archive into a validated pack map (`%{manifest, files, checks, rules, dashboards, ...}`).
  """
  @spec extract(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract(archive_bytes, opts \\ []) when is_binary(archive_bytes) and is_list(opts) do
    with {:ok, file_map} <- extract_raw(archive_bytes, opts) do
      PackManifest.validate_pack_tree(file_map, opts)
    end
  end

  @doc """
  Performs bounded, traversal-safe extraction into `%{relative_path => binary}`
  without running full resource schema validation (still enforcing compressed &
  uncompressed byte caps, entry caps, symlink/traversal rejection, and
  `manifest.files` SHA-256 + unlisted-file checks unless `verify_manifest_files: false`).
  """
  @spec extract_raw(binary(), keyword()) :: {:ok, %{String.t() => binary()}} | {:error, term()}
  def extract_raw(archive_bytes, opts \\ []) when is_binary(archive_bytes) and is_list(opts) do
    initial_max_compressed =
      Keyword.get(opts, :max_compressed_bytes, @max_compressed_bytes_with_dashboards)

    initial_max_uncompressed =
      Keyword.get(opts, :max_uncompressed_bytes, @max_uncompressed_bytes_with_dashboards)

    max_entries = Keyword.get(opts, :max_entries, @max_entries)

    if byte_size(archive_bytes) > initial_max_compressed do
      {:error, :compressed_archive_too_large}
    else
      with {:ok, files} <- unpack_by_magic(archive_bytes, initial_max_uncompressed, max_entries),
           :ok <- enforce_post_manifest_limits(archive_bytes, files, opts),
           :ok <- check_renderer_sizes(files),
           :ok <- maybe_verify_manifest_files(files, opts) do
        {:ok, files}
      end
    end
  end

  ## Packing (POSIX USTAR + zstd)

  defp maybe_refresh_digests(raw_files, opts) do
    files = Map.new(raw_files, fn {k, v} -> {to_string(k), v} end)

    if Keyword.get(opts, :refresh_digests, false) == true do
      case Map.fetch(files, "manifest.json") do
        {:ok, manifest_bytes} when is_binary(manifest_bytes) ->
          case Jason.decode(manifest_bytes) do
            {:ok, manifest} when is_map(manifest) ->
              {:ok, _updated_manifest, updated_files} =
                PackManifest.refresh_manifest_digests(manifest, files)

              {:ok, updated_files}

            _ ->
              {:error, :invalid_manifest_json}
          end

        {:ok, manifest} when is_map(manifest) ->
          {:ok, _updated_manifest, updated_files} =
            PackManifest.refresh_manifest_digests(manifest, files)

          {:ok, updated_files}

        :error ->
          {:error, :missing_manifest}
      end
    else
      {:ok, files}
    end
  end

  defp check_build_bounds(file_map, max_entries, max_uncompressed) do
    count = map_size(file_map)

    total =
      Enum.reduce(file_map, 0, fn {_k, v}, acc ->
        acc + if(is_binary(v), do: byte_size(v), else: 0)
      end)

    cond do
      count > max_entries -> {:error, :too_many_archive_entries}
      total > max_uncompressed -> {:error, :uncompressed_archive_too_large}
      true -> :ok
    end
  end

  defp effective_limits(files) do
    if has_dashboard_packages?(files) do
      {@max_compressed_bytes_with_dashboards, @max_uncompressed_bytes_with_dashboards}
    else
      {@max_compressed_bytes, @max_uncompressed_bytes}
    end
  end

  defp enforce_post_manifest_limits(archive_bytes, files, opts) do
    {default_compressed, default_uncompressed} = effective_limits(files)
    max_compressed = Keyword.get(opts, :max_compressed_bytes, default_compressed)
    max_uncompressed = Keyword.get(opts, :max_uncompressed_bytes, default_uncompressed)

    total_uncompressed =
      Enum.reduce(files, 0, fn {_k, v}, acc ->
        acc + if(is_binary(v), do: byte_size(v), else: 0)
      end)

    cond do
      byte_size(archive_bytes) > max_compressed -> {:error, :compressed_archive_too_large}
      total_uncompressed > max_uncompressed -> {:error, :uncompressed_archive_too_large}
      true -> :ok
    end
  end

  defp check_renderer_sizes(files) do
    oversized =
      Enum.find(files, fn {path, bytes} ->
        lower_path = String.downcase(path)

        is_binary(bytes) and
          String.starts_with?(path, "dashboard_packages/") and
          (String.ends_with?(lower_path, ".js") or String.ends_with?(lower_path, ".mjs")) and
          byte_size(bytes) > @max_renderer_bytes
      end)

    case oversized do
      nil -> :ok
      {path, _bytes} -> {:error, {:renderer_too_large, path}}
    end
  end

  defp has_dashboard_packages?(files) do
    case Map.fetch(files, "manifest.json") do
      {:ok, manifest_bytes} when is_binary(manifest_bytes) ->
        case Jason.decode(manifest_bytes) do
          {:ok, manifest} when is_map(manifest) ->
            manifest_has_dashboard_packages?(manifest)

          _ ->
            false
        end

      {:ok, manifest} when is_map(manifest) ->
        manifest_has_dashboard_packages?(manifest)

      _ ->
        Enum.any?(Map.keys(files), &String.starts_with?(&1, "dashboard_packages/"))
    end
  end

  defp manifest_has_dashboard_packages?(manifest) do
    Map.get(manifest, "pack_format_version") == 2 and
      manifest
      |> get_in(["resources", "dashboard_packages"])
      |> List.wrap()
      |> Enum.empty?()
      |> Kernel.not()
  end

  @doc false
  @spec encode_ustar(map()) :: {:ok, binary()} | {:error, term()}
  def encode_ustar(file_map) when is_map(file_map) do
    sorted =
      file_map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))

    entries_res =
      Enum.reduce_while(sorted, {:ok, []}, fn {path, body}, {:ok, acc} ->
        case build_ustar_entry(path, body) do
          {:ok, iodata} -> {:cont, {:ok, [iodata | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case entries_res do
      {:ok, rev} ->
        eof = :binary.copy(<<0>>, @tar_block_size * 2)
        {:ok, IO.iodata_to_binary([Enum.reverse(rev), eof])}

      err ->
        err
    end
  end

  defp build_ustar_entry(path, body) when is_binary(path) and is_binary(body) do
    with {:ok, name_field, prefix_field} <- split_ustar_name(path) do
      size = byte_size(body)
      mode = "0000644\0"
      uid = "0000000\0"
      gid = "0000000\0"
      size_octal = octal_field(size, 11)
      mtime = "00000000000\0"
      placeholder_chksum = "        "
      typeflag = <<?0>>
      linkname = :binary.copy(<<0>>, 100)
      magic = "ustar\0"
      version = "00"
      uname = :binary.copy(<<0>>, 32)
      gname = :binary.copy(<<0>>, 32)
      devmajor = "0000000\0"
      devminor = "0000000\0"
      tail_pad = :binary.copy(<<0>>, 12)

      pre_chksum =
        IO.iodata_to_binary([
          name_field,
          mode,
          uid,
          gid,
          size_octal,
          mtime
        ])

      post_chksum =
        IO.iodata_to_binary([
          typeflag,
          linkname,
          magic,
          version,
          uname,
          gname,
          devmajor,
          devminor,
          prefix_field,
          tail_pad
        ])

      unsigned_header = pre_chksum <> placeholder_chksum <> post_chksum
      sum = byte_sum(unsigned_header, 0)
      chksum_str = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, 0x20>>
      header = pre_chksum <> chksum_str <> post_chksum

      rem_bytes = rem(size, @tar_block_size)

      body_pad =
        if rem_bytes == 0, do: <<>>, else: :binary.copy(<<0>>, @tar_block_size - rem_bytes)

      {:ok, [header, body, body_pad]}
    end
  end

  defp split_ustar_name(path) do
    cond do
      not PackManifest.safe_relative_path?(path) ->
        {:error, {:unsafe_archive_path, path}}

      byte_size(path) <= 100 ->
        {:ok, pad_nul(path, 100), :binary.copy(<<0>>, 155)}

      true ->
        split_prefix_and_name(path)
    end
  end

  defp split_prefix_and_name(path) do
    segments = String.split(path, "/")

    found =
      Enum.find_value(1..(length(segments) - 1), fn split_at ->
        prefix = segments |> Enum.take(split_at) |> Enum.join("/")
        name = segments |> Enum.drop(split_at) |> Enum.join("/")

        if byte_size(prefix) <= 155 and byte_size(name) <= 100 do
          {pad_nul(name, 100), pad_nul(prefix, 155)}
        end
      end)

    case found do
      {name_field, prefix_field} -> {:ok, name_field, prefix_field}
      nil -> {:error, {:archive_path_too_long, path}}
    end
  end

  defp pad_nul(bin, width) do
    bin <> :binary.copy(<<0>>, width - byte_size(bin))
  end

  defp octal_field(num, digits) do
    String.pad_leading(Integer.to_string(num, 8), digits, "0") <> <<0>>
  end

  defp byte_sum(<<>>, acc), do: acc
  defp byte_sum(<<b, rest::binary>>, acc), do: byte_sum(rest, acc + b)

  ## Unpacking & Streaming Bounds

  defp unpack_by_magic(
         <<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = zst_bytes,
         max_uncompressed,
         max_entries
       ) do
    with {:ok, tar_bytes} <- decompress_zstd_bounded(zst_bytes, max_uncompressed) do
      decode_ustar(tar_bytes, max_uncompressed, max_entries)
    end
  end

  defp unpack_by_magic(<<0x1F, 0x8B, _::binary>> = gz_bytes, max_uncompressed, max_entries) do
    with {:ok, tar_bytes} <- decompress_gzip_bounded(gz_bytes, max_uncompressed) do
      decode_ustar(tar_bytes, max_uncompressed, max_entries)
    end
  end

  defp unpack_by_magic(
         <<"PK", sig::binary-size(2), _::binary>> = zip_bytes,
         max_uncompressed,
         max_entries
       )
       when sig in [<<0x03, 0x04>>, <<0x05, 0x06>>] do
    extract_zip_bounded(zip_bytes, max_uncompressed, max_entries)
  end

  defp unpack_by_magic(raw_bytes, max_uncompressed, max_entries)
       when byte_size(raw_bytes) >= @tar_block_size do
    case binary_part(raw_bytes, 257, 5) do
      "ustar" -> decode_ustar(raw_bytes, max_uncompressed, max_entries)
      _ -> {:error, :unsupported_archive_format}
    end
  end

  defp unpack_by_magic(_other, _max_uncompressed, _max_entries),
    do: {:error, :unsupported_archive_format}

  defp decompress_zstd_bounded(zst_bytes, max_uncompressed) do
    case :zstd.get_frame_header(zst_bytes) do
      {:ok, %{frameContentSize: content_size}}
      when is_integer(content_size) and content_size > max_uncompressed ->
        {:error, :uncompressed_archive_too_large}

      {:error, _reason} ->
        {:error, :corrupt_zstd_archive}

      _ ->
        run_zstd_stream(zst_bytes, max_uncompressed)
    end
  end

  defp run_zstd_stream(zst_bytes, max_uncompressed) do
    {:ok, dctx} = :zstd.context(:decompress)

    try do
      zstd_pump_input(dctx, zst_bytes, max_uncompressed, 0, [])
    rescue
      _ -> {:error, :corrupt_zstd_archive}
    catch
      _, _ -> {:error, :corrupt_zstd_archive}
    after
      _ = :zstd.close(dctx)
    end
  end

  defp zstd_pump_input(dctx, input, max_bytes, total, acc) do
    case :zstd.stream(dctx, input) do
      {:continue, remainder, chunk} ->
        next_total = total + IO.iodata_length(chunk)

        if next_total > max_bytes do
          {:error, :uncompressed_archive_too_large}
        else
          zstd_pump_input(dctx, remainder, max_bytes, next_total, [acc | chunk])
        end

      {:continue, chunk} ->
        next_total = total + IO.iodata_length(chunk)

        if next_total > max_bytes do
          {:error, :uncompressed_archive_too_large}
        else
          zstd_pump_finish(dctx, <<>>, max_bytes, next_total, [acc | chunk])
        end

      {:error, _} ->
        {:error, :corrupt_zstd_archive}
    end
  end

  defp zstd_pump_finish(dctx, input, max_bytes, total, acc) do
    case :zstd.finish(dctx, input) do
      {:continue, remainder, chunk} ->
        next_total = total + IO.iodata_length(chunk)

        if next_total > max_bytes do
          {:error, :uncompressed_archive_too_large}
        else
          zstd_pump_finish(dctx, remainder, max_bytes, next_total, [acc | chunk])
        end

      {:done, chunk} ->
        next_total = total + IO.iodata_length(chunk)

        if next_total > max_bytes do
          {:error, :uncompressed_archive_too_large}
        else
          {:ok, IO.iodata_to_binary([acc | chunk])}
        end

      {:error, _} ->
        {:error, :corrupt_zstd_archive}
    end
  end

  defp decompress_gzip_bounded(gz_bytes, max_uncompressed) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflate_chunks(z, gz_bytes, max_uncompressed, 0, [])
    rescue
      _ -> {:error, :corrupt_gzip_archive}
    catch
      _, _ -> {:error, :corrupt_gzip_archive}
    after
      _ = :zlib.close(z)
    end
  end

  defp inflate_chunks(z, input, max_bytes, total, acc) do
    <<slice::binary-size(min(byte_size(input), 16_384)), rest::binary>> = input
    chunks = :zlib.inflate(z, slice)
    next_total = total + IO.iodata_length(chunks)

    cond do
      next_total > max_bytes ->
        {:error, :uncompressed_archive_too_large}

      rest == <<>> ->
        {:ok, IO.iodata_to_binary([acc | chunks])}

      true ->
        inflate_chunks(z, rest, max_bytes, next_total, [acc | chunks])
    end
  end

  defp extract_zip_bounded(zip_bytes, max_uncompressed, max_entries) do
    with {:ok, listing} <- :zip.list_dir(zip_bytes),
         :ok <- preflight_zip_listing(listing, max_uncompressed, max_entries),
         {:ok, extracted} <- :zip.extract(zip_bytes, [:memory]) do
      normalize_zip_extracted(extracted, max_uncompressed)
    else
      {:error, reason} when is_atom(reason) or is_tuple(reason) -> {:error, reason}
      other -> {:error, {:invalid_zip_archive, other}}
    end
  end

  defp preflight_zip_listing(listing, max_uncompressed, max_entries) do
    listing
    |> Enum.reduce_while({:ok, MapSet.new(), 0, 0}, fn
      {:zip_comment, _}, state ->
        {:cont, state}

      {:zip_file, raw_name, file_info, _comment, _offset, _comp_size},
      {:ok, seen, count, total} ->
        name = List.to_string(raw_name)
        size = elem(file_info, 1)
        type = elem(file_info, 2)
        mode = elem(file_info, 7) || 0

        cond do
          type == :symlink or (mode &&& @s_ifmt) == @s_iflnk ->
            {:halt, {:error, :symlink_forbidden}}

          type == :directory or String.ends_with?(name, "/") or (mode &&& @s_ifmt) == @s_ifdir ->
            if PackManifest.safe_relative_path?(String.trim_trailing(name, "/")) do
              {:cont, {:ok, seen, count, total}}
            else
              {:halt, {:error, {:unsafe_archive_path, name}}}
            end

          type != :regular and (mode &&& @s_ifmt) not in [0, @s_ifreg] ->
            {:halt, {:error, :unsupported_archive_entry_type}}

          not PackManifest.safe_relative_path?(name) ->
            {:halt, {:error, {:unsafe_archive_path, name}}}

          MapSet.member?(seen, name) ->
            {:halt, {:error, {:duplicate_archive_entry, name}}}

          count + 1 > max_entries ->
            {:halt, {:error, :too_many_archive_entries}}

          total + size > max_uncompressed ->
            {:halt, {:error, :uncompressed_archive_too_large}}

          true ->
            {:cont, {:ok, MapSet.put(seen, name), count + 1, total + size}}
        end
    end)
    |> case do
      {:ok, _, _, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp normalize_zip_extracted(entries, max_uncompressed) do
    entries
    |> Enum.reduce_while({:ok, %{}, 0}, fn {raw_name, bytes}, {:ok, acc, total} ->
      name = List.to_string(raw_name)
      next_total = total + byte_size(bytes)

      cond do
        not PackManifest.safe_relative_path?(name) ->
          {:halt, {:error, {:unsafe_archive_path, name}}}

        next_total > max_uncompressed ->
          {:halt, {:error, :uncompressed_archive_too_large}}

        true ->
          {:cont, {:ok, Map.put(acc, name, bytes), next_total}}
      end
    end)
    |> case do
      {:ok, map, _} -> {:ok, map}
      err -> err
    end
  end

  @doc false
  @spec decode_ustar(binary(), pos_integer(), pos_integer()) ::
          {:ok, %{String.t() => binary()}} | {:error, term()}
  def decode_ustar(tar_bytes, max_uncompressed, max_entries) do
    if rem(byte_size(tar_bytes), @tar_block_size) == 0 do
      parse_tar_blocks(tar_bytes, max_uncompressed, max_entries, 0, %{}, nil)
    else
      {:error, :corrupt_tar_archive}
    end
  end

  defp parse_tar_blocks(<<>>, _max_bytes, _max_entries, _total, files, _pax_path),
    do: {:ok, files}

  defp parse_tar_blocks(
         <<header::binary-size(@tar_block_size), rest::binary>>,
         max_bytes,
         max_entries,
         total,
         files,
         pax_path
       ) do
    if zero_block?(header) do
      {:ok, files}
    else
      with :ok <- verify_tar_checksum(header),
           {:ok, size} <- parse_tar_octal(binary_part(header, 124, 12)) do
        typeflag = :binary.at(header, 156)
        raw_path = pax_path || extract_ustar_path(header)
        padded_len = round_up_512(size)

        if byte_size(rest) < padded_len do
          {:error, :truncated_tar_archive}
        else
          <<body::binary-size(size), _pad::binary-size(padded_len - size), after_entry::binary>> =
            rest

          handle_tar_entry(
            typeflag,
            raw_path,
            body,
            after_entry,
            max_bytes,
            max_entries,
            total,
            files
          )
        end
      end
    end
  end

  defp handle_tar_entry(typeflag, raw_path, body, rest, max_bytes, max_entries, total, files) do
    cond do
      typeflag in [?1, ?2] ->
        {:error, :symlink_forbidden}

      typeflag in [?3, ?4, ?6] ->
        {:error, :device_entry_forbidden}

      typeflag == ?5 ->
        clean_dir = String.trim_trailing(raw_path, "/")

        if clean_dir == "" or PackManifest.safe_relative_path?(clean_dir) do
          parse_tar_blocks(rest, max_bytes, max_entries, total, files, nil)
        else
          {:error, {:unsafe_archive_path, raw_path}}
        end

      typeflag == ?x ->
        case parse_pax_headers(body) do
          {:ok, next_pax_path} ->
            parse_tar_blocks(rest, max_bytes, max_entries, total, files, next_pax_path)

          {:error, _} = err ->
            err
        end

      typeflag == ?g ->
        parse_tar_blocks(rest, max_bytes, max_entries, total, files, nil)

      typeflag in [0, ?0] ->
        next_total = total + byte_size(body)

        cond do
          not PackManifest.safe_relative_path?(raw_path) ->
            {:error, {:unsafe_archive_path, raw_path}}

          Map.has_key?(files, raw_path) ->
            {:error, {:duplicate_archive_entry, raw_path}}

          map_size(files) + 1 > max_entries ->
            {:error, :too_many_archive_entries}

          next_total > max_bytes ->
            {:error, :uncompressed_archive_too_large}

          true ->
            parse_tar_blocks(
              rest,
              max_bytes,
              max_entries,
              next_total,
              Map.put(files, raw_path, body),
              nil
            )
        end

      true ->
        {:error, {:unsupported_tar_typeflag, typeflag}}
    end
  end

  defp parse_pax_headers(body) do
    lines = String.split(body, "\n", trim: true)

    Enum.reduce_while(lines, {:ok, nil}, fn line, {:ok, path_acc} ->
      case String.split(line, " ", parts: 2) do
        [_len, kv] ->
          cond do
            String.starts_with?(kv, "linkpath=") ->
              {:halt, {:error, :symlink_forbidden}}

            String.starts_with?(kv, "path=") ->
              p = String.replace_prefix(kv, "path=", "")
              {:cont, {:ok, p}}

            true ->
              {:cont, {:ok, path_acc}}
          end

        _ ->
          {:cont, {:ok, path_acc}}
      end
    end)
  end

  defp extract_ustar_path(header) do
    name = cstring(binary_part(header, 0, 100))
    prefix = cstring(binary_part(header, 345, 155))

    if prefix == "" do
      name
    else
      prefix <> "/" <> name
    end
  end

  defp cstring(bin) do
    case :binary.split(bin, <<0>>) do
      [head | _] -> head
      [] -> ""
    end
  end

  defp verify_tar_checksum(header) do
    stored_raw = binary_part(header, 148, 8)

    with {:ok, expected} <- parse_tar_octal(stored_raw) do
      zeroed =
        binary_part(header, 0, 148) <>
          "        " <>
          binary_part(header, 156, @tar_block_size - 156)

      actual = byte_sum(zeroed, 0)

      if actual == expected do
        :ok
      else
        {:error, :invalid_tar_checksum}
      end
    end
  end

  defp parse_tar_octal(bin) do
    trimmed =
      bin
      |> cstring()
      |> String.trim()

    if trimmed == "" do
      {:ok, 0}
    else
      case Integer.parse(trimmed, 8) do
        {val, ""} when val >= 0 -> {:ok, val}
        _ -> {:error, :invalid_tar_header}
      end
    end
  end

  defp zero_block?(block), do: block == :binary.copy(<<0>>, @tar_block_size)

  defp round_up_512(0), do: 0

  defp round_up_512(size) do
    case rem(size, @tar_block_size) do
      0 -> size
      r -> size + (@tar_block_size - r)
    end
  end

  defp maybe_verify_manifest_files(files, opts) do
    if Keyword.get(opts, :verify_manifest_files, true) == true do
      with {:ok, manifest_bytes} <- fetch_manifest(files),
           {:ok, raw_manifest} <- decode_manifest(manifest_bytes),
           {:ok, manifest} <- PackManifest.validate_manifest(raw_manifest) do
        verify_extracted_digests(files, manifest["files"])
      end
    else
      :ok
    end
  end

  defp fetch_manifest(files) do
    case Map.fetch(files, "manifest.json") do
      {:ok, b} -> {:ok, b}
      :error -> {:error, :missing_manifest}
    end
  end

  defp decode_manifest(bytes) do
    case Jason.decode(bytes) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, :invalid_manifest_json}
    end
  end

  defp verify_extracted_digests(files, declared) do
    actual_paths = files |> Map.keys() |> List.delete("manifest.json") |> MapSet.new()
    declared_paths = declared |> Map.keys() |> MapSet.new()

    if MapSet.equal?(actual_paths, declared_paths) do
      mismatch =
        Enum.find(declared, fn {path, expected_hex} ->
          PackManifest.sha256_hex(Map.fetch!(files, path)) != String.downcase(expected_hex)
        end)

      case mismatch do
        nil -> :ok
        {bad_path, _} -> {:error, {:file_digest_mismatch, bad_path}}
      end
    else
      unlisted =
        actual_paths |> MapSet.difference(declared_paths) |> MapSet.to_list() |> Enum.sort()

      missing =
        declared_paths |> MapSet.difference(actual_paths) |> MapSet.to_list() |> Enum.sort()

      if unlisted == [] do
        {:error, {:missing_archive_files, missing}}
      else
        {:error, {:unlisted_archive_files, unlisted}}
      end
    end
  end
end
