defmodule ServiceRadarNVR.PublicationIntent do
  @moduledoc """
  Immutable, bounded local intent for later Core catalog reconciliation.

  This records a caller's authority correlation, not proof of authority. Core
  must validate the original frozen block before publication. No acknowledgement,
  upload receipt, deletion authority or playback permission is created here.
  Capacity serializes preparation/persistence while no local writer is admitted.
  Incomplete or conflicting files are preserved, never rewritten or repaired.
  """

  alias ServiceRadarNVR.Blocks
  alias ServiceRadarRecording.Storage
  alias ServiceRadarRecordingMetadata.LocalPublicationIntent

  @filename "publication.json"
  @max_bytes 65_536

  def prepare(storage, block_id, reference, limits) do
    with {:ok, bytes} <- encode(storage, block_id, reference, limits),
         {:ok, additional} <- existing(storage, block_id, bytes) do
      {:ok, bytes, additional}
    end
  end

  def inspect(storage, block_id, limits) do
    with :ok <- valid_block_id(block_id),
         {:ok, bytes} <- read(storage, block_id),
         {:ok, document} <- LocalPublicationIntent.decode(bytes),
         reference = %{
           operation_id: document["operation_id"],
           recording_block_id: document["recording_block_id"],
           descriptor_sha256: document["descriptor_sha256"]
         },
         {:ok, expected} <- encode(storage, block_id, reference, limits),
         :ok <- matches(bytes, expected) do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_publication_intent}
    end
  end

  # Exclusive creation preserves a partial write as unresolved evidence. A lost
  # reply after a complete write can be retried by syncing the exact same bytes.
  def persist(storage, block_id, bytes) do
    path = path(storage, block_id)

    with :ok <- Storage.verify(storage) do
      case create_file(path, bytes) do
        :ok -> sync_directory(storage, block_id)
        {:error, :eexist} -> sync_existing(storage, block_id, bytes)
        {:error, _} = error -> error
      end
    end
  end

  defp create_file(path, bytes) do
    with_file(path, [:write, :exclusive], fn device ->
      with :ok <- File.chmod(path, 0o600),
           :ok <- :file.write(device, bytes),
           do: :file.sync(device)
    end)
  end

  defp encode(storage, block_id, reference, limits) do
    with {:ok, snapshot} <- Blocks.inspect(storage, block_id, limits),
         {:ok, descriptor} <- Blocks.descriptor(snapshot),
         {:ok, document} <- Jason.decode(descriptor) do
      LocalPublicationIntent.encode(document, storage.id, reference)
    end
  end

  defp valid_block_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, id), do: :ok, else: {:error, :invalid_block_id}
  end

  defp valid_block_id(_), do: {:error, :invalid_block_id}

  defp existing(storage, block_id, expected) do
    case read(storage, block_id) do
      {:ok, bytes} -> with :ok <- matches(bytes, expected), do: {:ok, 0}
      {:error, :enoent} -> {:ok, byte_size(expected)}
      {:error, _} = error -> error
    end
  end

  defp matches(bytes, bytes), do: :ok
  defp matches(_, _), do: {:error, :publication_intent_conflict}

  defp read(storage, block_id) do
    directory = Path.join(storage.root, block_id)

    with :ok <- Storage.verify(storage),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:ok, %File.Stat{type: :regular, links: 1, size: size, mode: mode}} when size in 1..@max_bytes <-
           File.lstat(path(storage, block_id)),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, bytes} <- with_file(path(storage, block_id), [:read], &:file.read(&1, @max_bytes + 1)),
         true <- byte_size(bytes) == size,
         :ok <- Storage.verify(storage) do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_publication_intent}
    end
  end

  defp sync_existing(storage, block_id, expected) do
    with {:ok, bytes} <- read(storage, block_id),
         :ok <- matches(bytes, expected),
         :ok <- with_file(path(storage, block_id), [:read, :write], &:file.sync/1),
         do: sync_directory(storage, block_id)
  end

  defp sync_directory(storage, block_id) do
    with :ok <- with_file(Path.join(storage.root, block_id), [:read, :directory], &:file.sync/1),
         do: Storage.verify(storage)
  end

  defp path(storage, block_id), do: Path.join([storage.root, block_id, @filename])

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
