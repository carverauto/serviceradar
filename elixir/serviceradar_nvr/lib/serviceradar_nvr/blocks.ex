defmodule ServiceRadarNVR.Blocks do
  @moduledoc false

  alias ServiceRadarRecording.Initialization
  alias ServiceRadarRecording.Spool
  alias ServiceRadarRecordingMetadata.Descriptor

  def inspect(storage, block_id, limits) do
    with {:ok, snapshot} <- Spool.inspect_sealed(storage, block_id, limits), do: with_format(snapshot)
  end

  def descriptor(snapshot) do
    with {:ok, descriptor} <- Descriptor.from_snapshot(snapshot, snapshot.init_format),
         do: Descriptor.encode(descriptor)
  end

  # Why a sealed block read failed, for the routes that answer it:
  # `:block_not_found` when the ID names no retained block, `:block_not_sealed`
  # when the block is present but no seal verifies, `:read_unavailable` when the
  # read pool or recovery state refused the read, and `:other` for anything else.
  def read_error(reason) when reason in [:enoent, :invalid_block_id], do: :block_not_found

  def read_error(reason)
      when reason in [
             :nvr_read_capacity,
             :nvr_read_timeout,
             :nvr_read_unavailable,
             :nvr_recovery_closed,
             :nvr_storage_not_configured
           ], do: :read_unavailable

  def read_error(reason)
      when reason in [
             :unsealed_block,
             :empty_block,
             :block_identity_mismatch,
             :uncommitted_block_bytes,
             :block_digest_mismatch,
             :journal_digest_mismatch,
             :media_digest_mismatch,
             :truncated_media
           ], do: :block_not_sealed

  def read_error(_reason), do: :other

  def with_format(snapshot) do
    with {:ok, init} <- Spool.read_init(snapshot),
         {:ok, format} <- Initialization.parse(init) do
      {:ok, Map.put(snapshot, :init_format, format)}
    end
  end

  # Committed fragments are contiguous from offset zero, so in sequence order
  # they are exactly the sealed media file, bound here to its seal digest.
  def media(snapshot) do
    result =
      Enum.reduce_while(snapshot.entries, {:ok, []}, fn entry, {:ok, parts} ->
        case Spool.read_fragment(snapshot, entry["sequence"]) do
          {:ok, bytes} -> {:cont, {:ok, [parts | bytes]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, parts} <- result,
         media = IO.iodata_to_binary(parts),
         true <-
           (byte_size(media) == snapshot.high_water and
              Base.encode16(:crypto.hash(:sha256, media), case: :lower) == snapshot.sha256) ||
             {:error, :media_digest_mismatch} do
      {:ok, media}
    end
  end
end
