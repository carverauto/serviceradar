defmodule ServiceRadarNVR.Publication do
  @moduledoc """
  Immutable local intent and acknowledgement records for Core reconciliation.

  Trusted same-VM callers supply authority correlation and Core responses; these
  files do not prove origin, qualified storage, availability or deletion rights.
  Capacity serializes persistence while local writers are idle. Incomplete or
  conflicting files remain untouched. Acknowledgement persistence syncs the exact
  matching intent before the response, retaining both records for recovery.
  """

  alias ServiceRadarNVR.Blocks
  alias ServiceRadarRecording.Storage
  alias ServiceRadarRecordingMetadata.LocalPublicationAcknowledgement
  alias ServiceRadarRecordingMetadata.LocalPublicationIntent

  # Existing records are immutable, including partial writes. Their retained
  # bytes are charged by inventory; only absent records need future headroom.
  def pending_bytes(files) do
    Enum.reduce([:intent, :acknowledgement], 0, fn kind, bytes ->
      if filename(kind) in files, do: bytes, else: bytes + max_bytes(kind)
    end)
  end

  def max_bytes(:intent), do: 65_536
  def max_bytes(:acknowledgement), do: 512

  def prepare(storage, block_id, kind, payload, limits) do
    with {:ok, bytes} <- encode(storage, block_id, kind, payload, limits),
         {:ok, additional} <- existing(storage, block_id, kind, bytes) do
      {:ok, bytes, additional}
    end
  end

  def inspect(storage, block_id, :intent, limits) do
    with :ok <- valid_block_id(block_id),
         {:ok, bytes} <- read(storage, block_id, :intent),
         {:ok, document} <- LocalPublicationIntent.decode(bytes),
         reference = %{
           operation_id: document["operation_id"],
           recording_block_id: document["recording_block_id"],
           descriptor_sha256: document["descriptor_sha256"]
         },
         {:ok, expected} <- encode(storage, block_id, :intent, reference, limits),
         :ok <- matches(bytes, expected, :intent) do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_publication_intent}
    end
  end

  def inspect(storage, block_id, :acknowledgement, limits) do
    with :ok <- valid_block_id(block_id),
         {:ok, bytes} <- read(storage, block_id, :acknowledgement) do
      encode(storage, block_id, :acknowledgement, bytes, limits)
    end
  end

  def persist(storage, block_id, :acknowledgement, bytes) do
    with {:ok, intent} <- read(storage, block_id, :intent),
         :ok <- LocalPublicationAcknowledgement.validate(bytes, intent),
         :ok <- sync_existing(storage, block_id, :intent, intent) do
      persist_record(storage, block_id, :acknowledgement, bytes)
    end
  end

  def persist(storage, block_id, :intent, bytes), do: persist_record(storage, block_id, :intent, bytes)

  # Exclusive creation preserves a partial write as unresolved evidence. A lost
  # reply after a complete write can be retried by syncing the exact same bytes.
  defp persist_record(storage, block_id, kind, bytes) do
    path = path(storage, block_id, kind)

    with :ok <- Storage.verify(storage) do
      case create_file(path, bytes) do
        :ok -> sync_directory(storage, block_id)
        {:error, :eexist} -> sync_existing(storage, block_id, kind, bytes)
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

  defp encode(storage, block_id, :intent, reference, limits) do
    with {:ok, snapshot} <- Blocks.inspect(storage, block_id, limits),
         {:ok, descriptor} <- Blocks.descriptor(snapshot),
         {:ok, document} <- Jason.decode(descriptor) do
      LocalPublicationIntent.encode(document, storage.id, reference)
    end
  end

  defp encode(storage, block_id, :acknowledgement, bytes, limits) do
    with {:ok, intent} <- inspect(storage, block_id, :intent, limits),
         :ok <- LocalPublicationAcknowledgement.validate(bytes, intent) do
      {:ok, bytes}
    end
  end

  defp valid_block_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, id), do: :ok, else: {:error, :invalid_block_id}
  end

  defp valid_block_id(_), do: {:error, :invalid_block_id}

  defp existing(storage, block_id, kind, expected) do
    case read(storage, block_id, kind) do
      {:ok, bytes} -> with :ok <- matches(bytes, expected, kind), do: {:ok, 0}
      {:error, :enoent} -> {:ok, byte_size(expected)}
      {:error, _} = error -> error
    end
  end

  defp matches(bytes, bytes, _kind), do: :ok
  defp matches(_, _, :intent), do: {:error, :publication_intent_conflict}
  defp matches(_, _, :acknowledgement), do: {:error, :publication_acknowledgement_conflict}

  defp read(storage, block_id, kind) do
    limit = max_bytes(kind)
    directory = Path.join(storage.root, block_id)

    with :ok <- Storage.verify(storage),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:ok, %File.Stat{type: :regular, links: 1, size: size, mode: mode}} when size in 1..limit <-
           File.lstat(path(storage, block_id, kind)),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, bytes} <- with_file(path(storage, block_id, kind), [:read], &:file.read(&1, limit + 1)),
         true <- byte_size(bytes) == size,
         :ok <- Storage.verify(storage) do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, invalid_record(kind)}
    end
  end

  defp sync_existing(storage, block_id, kind, expected) do
    with {:ok, bytes} <- read(storage, block_id, kind),
         :ok <- matches(bytes, expected, kind),
         :ok <- with_file(path(storage, block_id, kind), [:read, :write], &:file.sync/1),
         do: sync_directory(storage, block_id)
  end

  defp sync_directory(storage, block_id) do
    with :ok <- with_file(Path.join(storage.root, block_id), [:read, :directory], &:file.sync/1),
         do: Storage.verify(storage)
  end

  defp path(storage, block_id, kind), do: Path.join([storage.root, block_id, filename(kind)])
  defp filename(:intent), do: "publication.json"
  defp filename(:acknowledgement), do: "publication-ack.json"
  defp invalid_record(:intent), do: :invalid_publication_intent
  defp invalid_record(:acknowledgement), do: :invalid_publication_acknowledgement

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
