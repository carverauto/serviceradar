defmodule ServiceRadarNVR do
  @moduledoc """
  Local service boundary for a finite recording session with bounded local blocks.

  Only trusted code in this VM may call this API. It is not an enrollment,
  assignment or offline-authority protocol. Only health probes are exposed over HTTP; no media or control listener exists.
  The caller is the sole producer and owns the returned bounded Inbox; media
  enters through Inbox.offer/2 and ends through Inbox.finish/1. Terminal results
  arrive as `{:nvr_recording, pid, result}`. A sealed local snapshot is not a
  catalog, archive or playback receipt.

  Full blocks produce `{:nvr_block_sealed, pid, receipt}` before admission of
  their successor. The terminal success contains the final block. These local
  notifications are not a durable outbox; retained journals are recovery evidence.
  """

  alias ServiceRadarNVR.Session
  alias ServiceRadarRecording.Initialization
  alias ServiceRadarRecording.Spool

  def start_recording(identity, clock) do
    case DynamicSupervisor.start_child(ServiceRadarNVR.Sessions, {Session, {self(), identity, clock}}) do
      {:ok, pid} -> {:ok, pid, GenServer.call(pid, :inbox)}
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :recording_unavailable}
  end

  def status(pid), do: GenServer.call(pid, :status)
  def stop(pid), do: GenServer.call(pid, :stop)

  @doc "Read-only local capacity observation, not a reservation or pool capability."
  def capacity, do: ServiceRadarNVR.Capacity.status()

  @doc "List at most 4,096 retained block IDs, including incomplete blocks; not a coverage catalog."
  def list_blocks do
    with {:ok, storage, _limits} <- ServiceRadarNVR.Capacity.recovery_storage(),
         {:ok, inventory} <- ServiceRadarNVR.Disk.inventory(storage) do
      {:ok, Enum.sort(inventory.block_ids)}
    end
  end

  @doc """
  Verify a sealed block without changing disk or requiring a saved notification.

  Includes `init_format` derived from the verified initialization bytes. This is
  local media evidence, not a publication receipt or playback authorization.
  """
  def sealed_block(block_id) do
    with {:ok, storage, limits} <- ServiceRadarNVR.Capacity.recovery_storage(),
         {:ok, snapshot} <- Spool.inspect_sealed(storage, block_id, limits) do
      with_format(snapshot)
    end
  end

  @doc """
  Recover and seal one retained block using its expected identity (including clock).

  Refuses while any local recording has a reservation. The provisioned volume
  must already have exclusive attachment and the previous writer must be retired;
  this local guard does not fence another replica. No capture or publication starts.
  Includes `init_format` as in `sealed_block/1`. Format decoding follows repair
  and sealing; a format error does not mean the files were left unchanged.
  """
  def recover_block(block_id, expected_identity) do
    with {:ok, snapshot} <- ServiceRadarNVR.Capacity.recover_block(block_id, expected_identity) do
      with_format(snapshot)
    end
  end

  defp with_format(snapshot) do
    with {:ok, init} <- Spool.read_init(snapshot),
         {:ok, format} <- Initialization.parse(init) do
      {:ok, Map.put(snapshot, :init_format, format)}
    end
  end
end
