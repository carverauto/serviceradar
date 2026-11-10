defmodule ServiceRadarNVR.Disk do
  @moduledoc false

  alias ServiceRadarRecording.Storage

  @max_blocks 4096
  @block_files ~w(init.mp4 media.m4s journal publication.json)

  # Inspect metadata only. Incomplete and sealed blocks are equally charged;
  # this is neither journal recovery nor permission to remove anything.
  def inventory(storage) do
    with :ok <- Storage.verify(storage),
         {:ok, entries} <- File.ls(storage.root),
         blocks = List.delete(entries, ".storage-id"),
         true <- length(blocks) <= @max_blocks || {:error, :nvr_inventory_limit},
         {:ok, bytes} <- sum(blocks, &block_bytes(storage.root, &1)),
         :ok <- Storage.verify(storage) do
      {:ok, %{used_bytes: bytes, blocks: length(blocks), max_blocks: @max_blocks, block_ids: blocks}}
    end
  end

  # GNU coreutils ships in the Linux runtime image. Use available (non-root)
  # blocks and the fundamental block size, never rounded df percentages.
  def available_bytes(root) do
    case System.cmd("/usr/bin/timeout", ["-k", "1s", "2s", "/usr/bin/stat", "-f", "--format=%a %S", "--", root],
           env: [{"LC_ALL", "C"}],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_available(output)
      _ -> {:error, :nvr_disk_probe_failed}
    end
  rescue
    ErlangError -> {:error, :nvr_disk_probe_failed}
  end

  defp parse_available(output) do
    with [blocks, size] <- String.split(output),
         {blocks, ""} when blocks >= 0 <- Integer.parse(blocks),
         {size, ""} when size > 0 <- Integer.parse(size) do
      {:ok, blocks * size}
    else
      _ -> {:error, :nvr_disk_probe_failed}
    end
  end

  defp block_bytes(root, key) do
    path = Path.join(root, key)

    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, key),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         {:ok, files} <- File.ls(path),
         true <- Enum.all?(files, &(&1 in @block_files)) do
      sum(files, &file_bytes(Path.join(path, &1)))
    else
      _ -> {:error, :nvr_inventory_unavailable}
    end
  end

  defp file_bytes(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1, size: bytes}} -> {:ok, bytes}
      _ -> {:error, :nvr_inventory_unavailable}
    end
  end

  defp sum(entries, measure) do
    Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, total} ->
      case measure.(entry) do
        {:ok, bytes} -> {:cont, {:ok, total + bytes}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
