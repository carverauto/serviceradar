defmodule ServiceRadarNVR.DispositionJournal do
  @moduledoc """
  Durable append-only tombstone journal for reclaimed local blocks.

  Each committed entry is one newline-terminated canonical JSON record synced
  to `.disposition-journal` at the spool root before the block directory is
  unlinked. On restart, loading the journal and completing any pending removals
  finishes interrupted unlinks without mistaking a half-deleted directory for
  an incomplete block or inventory corruption.
  """

  alias ServiceRadarNVR.Blocks
  alias ServiceRadarRecording.Storage
  alias ServiceRadarRecordingMetadata.CanonicalJSON

  @filename ".disposition-journal"

  def filename, do: @filename

  @doc "Load all committed tombstones from `.disposition-journal`, keyed by block ID."
  def load(%Storage{} = storage) do
    path = journal_path(storage)

    case File.lstat(path) do
      {:error, :enoent} -> {:ok, %{}}
      {:ok, %File.Stat{type: :regular, links: 1, mode: mode}} -> load_private(path, mode, storage.id)
      {:ok, _} -> {:error, :invalid_disposition_journal}
      {:error, _} = error -> error
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

  defp load_private(path, mode, storage_id) do
    if Bitwise.band(mode, 0o077) == 0,
      do: read_entries(path, storage_id),
      else: {:error, :invalid_disposition_journal}
  end

  defp read_entries(path, storage_id) do
    case File.read(path) do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, bytes} ->
        # Only newline-terminated lines are committed; a partial trailing write
        # from a mid-append crash has no terminating newline and is ignored.
        lines = :binary.split(bytes, "\n", [:global])
        committed = Enum.slice(lines, 0, length(lines) - 1)
        parse_lines(committed, storage_id)

      {:error, _} = error ->
        error
    end
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
      {:ok, %File.Stat{type: :regular, links: 1, mode: mode}} -> append_private(path, mode, data)
      {:ok, _} -> {:error, :invalid_disposition_journal}
      {:error, _} = error -> error
    end
  end

  defp create_and_sync(root, path, data) do
    with :ok <- write_and_fsync(path, [:write, :exclusive], data, true),
         do: fsync_dir(root)
  end

  defp append_private(path, mode, data) do
    if Bitwise.band(mode, 0o077) == 0,
      do: write_and_fsync(path, [:write, :append], data, false),
      else: {:error, :invalid_disposition_journal}
  end

  defp write_and_fsync(path, modes, data, chmod?) do
    case :file.open(String.to_charlist(path), [:raw, :binary | modes]) do
      {:ok, device} ->
        try do
          with :ok <- maybe_chmod(path, chmod?),
               :ok <- :file.write(device, data),
               do: :file.sync(device)
        after
          :file.close(device)
        end

      {:error, _} = error ->
        error
    end
  end

  defp maybe_chmod(path, true), do: File.chmod(path, 0o600)
  defp maybe_chmod(_path, false), do: :ok

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

  defp fsync_dir(dir) do
    case :file.open(String.to_charlist(dir), [:raw, :binary, :read, :directory]) do
      {:ok, device} ->
        try do
          :file.sync(device)
        after
          :file.close(device)
        end

      {:error, _} = error ->
        error
    end
  end
end
