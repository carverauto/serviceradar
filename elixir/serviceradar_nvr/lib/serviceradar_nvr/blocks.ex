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
end
