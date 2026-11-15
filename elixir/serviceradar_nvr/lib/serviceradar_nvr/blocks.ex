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
