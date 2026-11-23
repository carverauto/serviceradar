defmodule ServiceRadarNVR.DispositionJournal do
  @moduledoc """
  Durable append-only tombstone journal for reclaimed local blocks.

  Each committed entry is one newline-terminated canonical JSON record synced
  to `.disposition-journal` at the spool root before the block directory is
  unlinked. On restart, loading the journal truncates any unterminated trailing
  partial line, syncs the file and spool root, and completing any pending
  removals finishes interrupted unlinks without mistaking a half-deleted
  directory for an incomplete block or inventory corruption.
  """

  alias ServiceRadarNVR.Blocks
  alias ServiceRadarRecording.Storage
  alias ServiceRadarRecordingMetadata.CanonicalJSON

  @filename ".disposition-journal"

  def filename, do: @filename

  @doc "Load all committed tombstones from `.disposition-journal`, keyed by block ID."
  def load(%Storage{} = storage) do
    path = journal_path(storage)

    with :ok <- Storage.verify(storage) do
      case File.lstat(path) do
        {:error, :enoent} -> {:ok, %{}}
        {:ok, %File.Stat{type: :regular, links: 1, mode: mode}} -> load_private(storage, path, mode)
        {:ok, _} -> {:error, :invalid_disposition_journal}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Append and fsync one tombstone record before unlinking the block directory."
  def append(%Storage{} = storage, block_id, operation_id, expected_descriptor_sha256) do
    record = %{
      "version" => 1,
      "storage_id" => storage.id,
      "block_id" => block_id,
      "operation_id" => operation_id,
      "expected_descriptor_sha256" => expected_descriptor_sha256,
      "reclaimed_at_ms" => System.os_time(:millisecond)
    }

    with :ok <- Storage.verify(storage),
         {:ok, line} <- CanonicalJSON.encode(record),
         :ok <- append_line(storage, line <> "\n"),
         :ok <- Storage.verify(storage) do
      {:ok, record}
    end
  end

  @doc "Finish unlinking any tombstoned block directories left behind by a crash."
  def complete_pending(%Storage{} = storage, tombstones) when is_map(tombstones) do
    Enum.reduce_while(Map.keys(tombstones), :ok, fn block_id, :ok ->
      case unlink_block(storage, block_id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Safely unlink one validated block directory and sync the spool root."
  def unlink_block(%Storage{} = storage, block_id) do
    if Blocks.valid_id?(block_id),
      do: unlink_validated(storage, Path.join(storage.root, block_id)),
      else: {:error, :invalid_block_id}
  end

  defp unlink_validated(storage, path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory}} -> remove_block_dir(storage, path)
      {:ok, _} -> {:error, :invalid_block_directory}
      {:error, _} = error -> error
    end
  end

  defp remove_block_dir(storage, path) do
    with :ok <- remove_directory_contents(path),
         :ok <- File.rmdir(path),
         :ok <- fsync_dir(storage.root),
         do: Storage.verify(storage)
  end

  defp journal_path(%Storage{root: root}), do: Path.join(root, @filename)

  defp load_private(storage, path, mode) do
    if Bitwise.band(mode, 0o077) == 0,
      do: read_entries(storage, path),
      else: {:error, :invalid_disposition_journal}
  end

  defp read_entries(storage, path) do
    case File.read(path) do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, bytes} ->
        lines = :binary.split(bytes, "\n", [:global])
        {committed, [tail]} = Enum.split(lines, -1)

        with {:ok, entries} <- parse_lines(committed, storage.id),
             :ok <- maybe_truncate_tail(storage, path, byte_size(bytes) - byte_size(tail), byte_size(tail)) do
          {:ok, entries}
        end

      {:error, _} = error ->
        error
    end
  end

  defp maybe_truncate_tail(_storage, _path, _committed_size, 0), do: :ok

  defp maybe_truncate_tail(storage, path, committed_size, _tail_size) do
    with :ok <- truncate_file(path, committed_size),
         :ok <- fsync_dir(storage.root),
         do: Storage.verify(storage)
  end

  defp truncate_file(path, size) do
    with_file(path, [:read, :write], fn device ->
      with {:ok, actual} <- :file.position(device, :eof),
           true <- actual >= size || {:error, :invalid_disposition_journal},
           {:ok, ^size} <- :file.position(device, size),
           :ok <- :file.truncate(device),
           do: :file.sync(device)
    end)
  end

  defp parse_lines(lines, storage_id) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
      case decode_entry(line, storage_id) do
        {:ok, entry} -> {:cont, {:ok, Map.put_new(acc, entry["block_id"], entry)}}
        :error -> {:halt, {:error, :invalid_disposition_journal}}
      end
    end)
  end

  defp decode_entry(line, storage_id) do
    with {:ok,
          %{
            "version" => 1,
            "storage_id" => ^storage_id,
            "block_id" => block_id,
            "operation_id" => operation_id,
            "expected_descriptor_sha256" => digest,
            "reclaimed_at_ms" => reclaimed_at
          } = entry}
         when map_size(entry) == 6 <- Jason.decode(line),
         {:ok, ^line} <- CanonicalJSON.encode(entry),
         true <-
           Blocks.valid_id?(block_id) and canonical_uuid?(operation_id) and Blocks.valid_id?(digest) and
             is_integer(reclaimed_at) and reclaimed_at > 0 do
      {:ok, entry}
    else
      _ -> :error
    end
  end

  defp append_line(storage, data) do
    path = journal_path(storage)

    case File.lstat(path) do
      {:error, :enoent} -> create_and_sync(storage.root, path, data)
      {:ok, %File.Stat{type: :regular, links: 1, mode: mode}} -> append_private(storage.root, path, mode, data)
      {:ok, _} -> {:error, :invalid_disposition_journal}
      {:error, _} = error -> error
    end
  end

  defp create_and_sync(root, path, data) do
    with :ok <-
           with_file(path, [:write, :exclusive], fn device ->
             with :ok <- File.chmod(path, 0o600), do: write_or_rollback(device, 0, data)
           end),
         do: fsync_dir(root)
  end

  defp append_private(root, path, mode, data) do
    if Bitwise.band(mode, 0o077) == 0 do
      with {:ok, offset} <- write_at_eof(path, data) do
        if offset == 0, do: fsync_dir(root), else: :ok
      end
    else
      {:error, :invalid_disposition_journal}
    end
  end

  defp write_at_eof(path, data) do
    with_file(path, [:read, :write], fn device ->
      with {:ok, offset} <- :file.position(device, :eof),
           :ok <- check_line_boundary(device, offset),
           {:ok, ^offset} <- :file.position(device, offset),
           :ok <- write_or_rollback(device, offset, data) do
        {:ok, offset}
      end
    end)
  end

  defp check_line_boundary(_device, 0), do: :ok

  defp check_line_boundary(device, offset) do
    case :file.pread(device, offset - 1, 1) do
      {:ok, "\n"} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :invalid_disposition_journal}
    end
  end

  defp write_or_rollback(device, offset, data) do
    case :file.write(device, data) do
      :ok ->
        :file.sync(device)

      {:error, _} = error ->
        rollback_write(device, offset)
        error
    end
  end

  defp rollback_write(device, offset) do
    with {:ok, ^offset} <- :file.position(device, offset),
         :ok <- :file.truncate(device) do
      :file.sync(device)
    end
  end

  defp remove_directory_contents(dir) do
    case File.ls(dir) do
      {:ok, files} -> remove_files(dir, files)
      {:error, _} = error -> error
    end
  end

  defp remove_files(dir, files) do
    Enum.reduce_while(files, :ok, fn name, :ok ->
      case remove_regular_file(Path.join(dir, name)) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp remove_regular_file(file_path) do
    case File.lstat(file_path) do
      {:ok, %File.Stat{type: :regular}} -> unlink_ignoring_enoent(file_path)
      {:error, :enoent} -> :ok
      _ -> {:error, :invalid_block_file}
    end
  end

  defp unlink_ignoring_enoent(file_path) do
    case File.rm(file_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = error -> error
    end
  end

  defp canonical_uuid?(value) when is_binary(value), do: Ecto.UUID.cast(value) == {:ok, value}
  defp canonical_uuid?(_value), do: false

  defp fsync_dir(dir), do: with_file(dir, [:read, :directory], &:file.sync/1)

  defp with_file(path, modes, fun) do
    case :file.open(String.to_charlist(path), [:raw, :binary | modes]) do
      {:ok, device} ->
        try do
          fun.(device)
        after
          :file.close(device)
        end

      {:error, _} = error ->
        error
    end
  end
end
