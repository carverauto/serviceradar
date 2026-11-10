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
  alias ServiceRadarRecordingMetadata.Descriptor

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
  Return canonical v1 descriptor JSON for a verified sealed local block.

  This trusted same-VM API verifies media through `sealed_block/1` first. The
  portable bytes contain no local paths or storage receipts and grant neither
  publication authority nor playback access. Inspection does not mutate disk.
  """
  def block_descriptor(block_id) do
    with {:ok, snapshot} <- sealed_block(block_id) do
      encode_descriptor(snapshot)
    end
  end

  @doc """
  Read verified initialization bytes or one fragment bound to a descriptor digest.

  `descriptor_sha256` is the lowercase hexadecimal SHA-256 of `block_descriptor/1`
  JSON. Select `:init` or `{:fragment, sequence}`; paths and arbitrary ranges are
  not accepted. Each call verifies the entire sealed block before comparing the
  descriptor digest, then rechecks the selected bytes. The runtime bounds output
  to 1 MiB for initialization or 4 MiB for a fragment.

  This trusted same-VM API runs I/O in the caller. It supplies neither playback
  authorization nor aggregate reader admission, cancellation or remote transport.
  """
  def read_block(block_id, descriptor_sha256, :init) do
    read_verified(block_id, descriptor_sha256, &Spool.read_init/1)
  end

  def read_block(block_id, descriptor_sha256, {:fragment, sequence}) when is_integer(sequence) and sequence >= 0 do
    read_verified(block_id, descriptor_sha256, &Spool.read_fragment(&1, sequence))
  end

  def read_block(_block_id, _descriptor_sha256, _selector), do: {:error, :invalid_media_selector}

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

  defp read_verified(block_id, expected_digest, read)
       when is_binary(expected_digest) and byte_size(expected_digest) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, expected_digest) do
      with {:ok, snapshot} <- sealed_block(block_id),
           {:ok, descriptor} <- encode_descriptor(snapshot),
           digest = Base.encode16(:crypto.hash(:sha256, descriptor), case: :lower),
           true <- digest == expected_digest || {:error, :descriptor_digest_mismatch} do
        read.(snapshot)
      end
    else
      {:error, :invalid_descriptor_digest}
    end
  end

  defp read_verified(_block_id, _expected_digest, _read), do: {:error, :invalid_descriptor_digest}

  defp encode_descriptor(snapshot) do
    with {:ok, descriptor} <- Descriptor.from_snapshot(snapshot, snapshot.init_format) do
      Descriptor.encode(descriptor)
    end
  end

  defp with_format(snapshot) do
    with {:ok, init} <- Spool.read_init(snapshot),
         {:ok, format} <- Initialization.parse(init) do
      {:ok, Map.put(snapshot, :init_format, format)}
    end
  end
end
